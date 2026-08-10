// build38.25 diagnostic boot logger (header-only, no pbxproj change needed)
// Writes timestamped trace lines so we can diagnose the post-userspace-reboot
// "not jailbroken" issue after the fact.
//
// IMPORTANT: the user cannot get SSH when the device ends up "not jailbroken",
// so we must NOT rely on /var/log. We write to /var/mobile/Media which is
// reachable via AFC (3uTools / iFunBox / ifuse) even on a NON-jailbroken device.
// We try several paths and use the first one that is writable.
#ifndef BOOTLOG_H
#define BOOTLOG_H

#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

static inline FILE *bootlog_open(void)
{
	// order matters: AFC-accessible paths first, /var/log last as fallback
	static const char *paths[] = {
		"/var/mobile/Media/launchdhook_boot.log",
		"/var/mobile/Media/launchdhook_boot.log.txt",
		"/var/mobile/launchdhook_boot.log",
		"/var/log/launchdhook_boot.log",
	};
	for (int i = 0; i < (int)(sizeof(paths)/sizeof(paths[0])); i++) {
		FILE *f = fopen(paths[i], "a");
		if (f) return f;
	}
	return NULL;
}

static inline void bootlog(const char *fmt, ...)
{
	FILE *f = bootlog_open();
	if (!f) return;
	time_t t = time(NULL);
	fprintf(f, "[%ld] ", (long)t);
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fprintf(f, "\n");
	fflush(f);
	int fd = fileno(f);
	if (fd >= 0) fsync(fd);
	fclose(f);
}

#endif
