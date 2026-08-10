#include <Foundation/Foundation.h>
#include <kern_memorystatus.h>
#include <mach-o/dyld.h>
#include <libproc.h>
#include <spawn.h>

#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/roothider.h>

extern char **environ;

void jailbreakd_received_message(mach_port_t port);

int posix_spawnattr_setspecialport_np(posix_spawnattr_t *attr, mach_port_t new_port, int which);
int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t * __restrict attr, mach_port_t portarray[], uint32_t count);

void setJetsamLimit(uint32_t sizeInMB, bool is_fatal_limit)
{
	uint32_t cmd = is_fatal_limit ? MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT : MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK;
	int rc = memorystatus_control(cmd, getpid(), sizeInMB, NULL, 0);
	if (rc < 0) { perror ("memorystatus_control"); exit(rc);}
}

void enableXPCLog(void* debugLog, void* errorLog);

int main(int argc, char* argv[])
{
	// iOS 18 修复：crashreporter_start() 在独立 spawn 的进程里调 task_set_exception_ports
	// 会触发 EXC_GUARD（GUARD_TYPE_MACH_PORT, SET_EXCEPTION_BEHAVIOR on mach port 0）→ SIGKILL。
	// 真机崩溃栈：crashreporter_start → crashreporter_resume → task_set_exception_ports → EXC_GUARD。
	// crashreporter 只是崩溃日志收集，对 jailbreakd 非必需，跳过（launchdhook 注入 launchd 时不受此限制）。
	// crashreporter_start();

	setJetsamLimit(50, false);

#ifdef ENABLE_LOGS
	enableXPCLog(JBLogDebugFunction, JBLogErrorFunction);
	enableJBDLog(JBLogDebugFunction, JBLogErrorFunction);
#endif

	// roothide merge (build38.17): 在 jailbreakd 启动早期检测并注入 launchdhook。
	// 原因：iOS 17+ dyld patch 已跳过（原版 dyld），DYLD_INSERT_LIBRARIES 不再生效，
	// launchdhook 必须在 userspace reboot 后由 jailbreakd 线程注入到 launchd（pid 1）。
	// jailbreakd 有 task_for_pid-allow + thread-set-state entitlements。
	{
		char selfPathC[PATH_MAX];
		uint32_t selfPathSize = sizeof(selfPathC);
		if (_NSGetExecutablePath(selfPathC, &selfPathSize) == 0) {
			NSString *selfPath = [NSString stringWithUTF8String:selfPathC];
			NSString *jbroot = selfPath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
			NSString *launchdhookPath = [jbroot stringByAppendingPathComponent:@"basebin/launchdhook.dylib"];

			// 检查 launchdhook 是否已在 launchd 中加载（简单检查：DYLD_INSERT 是否还在 env，
			// 或者直接检查文件是否被 open——都不靠谱。直接注入，幂等无害。）
			task_t launchdTask = MACH_PORT_NULL;
			if (task_for_pid(mach_task_self(), 1, &launchdTask) == KERN_SUCCESS) {
				// dlopen 在 Shared Cache 中，跨进程地址相同
				void *dlopenPtr = dlsym(RTLD_DEFAULT, "dlopen");
				if (dlopenPtr) {
					const char *pathStr = launchdhookPath.fileSystemRepresentation;
					size_t pathLen = strlen(pathStr) + 1;

					mach_vm_address_t remoteStack = 0;
					mach_vm_address_t remotePath = 0;
					if (mach_vm_allocate(launchdTask, &remoteStack, 0x4000, VM_FLAGS_ANYWHERE) == KERN_SUCCESS &&
						mach_vm_allocate(launchdTask, &remotePath, PATH_MAX, VM_FLAGS_ANYWHERE) == KERN_SUCCESS &&
						mach_vm_write(launchdTask, remotePath, (vm_offset_t)pathStr, (mach_msg_type_number_t)pathLen) == KERN_SUCCESS) {

						arm_thread_state64_t state = {};
						state.__x[0] = (uint64_t)remotePath;
						state.__x[1] = (uint64_t)RTLD_NOW;
						state.__pc = (uint64_t)dlopenPtr;
						state.__sp = (uint64_t)(remoteStack + 0x3f00);

						thread_act_t thread = MACH_PORT_NULL;
						if (thread_create_running(launchdTask, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thread) == KERN_SUCCESS) {
							mach_port_deallocate(mach_task_self(), thread);
						} else {
							// thread_create_running not available, try thread_create + resume
							if (thread_create(launchdTask, &thread) == KERN_SUCCESS) {
								thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
								thread_resume(thread);
								mach_port_deallocate(mach_task_self(), thread);
							}
						}
					}
					mach_port_deallocate(mach_task_self(), launchdTask);
				}
			}
		}
	}

	JBLogDebug("Hello from jailbrakd! uid=%d pid=%d ppid=%d", getuid(), getpid(), getppid());

	@autoreleasepool {

		mach_port_t *registeredPorts=NULL;
		mach_msg_type_number_t registeredPortsCount = 0;
		kern_return_t kr = mach_ports_lookup(mach_task_self(), &registeredPorts, &registeredPortsCount);
		if(kr != KERN_SUCCESS || registeredPortsCount < 3) {
			JBLogError("mach_ports_lookup error: %d, %x, %s", registeredPortsCount, kr, mach_error_string(kr));
			return 1;
		}
		for(int i=0; i<registeredPortsCount; i++) {
			JBLogDebug("registeredPorts[%d]: %x", i, registeredPorts[i]);
		}

		mach_port_t bootstraport = registeredPorts[2];
		if(!MACH_PORT_VALID(bootstraport)) {
			JBLogError("invalid bootstraport");
			return 2;
		}
		JBLogDebug("bootstraport: %x", bootstraport);

		registeredPorts[2] = MACH_PORT_NULL;
		mach_ports_register(mach_task_self(), registeredPorts, registeredPortsCount);

		JBLogDebug("start initializing jb primitives");
		jbclient_xpc_set_custom_port(bootstraport);
		int ret = jbclient_initialize_primitives();
		JBLogDebug("jbclient_initialize_primitives ret: %d", ret);
		if(ret != 0) {
			JBLogError("Failed to initialize jailbreak primitives: %d", ret);
			return 3;
		}

		if(getenv("RESPAWN_REQUIRED"))
		{
			unsetenv("RESPAWN_REQUIRED");

			char selfPath[PATH_MAX]={0};
			uint32_t selfPathSize = sizeof(selfPath);
			_NSGetExecutablePath(selfPath, &selfPathSize);
	
			pid_t pid;
			posix_spawnattr_t attr = NULL;
			posix_spawnattr_init(&attr);
			posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED);
			// posix_spawnattr_setspecialport_np(&attr, bootstraport, TASK_BOOTSTRAP_PORT);
			// posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ bootstraport, MACH_PORT_NULL }, 3);
			posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ MACH_PORT_NULL, MACH_PORT_NULL, bootstraport }, 3);
			int ret = posix_spawn(&pid, selfPath, NULL, &attr, argv, environ);
			posix_spawnattr_destroy(&attr);

			if(ret != 0) {
				JBLogError("posix_spawn jailbreakd failed: %d, %s", ret, strerror(ret));
				return 4;
			}

			JBLogDebug("jailbreakd respawned: %d", pid);
	
			if(unrestrict(pid, proc_patch_dyld, false) != 0) {
				JBLogError("Failed to unrestrict process %d", pid);
				return 5;
			}

			if(dyld_patch_enabled()) {
				kill(pid, SIGCONT);
				return 0;
			} else {
				kill(pid, SIGKILL);
				waitpid(pid, NULL, 0);
			}
		}

		JBLogDebug("check in jailbreakd port...");
		mach_port_t serverPort = jbclient_jailbreakd_checkin();
		if (!MACH_PORT_VALID(serverPort)) {
			JBLogError("Failed to check in server port");
			return 6;
		}

		JBLogDebug("starting jailbreakd server, port=%x", serverPort);

		dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, (uintptr_t)serverPort, 0, dispatch_get_main_queue());
		dispatch_source_set_event_handler(source, ^{
			jailbreakd_received_message(serverPort);
		});
		dispatch_resume(source);

		dispatch_main();
	}

	JBLogDebug("jailbreakd exit...");
	return 0;
}
