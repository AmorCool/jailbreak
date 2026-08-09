#include <libjailbreak/jbserver.h>

extern struct jbserver_domain gSystemwideDomain;
extern struct jbserver_domain gPlatformDomain;
extern struct jbserver_domain gWatchdogDomain;
extern struct jbserver_domain gRootDomain;
extern struct jbserver_domain gDopamineDomain;
extern struct jbserver_domain gRootHideDomain;

struct jbserver_impl gGlobalServer = {
	.maxDomain = 1,
	.domains = (struct jbserver_domain*[]){
		&gSystemwideDomain,   // JBS_DOMAIN_SYSTEMWIDE = 1
		&gPlatformDomain,     // JBS_DOMAIN_PLATFORM   = 2
		&gWatchdogDomain,     // JBS_DOMAIN_WATCHDOG   = 3
		&gRootDomain,         // JBS_DOMAIN_ROOT       = 4
		&gDopamineDomain,     // JBS_DOMAIN_DOPAMINE   = 5
		&gRootHideDomain,     // JBS_DOMAIN_ROOTHIDE   = 6
		NULL,
	}
};