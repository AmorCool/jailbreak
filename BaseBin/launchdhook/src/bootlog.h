// build38.24 diagnostic boot logger (header-only, no pbxproj change needed)
// Writes timestamped trace lines to /var/log/launchdhook_boot.log so we can
// diagnose the post-userspace-reboot "not jailbroken" issue after the fact.
// launchdhook runs as launchd (root), so /var/log is writable.
#ifndef BOOTLOG_H
#define BOOTLOG_H

#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

static inline void bootlog(const char *fmt, ...)
{
	FILE *f = fopen("/var/log/launchdhook_boot.log", "a");
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
