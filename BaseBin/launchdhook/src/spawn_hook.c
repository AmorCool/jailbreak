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

	// build38.29: 把 orig 参数从 __posix_spawn_orig_wrapper 改为 roothide posthook。
	// posthook 内部会调用 __posix_spawn_orig_wrapper，并执行 spinlock patch、DYLD_IN_CACHE=0 等
	// roothide 特有的 spawn 后处理（这些在 3.x merge 后全部丢失）。
	return posix_spawn_hook_shared(pid, path, desc, argv, envp, roothide_launchd___posix_spawn_posthook, systemwide_trust_file_by_path, platform_set_process_debugged, jbsetting(jetsamMultiplier));
}

extern int roothide_launchd___posix_spawn_prehook(pid_t *restrict pidp, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);
extern int roothide_launchd___posix_spawn_posthook(pid_t *restrict pidp, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);

void initSpawnHooks(void)
{
	// build38.29: 恢复 roothide 2.x 的 prehook/posthook 链路。
	// 3.x merge 时 initSpawnHooks 被上游覆盖为直接 hook 到 __posix_spawn_hook，
	// 导致 roothide_launchd___posix_spawn_prehook/posthook 成为死代码：
	// - ensure_jbroot_symlink 本应覆盖所有 spawn 路径（build38.22 的修复曾加在 prehook 里，
	//   但 prehook 从未被调用，所以 38.22 实际未生效，直到 build38.27 把 ensure_jbroot_symlink
	//   内联到 __posix_spawn_hook 才修好 Sileo 闪退）。
	// - posthook 里的 jbdSpawnPatchChild(spinlock fix)、DYLD_IN_CACHE=0 等逻辑完全丢失。
	// rh2 原链路：__posix_spawn -> prehook -> __posix_spawn_hook -> posix_spawn_hook_shared -> posthook(as orig) -> __posix_spawn_orig_wrapper。
	// 这里把入口改回 prehook，并把 __posix_spawn_hook 里的 orig 参数改为 posthook，
	// 从而复活整条链路，同时保留 3.x 自己的 userspace reboot / boot logo / persona fix 逻辑。
	litehook_hook_function(__posix_spawn, roothide_launchd___posix_spawn_prehook);
}