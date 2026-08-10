#include <spawn.h>
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

// build38.32: 这两个 roothide spawn hook 在 roothider.m 中定义，需在文件顶部声明，
// 因为 __posix_spawn_hook（上方）与 initSpawnHooks（下方）都会用到；
// 原先声明放在文件末尾导致 __posix_spawn_hook 使用时未声明 → 编译失败。
extern int roothide_launchd___posix_spawn_prehook(pid_t *restrict pidp, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);
extern int roothide_launchd___posix_spawn_posthook(pid_t *restrict pidp, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);

void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code, const char *reason_string, uint64_t reason_flags);

extern int systemwide_trust_file_by_path(const char *path);
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
	if (statfs("/usr/lib", &fsb) != 0) return;
	if (strcmp(fsb.f_mntonname, "/usr/lib") != 0) {
		systemwide_domain_set_enabled(true);

		// The jailbreak server is not reachable at this point in the launchd lifecycle
		// So we need to host our own, just so that jbctl can talk to it
		mach_port_t serverPort = jbserver_local_start();
		jbctl_earlyboot(serverPort, "internal", "fakelib", "mount", NULL);
		jbserver_local_stop();

		// Note down that the jailbreak was hidden
		// So that after the userspace reboot, we can unmount fakelib again
		setenv("DOPAMINE_IS_HIDDEN", "1", true);
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
	return posix_spawn_hook_shared(pid, path, desc, argv, envp, __posix_spawn_orig_wrapper, systemwide_trust_file_by_path, platform_set_process_debugged, jbsetting(jetsamMultiplier));
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