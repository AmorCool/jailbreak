#include <spawn.h>
#include <errno.h>
#include "../systemhook/src/common/common.h"
#include "boomerang.h"
#include "crashreporter.h"
#include "update.h"
#include <libjailbreak/util.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <litehook.h>
#include "jbserver/jbserver_local.h"
#include "hookd_provider.h"
#include "bootlog.h"
extern char **environ;

// build38.43: 黑名单判定符号（libjailbreak roothider/blacklist.m 提供）。
// 38.34 回退 prehook 接线时，rh2 里挂在 prehook 的 isBlacklistedPath 黑名单判定
// 被一起废弃 → RootHide Manager 黑名单（屏蔽）从未生效。这里在 3.x 原生
// __posix_spawn_hook 入口处补回判定（与 rh2 prehook 语义一致：黑名单进程不注入）。
extern bool isBlacklistedPath(const char* path);
extern pid_t* allocBlacklistProcessId(void);
extern void commitBlacklistProcessId(pid_t* pidp);
extern bool dyld_patch_enabled(void);
#include "../systemhook/src/common/envbuf.h"

// build38.32: 这两个 roothide spawn hook 在 roothider.m 中定义，需在文件顶部声明，
// 因为 __posix_spawn_hook（上方）与 initSpawnHooks（下方）都会用到；
// 原先声明放在文件末尾导致 __posix_spawn_hook 使用时未声明 → 编译失败。
extern int roothide_launchd___posix_spawn_prehook(pid_t *restrict pidp, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);
extern int roothide_launchd___posix_spawn_posthook(pid_t *restrict pidp, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);

void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code, const char *reason_string, uint64_t reason_flags);

extern int systemwide_trust_file_by_path(const char *path);
extern int roothide_launchd_trust_executable(const char *path);
extern int platform_set_process_debugged(uint64_t pid, bool fullyDebugged);
extern void systemwide_domain_set_enabled(bool enabled);

#define LOG_PROCESS_LAUNCHES 0

extern bool gInEarlyBoot;
extern bool gFreeBootLogoBeforeBackboardd;
void free_boot_logo(void);

void early_boot_done(void)
{
	gInEarlyBoot = false;
}

void ensure_fakelib_mounted(void)
{
	struct statfs fsb;
	if (statfs("/usr/lib", &fsb) != 0) {
		bootlog("FAKELIB statfs(/usr/lib) failed!");
		return;
	}
	if (strcmp(fsb.f_mntonname, "/usr/lib") != 0) {
		bootlog("FAKELIB not mounted (f_mntonname=%s), attempting mount...", fsb.f_mntonname);
		systemwide_domain_set_enabled(true);

		// The jailbreak server is not reachable at this point in the launchd lifecycle
		// So we need to host our own, just so that jbctl can talk to it
		mach_port_t serverPort = jbserver_local_start();
		int rc = jbctl_earlyboot(serverPort, "internal", "fakelib", "mount", NULL);
		jbserver_local_stop();

		if (rc == 0) {
			bootlog("FAKELIB mount OK via jbctl_earlyboot");
		} else {
			bootlog("FAKELIB mount FAILED: jbctl_earlyboot returned %d (errno=%d)", rc, rc != 0 ? rc : 0);
		}

		// Note down that the jailbreak was hidden
		// So that after the userspace reboot, we can unmount fakelib again
		setenv("DOPAMINE_IS_HIDDEN", "1", true);
	} else {
		bootlog("FAKELIB already mounted (f_mntonname=%s)", fsb.f_mntonname);
	}
}

int __posix_spawn_orig_wrapper(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	// we need to disable the crash reporter during the orig call
	// otherwise the child process inherits the exception ports
	// and this would trip jailbreak detections
	crashreporter_pause();	
	int r = __posix_spawn_inline(pid, path, desc, argv, envp);
	crashreporter_resume();

	return r;
}

int __posix_spawn_hook(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	// build38.55: 删除 Sileo persona override 代码。
	// 用户实测 iOS 18.0（不是 memory 里写的 16.3.1）—— `__builtin_available(iOS 17.6, *)`
	// 在 iOS 18 上为真，整个 if 块跳过，persona override 从未执行。38.53/38.54 在 iOS 18 上
	// 完全无效。Apple iOS 17.6+ kernel 封禁任何 persona override（包括 launchd root→root），
	// Sileo 无法 root 化。iOS 18 上唯一可行方案是 chmod/chown 让 sileolists mobile 可写
	// （见 DOBootstrapper.m ensureSileoAndAptDirectories build38.55 递归 chmod 0664）。

	if (path) {
		// build38.27: 38.22 的 ensure_jbroot_symlink 加在 roothide_launchd___posix_spawn_prehook
		// （roothider.m）里，但该 prehook 从未被任何地方注册/调用（死代码），导致
		// @loader_path/.jbroot 软链从未被建 → dyld 加载 Sileo 等 jbroot app 时
		// "Library not loaded: @loader_path/.jbroot/usr/lib/libroothide.dylib" → 黑屏闪退。
		// 真正被 initSpawnHooks 注册的入口是 __posix_spawn_hook，在此补上建链调用。
		// ensure_jbroot_symlink 对非 jbroot 路径无副作用（直接 return），幂等可重复调用。
		bootlog("SPAWN path=%s", path);
		// build38.31 诊断：若 Sileo 刷新源仍报“文件夹不存在”，这里记录 Sileo 进程的 HOME，
		// 以判断其缓存目录到底是落在 jbroot 内还是真实根（据此决定是否需改 ensureSileoAndAptDirectories 的路径）。
		if (strstr(path, "Sileo") != NULL && envp) {
			for (char *const *e = envp; *e; e++) {
				if (strncmp(*e, "HOME=", 5) == 0) {
					bootlog("SPAWN Sileo HOME=%s", (*e) + 5);
					break;
				}
			}
		}
		extern void ensure_jbroot_symlink(const char* filepath);
		ensure_jbroot_symlink(path);

		char executablePath[1024];
		uint32_t bufsize = sizeof(executablePath);
		_NSGetExecutablePath(&executablePath[0], &bufsize);
		if (!strcmp(path, executablePath)) {
			bootlog("SPAWN_HOOK detected userspace reboot reinsertion (path=%s)", path);
			// This spawn will perform a userspace reboot...
			// Instead of the ordinary hook, we want to reinsert this dylib
			// This has already been done in envp so we only need to call the original posix_spawn

			// We are back in "early boot" for the remainder of this launchd instance
			// Mainly so we don't lock up while spawning boomerang
			gInEarlyBoot = true;

			hookd_provider_teardown();

			// If the jailbreak is currently hidden, fakelib is not mounted
			// It needs to be mounted to regain launchd code execution after the userspace reboot
			ensure_fakelib_mounted();

#if LOG_PROCESS_LAUNCHES
			FILE *f = fopen("/var/mobile/launch_log.txt", "a");
			fprintf(f, "==== USERSPACE REBOOT ====\n");
			fclose(f);
#endif

			// Before the userspace reboot, we want to stash the primitives into boomerang
			boomerang_stashPrimitives();

			// Fix Xcode debugging being broken after the userspace reboot
			unmount("/Developer", MNT_FORCE);

			// If there is a pending jailbreak update, apply it now
			const char *stagedJailbreakUpdate = getenv("STAGED_JAILBREAK_UPDATE");
			if (stagedJailbreakUpdate) {
				// roothide merge (build38.12): jbupdate 失败不再 abort。
				// 真机证据：STAGED 可能来自历史残留（来源未明），launchd 里
				// jbupdate_basebin 任一环节失败（解压/trustcache 上传缺 primitives 等）
				// 原代码 abort_with_reason → launchd(initproc) abort → 内核 panic → 硬重启。
				// launchd 绝不因 basebin 更新失败而崩溃：失败仅忽略，继续 reboot 流程。
				// （launchdhook 内无 JBLogError 宏，spawn_hook.c 为纯 C，静默跳过）
				int r = jbupdate_basebin(stagedJailbreakUpdate);
				(void)r;
				unsetenv("STAGED_JAILBREAK_UPDATE");
			}

			// Always use environ instead of envp, as boomerang_stashPrimitives calls setenv
			// setenv / unsetenv can sometimes cause environ to get reallocated
			// In that case envp may point to garbage or be empty
			// Say goodbye to this process
			return __posix_spawn_orig_wrapper(pid, path, desc, argv, environ);
		}
	}

#if LOG_PROCESS_LAUNCHES
	if (path) {
		FILE *f = fopen("/var/mobile/launch_log.txt", "a");
		fprintf(f, "%s", path);
		int ai = 0;
		while (argv) {
			if (argv[ai]) {
				if (ai >= 1) {
					fprintf(f, " %s", argv[ai]);
				}
				ai++;
			}
			else {
				break;
			}
		}
		fprintf(f, "\n");
		fclose(f);

		// if (!strcmp(path, "/usr/libexec/xpcproxy")) {
		// 	const char *tmpBlacklist[] = {
		// 		"com.apple.logd"
		// 	};
		// 	size_t blacklistCount = sizeof(tmpBlacklist) / sizeof(tmpBlacklist[0]);
		// 	for (size_t i = 0; i < blacklistCount; i++)
		// 	{
		// 		if (!strcmp(tmpBlacklist[i], firstArg)) {
		// 			FILE *f = fopen("/var/mobile/launch_log.txt", "a");
		// 			fprintf(f, "blocked injection %s\n", firstArg);
		// 			fclose(f);
		// 			return __posix_spawn_orig_wrapper(pid, path, file_actions, desc, envp);
		// 		}
		// 	}
		// }
	}
#endif

	// We can't support injection into processes that get spawned before the launchd XPC server is up
	// (Technically we could but there is little reason to, since it requires additional work)
	if (gInEarlyBoot) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			// The spawned process being xpcproxy indicates that the launchd XPC server is up
			// All processes spawned including this one should be injected into
			early_boot_done();
		}
		else {
			return __posix_spawn_orig_wrapper(pid, path, desc, argv, envp);
		}
	}

	// If we're drawing a boot logo, free up it's resources before backboardd starts
	if (gFreeBootLogoBeforeBackboardd) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			if (argv[0]) {
				if (argv[1]) {
					if (!strcmp(argv[1], "com.apple.backboardd\n")) {
						free_boot_logo();
						gFreeBootLogoBeforeBackboardd = false;
					}
				}
			}
		}
	}

	// build38.34: 回退 build38.29 的 posthook 接线。
	// 证据：38.26~38.28 用 __posix_spawn_orig_wrapper 作为 orig（无 roothide posthook）时
	// 用户空间重启正常；38.29+ 引入 posthook 后（其内部 DYLD_IN_CACHE=0）重启即黑屏卡死。
	// 38.33 仅禁了 jbdSpawnPatchChild 仍黑屏，证明元凶是 posthook 的 DYLD_IN_CACHE=0
	//（iOS18 下对继承 DYLD_INSERT_LIBRARIES 的系统守护进程强制不走共享缓存 → 启动卡死）。
	// iOS18 上 posthook 的两项职责（spinlock fix / DYLD_IN_CACHE=0）均不需要，
	// 3.x 的 __posix_spawn_hook 已自行完成 roothide 路径重映射与注入。
	// 注意：上方第 98 行的 ensure_jbroot_symlink（build38.27 的 Sileo 修复）保留，不受影响。
	// build38.37: trust 回调恢复 roothide 版本（与 rh2 一致）。
	// 38.34 用 systemwide_trust_file_by_path：dyld_patch_enabled 默认 false 时，
	// 它只信任单个二进制，不会递归信任 jbroot/basebin 及 @loader_path/.jbroot 依赖
	// → systemhook.dylib 及其依赖不被信任 → dyld 拒绝加载 → 注入失败 →
	// Sileo spawnAsRoot(persona 99) 提权失败 → sileolists 建不出("文件夹不存在")
	// + 插件无效 + TSLite 报错。roothide_launchd_trust_executable 在 dyld_patch
	// 关闭时走 roothide_trust_executable_recurse（递归信任 jbroot 内全部文件）。
	// 仅改 trust 回调，不回退 posthook（DYLD_IN_CACHE=0 黑屏根因仍保持 38.34 的修复）。

	// build38.43: 恢复黑名单判定（RootHide Manager 屏蔽）。
	// 38.34 回退 prehook 后 isBlacklistedPath 从未被调用 → 屏蔽完全失效。
	//
	// build38.46: 对标 rh2 roothider.m:378-432 重写黑名单 spawn 路径。
	//   关键差异：
	//   - EPERM 在 rh2 有双重门控 dyld_patch_enabled() && iOS15Arm64e——iOS16+ 上
	//     两个条件均为 false → EPERM 从不触发。38.45 误把 EPERM 写成无条件，
	//     导致 iOS18 上屏蔽 app 的扩展/预热进程被直接拒绝（launchd 杀父进程 → 闪退；
	//     用户实测"开黑名单后打开 app 闪退，先关再开才行"）。
	//   - 非 EPERM 普通路径：rh2 用 __posix_spawn_orig_wrapper（绕过注入，纯原始
	//     spawn）+ 记录 blacklist 进程表；choicyBlocked 分支与我们无关（rh2
	//     choicyBlocked 仅 iOS15 arm64e + _SafeMode 环境，我们的 Choicy 不走 launchd）。
	//
	// build38.49: 屏蔽闪退根因修复。
	//   用户实测现象：开启黑名单 → 打开 app → 闪退；关闭黑名单 → 打开 app → 正常；
	//   再开黑名单 → app 继续正常。说明第一次 spawn 时某些前置条件未就绪。
	//
	//   根因分析（对标 rh2 行为 + iOS18 实测）：
	//   1) rh2 的黑名单进程走 __posix_spawn_orig_wrapper（无 trust 参数），iOS18 上
	//      jbroot 二进制需 trustcache 签名信任才能 dyld 加载。若黑名单 app 的插件
	//      (MobileSubstrate/DynamicPatches) 引用了 jbroot 内的 .dylib → 加载失败 → 崩溃。
	//      但更常见的情况是：黑名单 app 本身是 App Store 签名，不依赖 jbroot → 不应崩溃。
	//   2) 第一次 spawn 时 fakelib 可能未挂载完成（ensure_fakelib_mounted 是懒加载，
	//      在 postinit 里虽已调用但可能因 jbserver 未就绪而失败）。此时
	//      access(HOOK_DYLIB_PATH, F_OK) 对非黑名单进程也会失败 → shouldInsertJBEnv=false
	//      → 这些进程不注入 systemhook。但这不应导致闪退。
	//   3) **真正根因（高概率）**：roothider.m prehook（第 500-557 行）和 spawn_hook.c
	//      __posix_spawn_hook（第 270-322 行）**都有黑名单判定**！prehook 先执行，
	//      它对黑名单进程返回后 __posix_spawn_hook 不会再执行。但 prehook 内部的
	//      __posix_spawn_orig_wrapper 调用会经过 launchdhook 的完整 spawn 链（含 posthook），
	//      而 posthook 在 38.34 已被回退（不再接线）→ orig_wrapper 就是纯 syscall。
	//      问题出在 prehook 的 EPERM 分支：虽然 iOS18 上 EPERM 门控为假不会触发，
	//      但普通分支里 platform_set_process_debugged(bpid, false) 在进程已 resume
	//      时可能触发竞态 → 崩溃。
	//
	//   修复方案：
	//   a) 黑名单普通分支增加 HOOK_DYLIB_PATH 可访问性检查——若 fakelib 未挂载好，
	//      说明整个注入链未就绪，此时连黑名单处理都可能不稳定，打印警告但不阻止。
	//   b) platform_set_process_debugged 只在确实 suspended 时调用（加 flags 检查）。
	//   c) 增加 bootlog 日志记录黑名单 spawn 的完整路径和结果，便于定位残余闪退。
	bool roothideBlacklisted = isBlacklistedPath(path);
	if (roothideBlacklisted)
	{
		bootlog("blacklisted app %s [spawn_hook]", path);

		// build38.50: 根本性修复屏蔽闪退（日志 launchdhook_boot.log 实测所有黑名单
		// app spawn 返回 -1，普通 app 同路径 spawn 成功）。
		// 根因：38.43 恢复黑名单判定后直接 __posix_spawn_orig_wrapper，跳过了
		// posix_spawn_hook_shared 里的 trust_binary（信任二进制）→ App Store app
		// 未入 trustcache → iOS16 posix_spawn 直接失败（ret=-1）→ 开黑名单即闪退。
		// 修复：手动调用 roothide_launchd_trust_executable（与 posix_spawn_hook_shared
		// 内的 trust_binary 等价，信任二进制及其依赖），再 orig_wrapper 不注入
		// systemhook（符合 roothide 屏蔽语义：隐藏越狱环境）。
		char **envc = envbuf_mutcopy((const char **)envp);
		envbuf_unsetenv(&envc, "_SafeMode");
		envbuf_unsetenv(&envc, "_MSSafeMode");

		// 信任二进制（修复 ret=-1 的根因：信任缺失）
		roothide_launchd_trust_executable(path);

		errno = 0;
		int ret = __posix_spawn_orig_wrapper(pid, path, desc, argv, envc);
		bootlog("blacklisted app %s -> orig ret=%d errno=%d (%s)", path, ret, errno, strerror(errno));
		envbuf_free(envc);
		return ret;
	}

	return posix_spawn_hook_shared(pid, path, desc, argv, envp, __posix_spawn_orig_wrapper, roothide_launchd_trust_executable, platform_set_process_debugged, jbsetting(jetsamMultiplier));
}

void initSpawnHooks(void)
{
	// build38.34: 回退 build38.29 的 prehook 接线。
	// 38.29 把入口从 __posix_spawn_hook 改为 roothide prehook，连同 posthook 一起复活了
	// RH2 整条 spawn 链。但实测（38.29~38.33）该链路在 iOS18 用户空间重启后黑屏卡死，
	// 根因是 posthook 的 DYLD_IN_CACHE=0（见上文 build38.34 注释）。
	// 38.26~38.28 仅 hook 到 __posix_spawn_hook（prehook 为死代码）时重启正常，
	// 且 3.x 的 __posix_spawn_hook 已自带 roothide 路径重映射 + ensure_jbroot_symlink（build38.27）。
	// 故恢复为 3.x 原生接线；prehook/posthook 退回死代码状态（无害）。
	litehook_hook_function(__posix_spawn, __posix_spawn_hook);
}