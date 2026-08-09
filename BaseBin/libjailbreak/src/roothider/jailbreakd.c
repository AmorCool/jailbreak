#include <spawn.h>
#include <unistd.h>
#include <assert.h>
#include <pthread.h>
#include <dlfcn.h>
#include <xpc/xpc.h>
#include <mach/mach.h>
#include <bsm/libbsm.h>
#include <sys/param.h>

#include "../libjailbreak.h"
#include "../jbserver.h"
#include "jailbreakd.h"
#include "common.h"
#include "log.h"

#ifdef ENABLE_LOGS
static void (*JBDLogDebugFunction)(const char *format, ...);
static void (*JBDLogErrorFunction)(const char *format, ...);

#define JBLogDebug(...) do { if(JBDLogDebugFunction)JBDLogDebugFunction(__VA_ARGS__); } while(0)
#define JBLogError(...) do { if(JBDLogErrorFunction)JBDLogErrorFunction(__VA_ARGS__); } while(0)

void enableJBDLog(void* debugLog, void* errorLog)
{
	JBDLogDebugFunction = debugLog;
	JBDLogErrorFunction = errorLog;
}
#endif

int posix_spawnattr_setspecialport_np(posix_spawnattr_t *attr, mach_port_t new_port, int which);
int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t * __restrict attr, mach_port_t portarray[], uint32_t count);

static bool __firstLoad = false;
static bool __jailbreakd_initialized = false;
mach_port_t gJailbreakdPort = MACH_PORT_NULL;

#define JAILBREAKD_CLIENT_PORT_FAST_GET

int registerServerPort()
{
	assert(getpid() == 1);

	// deallocate the previous port if it exists
	if(MACH_PORT_VALID(gJailbreakdPort)) {
		mach_port_deallocate(mach_task_self(), gJailbreakdPort);
		gJailbreakdPort = MACH_PORT_NULL;
	}

	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gJailbreakdPort);
	mach_port_insert_right(mach_task_self(), gJailbreakdPort, gJailbreakdPort, MACH_MSG_TYPE_MAKE_SEND);

	JBLogDebug("jailbreakd server port: %x", gJailbreakdPort);

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
	mach_port_t self_host = mach_host_self();
	kern_return_t kr = host_set_special_port(self_host, HOST_LAUNCHCTL_PORT, gJailbreakdPort);
	mach_port_deallocate(mach_task_self(), self_host);
	if (kr != KERN_SUCCESS) {
		// iOS 18 fix: HOST_LAUNCHCTL_PORT 可能被系统保护，host_set_special_port 失败。
		// FAST_GET 只是优化——客户端会降级到 jbclient_jailbreakd_lookup()（传统 XPC 查询），
		// 因此这里不致命；原代码返回 -1 会让 launchdhook 的 assert(initJailbreakd==0)
		// 崩溃 → launchd（initproc）abort → 内核 panic → 硬重启。
		JBLogError("host_set_special_port(HOST_LAUNCHCTL_PORT) failed: %x,%s (fallback to lookup)", kr, mach_error_string(kr));
	}
	return 0;
#else
	return 0;
#endif
}

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
mach_port_t jailbreakdClientPortFastGet()
{
	mach_port_t port = MACH_PORT_NULL;
	mach_port_t self_host = mach_host_self();
	kern_return_t kr = host_get_special_port(self_host, HOST_LOCAL_NODE, HOST_LAUNCHCTL_PORT, &port);
	mach_port_deallocate(mach_task_self(), self_host);
	if(kr != KERN_SUCCESS) {
		JBLogError("jailbreakdClientPortFastGet failed: %x,%s", kr, mach_error_string(kr));
		return MACH_PORT_NULL;
	}
	return port;
}
#endif

void setJailbreakdProcess(pid_t pid)
{
	//Reclaim the previous jailbreakd zombie process
	const char *pidenv = getenv("JAILBREAKD_PID");
	if (pidenv) 
	{
		pid_t oldpid = atoi(pidenv);
		if(oldpid != pid)
		{
			waitpid(oldpid, NULL, 0);
			unsetenv("JAILBREAKD_PID");
		}
	}

	char buf[32];
	snprintf(buf, sizeof(buf), "%d", pid);
	setenv("JAILBREAKD_PID", buf, 1);
}

int spawnJailbreakd()
{
	assert(getpid() == 1);

	static mach_port_t bootstraport = MACH_PORT_NULL;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
		mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &bootstraport);
		mach_port_insert_right(mach_task_self(), bootstraport, bootstraport, MACH_MSG_TYPE_MAKE_SEND);
		JBLogDebug("jailbreakd bootstrap port: %x", bootstraport);

		static dispatch_source_t source; //retain the dispatch source
		source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, (uintptr_t)bootstraport, 0, dispatch_get_global_queue(0,0));
		dispatch_source_set_event_handler(source, ^{
			JBLogDebug("received message from jailbreakd");
			xpc_object_t xdict = NULL;
			int err = xpc_pipe_receive(bootstraport, &xdict);
			if(err == 0) {
				// iOS 18 fix: 原 abort() 假设 xpchook 一定拦截 jailbreakd 的 checkin 消息。
				// iOS 18 上 xpc_pipe_receive 的接收路径可能绕过 launchdhook 的 xpc_receive_mach_msg hook，
				// 消息落入此 handler → abort() → launchd（initproc）abort → 内核 panic → 硬重启。
				// 改为交给 jbserver 处理：gGlobalServer（launchdhook 的 jbserver_global.c 导出）与
				// jbserver_received_xpc_message（libjailbreak.dylib 的 jbserver.c）在 launchdhook 进程内
				// 均可解析（launchdhook 链接 -ljailbreak）。本文件也会被编译进 systemhook.dylib
				// （不链接 libjailbreak）和 jailbreakd，故全部用 dlsym(RTLD_DEFAULT) 运行时查找，
				// 解析不到就安全跳过——避免任何 undefined symbol 链接错误。
				// 注：不能用 #pragma weak / __attribute__((weak)) 声明——Mach-O 链接器对从未在任何
				// image 定义过的符号即使 weak 声明也报 undefined symbol（build38.5 链接失败实测）。
				struct jbserver_impl *gServer = (struct jbserver_impl *)dlsym(RTLD_DEFAULT, "gGlobalServer");
				int (*receivedMsg)(struct jbserver_impl *, xpc_object_t) =
					(int (*)(struct jbserver_impl *, xpc_object_t))dlsym(RTLD_DEFAULT, "jbserver_received_xpc_message");
				if (gServer != NULL && receivedMsg != NULL) {
					receivedMsg(gServer, xdict);
				}
				xpc_release(xdict);
			}
		});
		dispatch_resume(source);
	});

	pid_t pid;
	posix_spawnattr_t attr = NULL;
	posix_spawnattr_init(&attr);
	// posix_spawnattr_setspecialport_np(&attr, bootstraport, TASK_BOOTSTRAP_PORT);
	// posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ bootstraport, MACH_PORT_NULL }, 3);
	posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){ MACH_PORT_NULL, MACH_PORT_NULL, bootstraport }, 3);
	int ret = posix_spawn(&pid, JBROOT_PATH("/basebin/jailbreakd"), NULL, &attr, (char*[]){"jailbreakd",NULL}, __firstLoad ? NULL :  ((char*[]){"RESPAWN_REQUIRED=1", NULL}));
	posix_spawnattr_destroy(&attr);

	if (ret != 0) {
		JBLogError("posix_spawn jailbreakd failed: %d\n", ret);
		return ret;
	}

	JBLogDebug("jailbreakd spawned, pid=%d\n", pid);

	/* here we can't wait for jailbreakd to initialize since opainject will suspend all other threads */
	
	setJailbreakdProcess(pid);

	return 0;
}

int initJailbreakd(bool firstLoad)
{
	assert(getpid() == 1);

	assert(__jailbreakd_initialized == false);

	__firstLoad = firstLoad;

	if(registerServerPort() != 0) {
		JBLogError("registerServerPort failed");
		return -1;
	}

	__jailbreakd_initialized = true;

	return spawnJailbreakd();
}

mach_port_t reactiveJailbreakdPort()
{
/* restarting jailbreakd may cause it to lose its previous internal state, 
	so we only use it during development. */
#ifndef ENABLE_LOGS
	//launchd_panic("jailbreakd crashed");
	abort();
#endif

	assert(getpid() == 1);

	//prevent jailbreakdClientPort from calling before initJailbreakd
	assert(__jailbreakd_initialized);

	mach_port_t port = MACH_PORT_NULL;

	static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
	pthread_mutex_lock(&mutex);

	// lock and check if another thread has reactivated the port

	kern_return_t kr = mach_port_mod_refs(mach_task_self(), gJailbreakdPort, MACH_PORT_RIGHT_SEND, 1);
	if(kr == KERN_SUCCESS) {
		port = gJailbreakdPort;
	}
	else
	{
		//make jailbreakd crashes perceptible
		sleep(5);

		//register server port before spawn jailbreakd
		if(registerServerPort() == 0)
		{
			//acquire the send right first
			kr = mach_port_mod_refs(mach_task_self(), gJailbreakdPort, MACH_PORT_RIGHT_SEND, 1);
			if(kr == KERN_SUCCESS)
			{
				port = gJailbreakdPort;

				// Try to restart jailbreakd
				if(spawnJailbreakd() != 0) {
					JBLogError("loadJailbreakd failed");
				}
			}
			else
			{
				JBLogError("jailbreakdClientPort failed");
			}
		}
		else
		{
			JBLogError("registerServerPort failed");
		}
	}

	pthread_mutex_unlock(&mutex);

	return port;
}

mach_port_t jailbreakdServerPort()
{
	assert(getpid() == 1);

	return gJailbreakdPort;
}

mach_port_t jailbreakdClientPort()
{
	mach_port_t port = MACH_PORT_NULL;

	if(getpid() == 1)
	{
		kern_return_t kr = mach_port_mod_refs(mach_task_self(), gJailbreakdPort, MACH_PORT_RIGHT_SEND, 1);
		if(kr == KERN_SUCCESS) {
			port = gJailbreakdPort;
		} else {
			JBLogError("jailbreakd port dead: %x,%s port=%x", kr, mach_error_string(kr), gJailbreakdPort);		
			port = reactiveJailbreakdPort();
		}
	}
	else
	{

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
		port = jailbreakdClientPortFastGet();
		if(!MACH_PORT_VALID(port))
		{
#endif

			port = jbclient_jailbreakd_lookup();

#ifdef JAILBREAKD_CLIENT_PORT_FAST_GET
		}
#endif

	}

	return port;
}

// xpc_object_t jailbreakdRequestViaLaunchd(xpc_object_t xdict)
// {
// 	// to do
// }

xpc_object_t jailbreakdXpcRequest(xpc_object_t xdict)
{
	mach_port_t port = jailbreakdClientPort();
	if (!MACH_PORT_VALID(port)) {
		JBLogError("invalid jailbreakdClientPort: %x", port);
		return NULL;
	}
	
	xpc_object_t xreply = NULL;
	xpc_object_t pipe = xpc_pipe_create_from_port(port, 0);
	if (pipe) {
		int err = xpc_pipe_routine(pipe, xdict, &xreply);
		if (err != 0) {
			char *desc = NULL;
			JBLogError("xpc_pipe_routine error on sending message to jailbreakd: %d / %s\n%s", err, xpc_strerror(err), (desc=xpc_copy_description(xdict)));
			if(desc) free(desc);
			if(xreply) xpc_release(xreply);
			xreply = NULL;
		};
	} else {
		JBLogError("xpc_pipe_create_from_port failed");
	}

	mach_port_deallocate(mach_task_self(), port);

	xpc_release(pipe);
	return xreply;
}

int jbdTestCall(int value)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_TEST_CALL);
	xpc_dictionary_set_int64(message, "value", value);

	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}

int jbdSystemwideLog(const char* fmt, ...)
{
	char* log = NULL;

	va_list args;
	va_start(args, fmt);
	vasprintf(&log, fmt, args);
	va_end(args);

	__uint64_t tid = 0;
	pthread_threadid_np(pthread_self(), &tid);

	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SYSTEMWIDE_LOG);
	xpc_dictionary_set_uint64(message, "tid", tid);
	xpc_dictionary_set_string(message, "log", log);

	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	free(log);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}

int jbdSpawnPatchChild(int pid, bool resume)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPAWN_PATCH_CHILD);
	xpc_dictionary_set_int64(message, "pid", pid);
	xpc_dictionary_set_bool(message, "resume", resume);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdSpinlockFixOnly(int pid, bool resume)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPINLOCK_FIX_ONLY);
	xpc_dictionary_set_int64(message, "pid", pid);
	xpc_dictionary_set_bool(message, "resume", resume);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdSpawnExecStart(const char* execfile, bool resume)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPAWN_EXEC_START);
	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_dictionary_set_bool(message, "resume", resume);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdSpawnExecCancel(const char* execfile)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_SPAWN_EXEC_CANCEL);
	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);
	int64_t result = -1;
	if (reply) {
		result  = xpc_dictionary_get_int64(reply, "result");
		xpc_release(reply);
	}
	return result;
}

int jbdExecTraceStart(const char* execfile, bool* traced)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_EXEC_TRACE_START);

	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_dictionary_set_uint64(message, "traced", (uint64_t)(void*)traced);

	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}

int jbdExecTraceCancel(const char* execfile, bool* detached)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_uint64(message, "id", JBD_MSG_EXEC_TRACE_CANCEL);

	xpc_dictionary_set_string(message, "execfile", execfile);
	xpc_dictionary_set_uint64(message, "detached", (uint64_t)(void*)detached);
	xpc_object_t reply = jailbreakdXpcRequest(message);
	xpc_release(message);

	if (!reply) return -100;

	int result = xpc_dictionary_get_int64(reply, "result");
	xpc_release(reply);
	return result;
}
