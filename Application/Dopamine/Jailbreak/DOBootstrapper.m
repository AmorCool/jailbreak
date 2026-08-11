//
//  Bootstrapper.m
//  Dopamine
//
//  Created by Lars Fröder on 09.01.24.
//

#import "DOBootstrapper.h"
#import "DOBootstrapper+zstd.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"
#import <libjailbreak/info.h>
#import <libjailbreak/util.h>
#import <libjailbreak/jbclient_xpc.h>
#import <libjailbreak/trustcache_fs.h>
#import <sys/mount.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <signal.h>
#import "NSString+Version.h"

#define LIBKRW_DOPAMINE_BUNDLED_VERSION @"2.0.3"
#define LIBROOT_DOPAMINE_BUNDLED_VERSION @"1.0.1"
#define BASEBIN_LINK_BUNDLED_VERSION @"1.0.0"
#define LAUNCHCTL_BUNDLED_VERSION @"1:1.2.0"

static NSDictionary *gBundledPackages = @{
    @"libkrw0-dopamine" : LIBKRW_DOPAMINE_BUNDLED_VERSION,
    @"libroot-dopamine" : LIBROOT_DOPAMINE_BUNDLED_VERSION,
    @"dopamine-basebin-link" : BASEBIN_LINK_BUNDLED_VERSION,
    @"launchctl" : LAUNCHCTL_BUNDLED_VERSION,
};

struct hfs_mount_args {
    char    *fspec;
    uid_t    hfs_uid;        /* uid that owns hfs files (standard HFS only) */
    gid_t    hfs_gid;        /* gid that owns hfs files (standard HFS only) */
    mode_t    hfs_mask;        /* mask to be applied for hfs perms  (standard HFS only) */
    uint32_t hfs_encoding;        /* encoding for this volume (standard HFS only) */
    struct    timezone hfs_timezone;    /* user time zone info (standard HFS only) */
    int        flags;            /* mounting flags, see below */
    int     journal_tbuffer_size;   /* size in bytes of the journal transaction buffer */
    int        journal_flags;          /* flags to pass to journal_open/create */
    int        journal_disable;        /* don't use journaling (potentially dangerous) */
};

NSString *const bootstrapErrorDomain = @"BootstrapErrorDomain";

/* ============ roothide specific: jbrand random jbroot path mechanism (from roothide 2.x DOBootstrapper.m) ============ */

uint64_t jbrand_new();
uint64_t jbrand_current();
int is_jbroot_name(char* name);
NSString* find_jbroot(BOOL force);
NSString* jbrootPrefix(NSString *path);
NSString* rootfsPrefix(NSString* path);

uint64_t jbrand_new()
{
    uint64_t value = ((uint64_t)arc4random()) | ((uint64_t)arc4random())<<32;
    uint8_t check = value>>8 ^ value >> 16 ^ value>>24 ^ value>>32 ^ value>>40 ^ value>>48 ^ value>>56;
    return (value & ~0xFF) | check;
}

int is_jbrand_value(uint64_t value)
{
   uint8_t check = value>>8 ^ value >> 16 ^ value>>24 ^ value>>32 ^ value>>40 ^ value>>48 ^ value>>56;
   return check == (uint8_t)value;
}

#define JB_ROOT_PREFIX ".jbroot-"
#define JB_RAND_LENGTH  (sizeof(uint64_t)*sizeof(char)*2)

int is_jbroot_name(char* name)
{
    if(strlen(name) != (sizeof(JB_ROOT_PREFIX)-1+JB_RAND_LENGTH))
        return 0;
    
    if(strncmp(name, JB_ROOT_PREFIX, sizeof(JB_ROOT_PREFIX)-1) != 0)
        return 0;
    
    char* endp=NULL;
    uint64_t value = strtoull(name+sizeof(JB_ROOT_PREFIX)-1, &endp, 16);
    if(!endp || *endp!='\0')
        return 0;
    
    if(!is_jbrand_value(value))
        return 0;
    
    return 1;
}

uint64_t resolve_jbrand_value(const char* name)
{
    if(strlen(name) != (sizeof(JB_ROOT_PREFIX)-1+JB_RAND_LENGTH))
        return 0;
    
    if(strncmp(name, JB_ROOT_PREFIX, sizeof(JB_ROOT_PREFIX)-1) != 0)
        return 0;
    
    char* endp=NULL;
    uint64_t value = strtoull(name+sizeof(JB_ROOT_PREFIX)-1, &endp, 16);
    if(!endp || *endp!='\0')
        return 0;
    
    if(!is_jbrand_value(value))
        return 0;
    
    return value;
}

NSString* find_jbroot(BOOL force)
{
    static NSString* cached_jbroot = nil;
    if(!force && cached_jbroot) {
        return cached_jbroot;
    }
    @synchronized(@"find_jbroot_lock")
    {
        //jbroot path may change when re-randomize it
        NSString * jbroot = nil;
        NSArray *subItems = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application/" error:nil];
        for (NSString *subItem in subItems) {
            if (is_jbroot_name(subItem.UTF8String))
            {
                NSString* path = [@"/var/containers/Bundle/Application/" stringByAppendingPathComponent:subItem];
                jbroot = path;
                break;
            }
        }
        cached_jbroot = jbroot;
    }
    return cached_jbroot;
}

uint64_t jbrand_current()
{
    NSString* jbroot = find_jbroot(NO);
    assert(jbroot != NULL);
    return resolve_jbrand_value([jbroot lastPathComponent].UTF8String);
}

NSString* jbrootPrefix(NSString *path)
{
    if(!path || path.UTF8String[0]!='/') {
        return path;
    }
    NSString* jbroot = find_jbroot(NO);
    assert(jbroot != NULL); //to avoid [nil stringByAppendingString:
    return [jbroot stringByAppendingPathComponent:path];
}

NSString* rootfsPrefix(NSString* path)
{
    if(!path || path.UTF8String[0]!='/') {
        return path;
    }
    return [@"/rootfs/" stringByAppendingPathComponent:path];
}

/* ============ roothide specific: package sources (incl. roothide official repos) ============ */

int getCFMajorVersion(void)
{
    if(@available(iOS 16.0, *)) {
        return 1900;
    }
    
    return ((int)kCFCoreFoundationVersionNumber / 100) * 100;
}

#define DEFAULT_SOURCES "\
Types: deb\n\
URIs: https://yourepo.com/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: https://repo.chariz.com/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: https://havoc.app/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: http://apt.thebigboss.org/repofiles/cydia/\n\
Suites: stable\n\
Components: main\n\
\n\
Types: deb\n\
URIs: https://roothide.github.io/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: https://roothide.github.io/procursus\n\
Suites: iphoneos-arm64e/%d\n\
Components: main\n\
\n\
Types: deb\n\
URIs: https://github.com/roothide/roothide.github.io/releases/download/%d/\n\
Suites: ./\n\
Components:\n\
"

#define ZEBRA_SOURCES "\
# Zebra Sources List\n\
deb https://getzbra.com/repo/ ./\n\
deb https://repo.chariz.com/ ./\n\
deb https://yourepo.com/ ./\n\
deb https://havoc.app/ ./\n\
deb https://roothide.github.io/ ./\n\
deb https://roothide.github.io/procursus iphoneos-arm64e/%d main\n\
deb https://github.com/roothide/roothide.github.io/releases/download/%d/ ./\n\
\n\
"

/* ============ end roothide specific ============ */

@implementation DOBootstrapper

- (instancetype)init
{
    self = [super init];
    if (self) {
        /*NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.opa334.bootstrapper.background-session"];
        _urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];*/
    }
    return self;
}

- (NSError *)extractTar:(NSString *)tarPath toPath:(NSString *)destinationPath
{
    int r = libarchive_unarchive(tarPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation);
    if (r != 0) {
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"libarchive returned %d", r]}];
    }
    return nil;
}

- (BOOL)deleteSymlinkAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:error];
    if (!attributes) return YES;
    if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
        return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
    }
    return NO;
}

- (BOOL)fileOrSymlinkExistsAtPath:(NSString *)path
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attributes) {
        if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
            return YES;
        }
    }
    
    return NO;
}

- (NSError *)createSymlinkAtPath:(NSString *)path toPath:(NSString *)destinationPath createIntermediateDirectories:(BOOL)createIntermediate
{
    NSError *error;
    NSString *parentPath = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] fileExistsAtPath:parentPath]) {
        if (!createIntermediate) return [NSError errorWithDomain:bootstrapErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed create %@->%@ symlink: Parent dir does not exists", path, destinationPath]}];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error]) return error;
    }
    
    [[NSFileManager defaultManager] createSymbolicLinkAtPath:path withDestinationPath:destinationPath error:&error];
    return error;
}

- (BOOL)isPrivatePrebootMountedWritable
{
    struct statfs ppStfs;
    statfs([[DOEnvironmentManager sharedManager] privatePrebootPath].fileSystemRepresentation, &ppStfs);
    return !(ppStfs.f_flags & MNT_RDONLY);
}

- (int)remountPrivatePrebootWritable:(BOOL)writable
{
    const char *ppPath = [[DOEnvironmentManager sharedManager] privatePrebootPath].fileSystemRepresentation;

    struct statfs ppStfs;
    int r = statfs(ppPath, &ppStfs);
    if (r != 0) return r;
    
    uint32_t flags = MNT_UPDATE;
    if (!writable) {
        flags |= MNT_RDONLY;
    }
    struct hfs_mount_args mntargs =
    {
        .fspec = ppStfs.f_mntfromname,
        .hfs_mask = 0,
    };
    return mount("apfs", ppPath, flags, &mntargs);
}

- (NSError *)ensurePrivatePrebootIsWritable
{
    if (![self isPrivatePrebootMountedWritable]) {
        int r = [self remountPrivatePrebootWritable:YES];
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedRemount userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Remounting /private/preboot as writable failed with error: %s", strerror(errno)]}];
        }
    }
    return nil;
}

- (void)fixupPathPermissions
{
    // Ensure the following paths are owned by root:wheel and have permissions of 755:
    // /private
    // /private/preboot
    // /private/preboot/UUID
    // /private/preboot/UUID/dopamine-<UUID>
    // /private/preboot/UUID/dopamine-<UUID>/procursus

    NSString *tmpPath = JBROOT_PATH(@"/");
    while (![tmpPath isEqualToString:@"/"]) {
        struct stat s;
        stat(tmpPath.fileSystemRepresentation, &s);
        if (s.st_uid != 0 || s.st_gid != 0) {
            chown(tmpPath.fileSystemRepresentation, 0, 0);
        }
        if ((s.st_mode & S_IRWXU) != 0755) {
            chmod(tmpPath.fileSystemRepresentation, 0755);
        }
        tmpPath = [tmpPath stringByDeletingLastPathComponent];
    }
}

- (void)patchBasebinDaemonPlist:(NSString *)plistPath
{
    NSMutableDictionary *plistDict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (plistDict) {
        bool madeChanges = NO;
        NSMutableArray *programArguments = ((NSArray *)plistDict[@"ProgramArguments"]).mutableCopy;
        for (NSString *argument in [programArguments reverseObjectEnumerator]) {
            if ([argument containsString:@"@JBROOT@"]) {
                programArguments[[programArguments indexOfObject:argument]] = [argument stringByReplacingOccurrencesOfString:@"@JBROOT@" withString:JBROOT_PATH(@"/")];
                madeChanges = YES;
            }
        }
        if (madeChanges) {
            plistDict[@"ProgramArguments"] = programArguments.copy;
            [plistDict writeToFile:plistPath atomically:NO];
        }
    }
}

- (void)patchBasebinDaemonPlists
{
    NSURL *basebinDaemonsURL = [NSURL fileURLWithPath:JBROOT_PATH(@"/basebin/LaunchDaemons")];
    for (NSURL *basebinDaemonURL in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:basebinDaemonsURL includingPropertiesForKeys:nil options:0 error:nil]) {
        [self patchBasebinDaemonPlist:basebinDaemonURL.path];
    }
}

- (NSString *)bootstrapVersion
{
    uint64_t cfver = (((uint64_t)kCFCoreFoundationVersionNumber / 100) * 100);
    if (cfver >= 2000) {
        return @"1900";
    }
    return [NSString stringWithFormat:@"%llu", cfver];
}

- (NSURL *)bootstrapURL
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://apt.procurs.us/bootstraps/%@/bootstrap-ssh-iphoneos-arm64.tar.zst", [self bootstrapVersion]]];
}

/*- (void)downloadBootstrapWithCompletion:(void (^)(NSString *path, NSError *error))completion
{
    NSURL *bootstrapURL = [self bootstrapURL];
    if (!bootstrapURL) {
        completion(nil, [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedToGetURL userInfo:@{NSLocalizedDescriptionKey : @"Failed to obtain bootstrap URL"}]);
        return;
    }
    
    _downloadCompletionBlock = ^(NSURL * _Nullable location, NSError * _Nullable error) {
        NSError *ourError;
        if (error) {
            ourError = [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedToDownload userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to download bootstrap: %@", error.localizedDescription]}];
        }
        completion(location.path, ourError);
    };
    
    _bootstrapDownloadTask = [_urlSession downloadTaskWithURL:bootstrapURL];
    [_bootstrapDownloadTask resume];
}*/

- (NSError *)ensureJbrandRootExists
{
    // roothide specific: jbroot 位于 /var/containers/Bundle/Application/.jbroot-<random jbrand>
    // （3.x 原本用 /private/preboot/dopamine-xxx/procursus 固定前缀；roothide 的"藏"要求
    //  随机 jbrand 路径，每次重装/重随机化都变，App 检测不到固定特征）
    NSString *jbrootPath = find_jbroot(NO);
    if (!jbrootPath) {
        jbrootPath = [NSString stringWithFormat:@"/var/containers/Bundle/Application/.jbroot-%016llX", jbrand_new()];
        if (mkdir(jbrootPath.fileSystemRepresentation, 0755) != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Creating jbroot failed: %s", strerror(errno)]}];
        }
        if (chown(jbrootPath.fileSystemRepresentation, 0, 0) != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"chown jbroot failed: %s", strerror(errno)]}];
        }
        find_jbroot(YES); // refresh cache
    }
    
    if (gSystemInfo.jailbreakInfo.rootPath) free(gSystemInfo.jailbreakInfo.rootPath);
    gSystemInfo.jailbreakInfo.rootPath = strdup(jbrootPath.UTF8String);
    gSystemInfo.jailbreakInfo.jbrand = jbrand_current();
    
    return nil;
}

- (int)buildPackageSources:(void (^)(NSError *))completion
{
    // roothide specific: 写入含 roothide 官方源的包源列表（3.x 原版没有 roothide 源）
    NSFileManager* fm = NSFileManager.defaultManager;
    
    if([[NSString stringWithFormat:@(DEFAULT_SOURCES), getCFMajorVersion(), getCFMajorVersion()] writeToFile:jbrootPrefix(@"/etc/apt/sources.list.d/default.sources") atomically:YES encoding:NSUTF8StringEncoding error:nil] == NO) {
        completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : @"Failed to write default.sources"}]);
        return -1;
    }
    
    if(![fm fileExistsAtPath:jbrootPrefix(@"/var/mobile/Library/Application Support/xyz.willy.Zebra")])
    {
        NSDictionary* attr = @{NSFilePosixPermissions:@(0755), NSFileOwnerAccountID:@(501), NSFileGroupOwnerAccountID:@(501)};
        [fm createDirectoryAtPath:jbrootPrefix(@"/var/mobile/Library/Application Support/xyz.willy.Zebra") withIntermediateDirectories:YES attributes:attr error:nil];
    }
    
    if([[NSString stringWithFormat:@(ZEBRA_SOURCES), getCFMajorVersion(), getCFMajorVersion()] writeToFile:jbrootPrefix(@"/var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list") atomically:YES encoding:NSUTF8StringEncoding error:nil] == NO) {
        completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : @"Failed to write Zebra sources.list"}]);
        return -1;
    }
    
    return 0;
}

- (void)hideJbrootVarToAppGroup:(NSString *)jbrootPath
{
    // roothide specific: 把 jbroot 的可写数据（/var）藏到 AppGroup 目录，
    // jbroot 里只留符号链接——目录结构更不显眼，是"藏"的一部分
    // （原逻辑来自 rh2 InstallBootstrap，jbroot_secondary 同样用随机 jbrand 命名）
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *jbrootSecondary = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX", jbrand_current()];
    
    if (![fm fileExistsAtPath:jbrootSecondary]) {
        mkdir(jbrootSecondary.fileSystemRepresentation, 0755);
        chown(jbrootSecondary.fileSystemRepresentation, 0, 0);
    }
    
    NSString *jbrootVar = [jbrootPath stringByAppendingPathComponent:@"/var"];
    if ([fm fileExistsAtPath:jbrootVar] && ![fm fileExistsAtPath:[jbrootSecondary stringByAppendingPathComponent:@"/var"]]) {
        [fm moveItemAtPath:jbrootVar toPath:[jbrootSecondary stringByAppendingPathComponent:@"/var"] error:nil];
    }
    
    // jbroot/var -> private/var -> AppGroup/var
    [fm removeItemAtPath:[jbrootPath stringByAppendingPathComponent:@"/private/var"] error:nil];
    [fm createSymbolicLinkAtPath:[jbrootPath stringByAppendingPathComponent:@"/private/var"] withDestinationPath:[jbrootSecondary stringByAppendingPathComponent:@"/var"] error:nil];
    [fm createSymbolicLinkAtPath:jbrootVar withDestinationPath:@"private/var" error:nil];
    
    // jbroot/tmp -> AppGroup/var/tmp
    [fm removeItemAtPath:[jbrootSecondary stringByAppendingPathComponent:@"/var/tmp"] error:nil];
    if ([fm fileExistsAtPath:[jbrootPath stringByAppendingPathComponent:@"/tmp"]]) {
        [fm moveItemAtPath:[jbrootPath stringByAppendingPathComponent:@"/tmp"] toPath:[jbrootSecondary stringByAppendingPathComponent:@"/var/tmp"] error:nil];
    }
    [fm createSymbolicLinkAtPath:[jbrootPath stringByAppendingPathComponent:@"/tmp"] withDestinationPath:@"var/tmp" error:nil];

    // 对齐 roothide 2.x (rh2 DOBootstrapper.m:1012):
    // jbrootSecondary/.jbroot 自指链接。/var 搬到 AppGroup 后，
    // /var/lib/dpkg -> .jbroot/Library/dpkg 这条链需要 jbrootSecondary/.jbroot
    // 指向真实 jbroot，否则 dpkg/apt 访问 /var/lib/dpkg 会断链，
    // Sileo 报 "/var/lib/dpkg/lock-frontend" 错误。
    [self ensureJbrootSelfLink];
}

- (void)ensureJbrootSelfLink
{
    // 幂等地确保 AppGroup 隐藏副本目录的 .jbroot 自指链接存在且指向当前 jbroot。
    // jbrand 变化（重启）后旧链接会失效，必须在每次越狱时校验/重建。
    NSString *jbrootPath = [NSString stringWithUTF8String:get_jbroot() ?: ""];
    if (!jbrootPath.length) return;
    NSString *jbrootSecondary = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX", jbrand_current()];
    NSString *selfLink = [jbrootSecondary stringByAppendingPathComponent:@".jbroot"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:selfLink]) {
        // 指向已变（jbrand 变化）则重建
        NSString *dest = [fm destinationOfSymbolicLinkAtPath:selfLink error:nil];
        if (![dest isEqualToString:jbrootPath]) {
            [fm removeItemAtPath:selfLink error:nil];
        }
    }
    if (![fm fileExistsAtPath:selfLink]) {
        [fm createSymbolicLinkAtPath:selfLink withDestinationPath:jbrootPath error:nil];
    }
}

- (void)extractBootstrap:(NSString *)path withCompletion:(void (^)(NSError *))completion
{
    NSString *bootstrapTar = [@"/var/tmp" stringByAppendingPathComponent:@"bootstrap.tar"];
    NSError *decompressionError = [self decompressZstd:path toTar:bootstrapTar];
    if (decompressionError) {
        completion(decompressionError);
        return;
    }
    
    // roothide specific: 解压到随机 jbrand jbroot 路径（rh2 方式）
    // roothide 的 bootstrap 是相对 jbroot 结构（./usr ./var），
    // 官方 rootless bootstrap（/var/jb 前缀）与 jbrand 机制不兼容
    NSString *jbrootPath = find_jbroot(NO);
    if (!jbrootPath) {
        completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : @"Failed to locate jbroot for bootstrap extraction"}]);
        return;
    }
    
    decompressionError = [self extractTar:bootstrapTar toPath:jbrootPath];
    if (decompressionError) {
        completion(decompressionError);
        return;
    }
    
    // roothide specific: var 数据藏到 AppGroup
    [self hideJbrootVarToAppGroup:jbrootPath];
    
    [[NSData data] writeToFile:JBROOT_PATH(@"/.installed_dopamine") atomically:YES];
    completion(nil);
}

- (NSError *)updateVarJbSymlink
{
    // Remove /var/jb as it might be wrong
    NSError *error;
    if (![self deleteSymlinkAtPath:@"/var/jb" error:&error]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
            if (![[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:&error]) {
                return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/jb directory failed with error: %@", error]}];
            }
        }
        else {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/jb symlink failed with error: %@", error]}];
        }
    }

    return [self createSymlinkAtPath:@"/var/jb" toPath:JBROOT_PATH(@"/") createIntermediateDirectories:YES];;
}

- (void)prepareBootstrapWithCompletion:(void (^)(NSError *))completion
{
    [[DOUIManager sharedInstance] sendLog:@"Updating BaseBin" debug:NO];

    // Ensure /private/preboot is mounted writable (Not writable by default on iOS <=15)
    NSError *error = [self ensurePrivatePrebootIsWritable];
    if (error) {
        completion(error);
        return;
    }
    
    [self fixupPathPermissions];
    
    // Clean up xinaA15 v1 leftovers if desired
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/.keep_symlinks"]) {
        NSArray *xinaLeftoverSymlinks = @[
            @"/var/alternatives",
            @"/var/ap",
            @"/var/apt",
            @"/var/bin",
            @"/var/bzip2",
            @"/var/cache",
            @"/var/dpkg",
            @"/var/etc",
            @"/var/gzip",
            @"/var/lib",
            @"/var/Lib",
            @"/var/libexec",
            @"/var/Library",
            @"/var/LIY",
            @"/var/Liy",
            @"/var/local",
            @"/var/newuser",
            @"/var/profile",
            @"/var/sbin",
            @"/var/suid_profile",
            @"/var/sh",
            @"/var/sy",
            @"/var/share",
            @"/var/ssh",
            @"/var/sudo_logsrvd.conf",
            @"/var/suid_profile",
            @"/var/sy",
            @"/var/usr",
            @"/var/zlogin",
            @"/var/zlogout",
            @"/var/zprofile",
            @"/var/zshenv",
            @"/var/zshrc",
            @"/var/log/dpkg",
            @"/var/log/apt",
        ];
        NSArray *xinaLeftoverFiles = @[
            @"/var/lib",
            @"/var/master.passwd"
        ];
        
        for (NSString *xinaLeftoverSymlink in xinaLeftoverSymlinks) {
            [self deleteSymlinkAtPath:xinaLeftoverSymlink error:nil];
        }
        
        for (NSString *xinaLeftoverFile in xinaLeftoverFiles) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:xinaLeftoverFile]) {
                [[NSFileManager defaultManager] removeItemAtPath:xinaLeftoverFile error:nil];
            }
        }
    }
    
    NSString *basebinPath = JBROOT_PATH(@"/basebin");
    NSString *installedPath = JBROOT_PATH(@"/.installed_dopamine");
    error = [self updateVarJbSymlink];
    if (error) {
        completion(error);
        return;
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:basebinPath]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:basebinPath error:&error]) {
            completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed deleting existing basebin file with error: %@", error.localizedDescription]}]);
            return;
        }
    }
    error = [self extractTar:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"] toPath:JBROOT_PATH(@"/")];
    if (error) {
        completion(error);
        return;
    }
    [self patchBasebinDaemonPlists];
    
    void (^bootstrapFinishedCompletion)(NSError *) = ^(NSError *error){
        if (error) {
            completion(error);
            return;
        }
        
        // roothide specific: 源列表含 roothide 官方源（3.x 原版只有 rootless.002599.xyz 等）
        NSString *defaultSources = [NSString stringWithFormat:@(DEFAULT_SOURCES), getCFMajorVersion(), getCFMajorVersion()];
        [defaultSources writeToFile:JBROOT_PATH(@"/etc/apt/sources.list.d/default.sources") atomically:NO encoding:NSUTF8StringEncoding error:nil];
        
        // roothide specific: Zebra 源列表（rh2 同样写入）
        NSString *zebraSources = [NSString stringWithFormat:@(ZEBRA_SOURCES), getCFMajorVersion(), getCFMajorVersion()];
        [zebraSources writeToFile:JBROOT_PATH(@"/var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list") atomically:NO encoding:NSUTF8StringEncoding error:nil];
        
        NSString *mobilePreferencesPath = JBROOT_PATH(@"/var/mobile/Library/Preferences");
        if (![[NSFileManager defaultManager] fileExistsAtPath:mobilePreferencesPath]) {
            NSDictionary<NSFileAttributeKey, id> *attributes = @{
                NSFilePosixPermissions : @0755,
                NSFileOwnerAccountID : @501,
                NSFileGroupOwnerAccountID : @501,
            };
            [[NSFileManager defaultManager] createDirectoryAtPath:mobilePreferencesPath withIntermediateDirectories:YES attributes:attributes error:nil];
        }
        
        JBFixMobilePermissions();

        // Add setuid bit to jbctl
        // Allows us in the end to reboot userspace after we're already mobile
        chmod(JBROOT_PATH("/basebin/jbctl"), S_ISUID | 0755);

        completion(nil);
    };
    
    
    BOOL needsBootstrap = ![[NSFileManager defaultManager] fileExistsAtPath:installedPath];
    if (needsBootstrap) {
        // First, wipe any existing content that's not basebin
        for (NSURL *subItemURL in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:JBROOT_PATH(@"/")] includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![subItemURL.lastPathComponent isEqualToString:@"basebin"]) {
                [[NSFileManager defaultManager] removeItemAtURL:subItemURL error:nil];
            }
        }
        
        /*void (^bootstrapDownloadCompletion)(NSString *, NSError *) = ^(NSString *path, NSError *error) {
            if (error) {
                completion(error);
                return;
            }
            [self extractBootstrap:path withCompletion:bootstrapFinishedCompletion];
        };*/
        
        [[DOUIManager sharedInstance] sendLog:@"Extracting Bootstrap" debug:NO];

        NSString *bootstrapZstdPath = [NSString stringWithFormat:@"%@/bootstrap_%@.tar.zst", [NSBundle mainBundle].bundlePath, [self bootstrapVersion]];
        [self extractBootstrap:bootstrapZstdPath withCompletion:bootstrapFinishedCompletion];

        /*NSString *documentsCandidate = @"/var/mobile/Documents/bootstrap.tar.zstd";
        NSString *bundleCandidate = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"bootstrap.tar.zstd"];
        // Check if the user provided a bootstrap
        if ([[NSFileManager defaultManager] fileExistsAtPath:documentsCandidate]) {
            bootstrapDownloadCompletion(documentsCandidate, nil);
        }
        else if ([[NSFileManager defaultManager] fileExistsAtPath:bundleCandidate]) {
            bootstrapDownloadCompletion(bundleCandidate, nil);
        }
        else {
            [[DOUIManager sharedInstance] sendLog:@"Downloading Bootstrap" debug:NO];
            [self downloadBootstrapWithCompletion:bootstrapDownloadCompletion];
        }*/
    }
    else {
        bootstrapFinishedCompletion(nil);
    }
}

- (int)installPackage:(NSString *)packagePath
{
    if (getuid() == 0) {
        // roothide specific: --force-depends 绕过依赖检查（如 sileo 依赖的 firmware 包
        // 不在 roothide bootstrap 里，dpkg 默认拒绝配置；firmware 只是固件版本标记包，
        // 运行时不需要，后续从源里更新时会自动补装）
        // build38.37: 带超时——installPackage 也被 launchctl/basebin-link 等分支共用，
        // 无超时的 exec_cmd_trusted 同步 waitpid 卡住 → 看门狗杀 app（闪退）。
        return [self execTrustedWithTimeout:15.0 binary:JBROOT_PATH(@"/usr/bin/dpkg") arguments:@[@"--force-depends", @"-i", packagePath]];
    }
    else {
        // idk why but waitpid sometimes fails and this returns -1, so we just ignore the return value
        exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "install_pkg", packagePath.fileSystemRepresentation, NULL);
        return 0;
    }
}

// build38.36: 带超时的 trusted exec。
// 背景：用户设备历史上 dpkg 中断过（updates/ journal 残留 → Sileo 弹“dpkg 被中断”），
// 38.35 在 finalize 里新增 3 个 dpkg -i + --configure -a 后，若 dpkg 锁/半状态导致
// 子进程卡住，exec_cmd 的同步 waitpid 会永久阻塞 → Dopamine app 无响应 →
// iOS 看门狗杀 app → 表现为“Fixing roothide 流程闪退、重开显示已越狱”。
// 这里给所有关键 dpkg 调用加超时：超时后 SIGKILL 子进程并返回 124（timeout 约定），
// 调用方容忍处理，保证 finalize 永不永久阻塞。
- (int)execTrustedWithTimeout:(double)timeoutSeconds binary:(NSString *)binary arguments:(NSArray<NSString *> *)arguments
{
    jbclient_trust_file_by_path(binary.fileSystemRepresentation);

    NSMutableArray<NSString *> *allArgs = [NSMutableArray arrayWithObject:binary];
    [allArgs addObjectsFromArray:arguments];

    char **argv = calloc(allArgs.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < allArgs.count; i++) {
        argv[i] = strdup(allArgs[i].fileSystemRepresentation);
    }
    argv[allArgs.count] = NULL;

    pid_t pid = 0;
    // build38.37: envp 必须传 environ（与 exec_cmd 一致）。
    // 38.36 传 NULL → 子进程环境为空 → dpkg 找不到 JBROOT/PATH/动态库 → 各种诡异失败。
    extern char **environ;
    int spawnError = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    for (NSUInteger i = 0; i < allArgs.count; i++) free(argv[i]);
    free(argv);

    if (spawnError != 0 || pid <= 0) return spawnError;

    double waited = 0.0;
    int status = 0;
    while (waited < timeoutSeconds) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
            return -1;
        }
        usleep(50000); // 50ms
        waited += 0.05;
    }

    // 超时：杀掉子进程，避免 finalize 永久阻塞
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    NSLog(@"[Dopamine] exec timed out after %.0fs, killed pid %d: %@ %@", timeoutSeconds, pid, binary, arguments);
    return 124;
}


- (int)uninstallPackageWithIdentifier:(NSString *)identifier
{
    return exec_cmd_trusted(JBROOT_PATH("/usr/bin/dpkg"), "-r", identifier.UTF8String, NULL);
}

- (NSString *)installedVersionForPackageWithIdentifier:(NSString *)identifier
{
    NSString *dpkgStatus = [NSString stringWithContentsOfFile:JBROOT_PATH(@"/var/lib/dpkg/status") encoding:NSUTF8StringEncoding error:nil];
    NSString *packageStartLine = [NSString stringWithFormat:@"Package: %@", identifier];
    
    NSArray *packageInfos = [dpkgStatus componentsSeparatedByString:@"\n\n"];
    for (NSString *packageInfo in packageInfos) {
        if ([packageInfo hasPrefix:packageStartLine]) {
            __block NSString *version = nil;
            [packageInfo enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
                if ([line hasPrefix:@"Version: "]) {
                    version = [line substringFromIndex:9];
                }
            }];
            return version;
        }
    }
    return nil;
}

- (NSError *)installPackageManagers
{
    NSArray *enabledPackageManagers = [[DOUIManager sharedInstance] enabledPackageManagers];
    for (NSDictionary *packageManagerDict in enabledPackageManagers) {
        NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:packageManagerDict[@"Package"]];
        NSString *name = packageManagerDict[@"Display Name"];
        // build38.36: 带超时（sileo.deb ~4MB，给足 120s；超时杀进程不再阻塞 finalize）
        int r = [self execTrustedWithTimeout:15.0 binary:JBROOT_PATH(@"/usr/bin/dpkg") arguments:@[@"--force-depends", @"-i", path]];
        if (r != 0 && r != 124) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install %@: %d\n", name, r]}];
        }
    }
    return nil;
}

- (BOOL)shouldInstallPackage:(NSString *)identifier
{
    NSString *bundledVersion = gBundledPackages[identifier];
    if (!bundledVersion) return NO;
    
    NSString *installedVersion = [self installedVersionForPackageWithIdentifier:identifier];
    if (!installedVersion) return YES;
    
    return [installedVersion numericalVersionRepresentation] < [bundledVersion numericalVersionRepresentation];
}

/* ============ roothide specific: 环境修正（幂等，每次越狱都跑） ============ */

- (NSString *)firmwareVersion
{
    // 取 iOS 营销版本号，如 "18.0"，用于 firmware 虚拟包。
    // Sileo / tweak 的依赖写的是 firmware(>=12.2)、firmware(>=15.0) 等，
    // 必须提供纯数字版本号，build 号（如 22A3354）会让 dpkg 解析成意外结果。
    size_t size = 0;
    sysctlbyname("kern.osproductversion", NULL, &size, NULL, 0);
    if (size == 0) return nil;
    char *buf = (char *)malloc(size);
    if (sysctlbyname("kern.osproductversion", buf, &size, NULL, 0) != 0) {
        free(buf);
        return nil;
    }
    NSString *ver = [NSString stringWithUTF8String:buf];
    free(buf);
    return ver;
}

- (BOOL)firmwarePackageValid
{
    NSString *statusPath = JBROOT_PATH(@"/Library/dpkg/status");
    NSString *status = [NSString stringWithContentsOfFile:statusPath encoding:NSUTF8StringEncoding error:nil];
    if (!status) return NO;
    // 匹配 firmware 段落并取出 Version 字段
    NSRange range = [status rangeOfString:@"\nPackage: firmware\n" options:0];
    if (range.location == NSNotFound) {
        if ([status hasPrefix:@"Package: firmware\n"]) {
            range = NSMakeRange(0, 0);
        } else {
            return NO;
        }
    }
    NSUInteger start = range.location + range.length;
    NSUInteger end = [status rangeOfString:@"\n\n" options:0 range:NSMakeRange(start, status.length - start)].location;
    if (end == NSNotFound) end = status.length;
    NSString *paragraph = [status substringWithRange:NSMakeRange(start, end - start)];
    NSRange verRange = [paragraph rangeOfString:@"\nVersion: "];
    if (verRange.location == NSNotFound) return NO;
    NSUInteger verStart = verRange.location + verRange.length;
    NSUInteger verEnd = [paragraph rangeOfString:@"\n" options:0 range:NSMakeRange(verStart, paragraph.length - verStart)].location;
    if (verEnd == NSNotFound) verEnd = paragraph.length;
    NSString *version = [paragraph substringWithRange:NSMakeRange(verStart, verEnd - verStart)];
    // 必须是 x.y[.z] 格式的纯数字版本，才能满足 firmware(>=12.2) 这种依赖
    if ([version rangeOfString:@"."].location == NSNotFound) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
    NSCharacterSet *inverted = [allowed invertedSet];
    return [version rangeOfCharacterFromSet:inverted].location == NSNotFound;
}

- (void)ensureFirmwarePackage
{
    // roothide 的 firmware 虚拟包本应由 prep_bootstrap.sh 里的 /usr/libexec/firmware 生成。
    // 但 3.x 版 Dopamine App 以真实根运行（roothide 2.x 里 App 是以 jbroot 为根的），
    // prep 里的 /usr/libexec/firmware（相对真实根）找不到 → firmware 包未注册 →
    // 所有依赖 firmware 的包（sileo / roothideapp / RootHide Patcher / 任意 tweak）都装失败。
    // 这里用 jbroot 绝对路径显式运行 firmware 二进制（等价于 rh2 里 App 以 jbroot 为根的行为），
    // 跑完再校验；若仍缺失或版本格式不对，手写替换 firmware 条目。
    if ([self firmwarePackageValid]) return;

    // 1) 尝试用 jbroot 路径运行 firmware 二进制（它会用 roothide 运行时把包写进 jbroot/Library/dpkg/status）
    // build38.37: 带超时——firmware 二进制若卡住，主线程阻塞超看门狗阈值同样闪退。
    [self execTrustedWithTimeout:15.0 binary:JBROOT_PATH(@"/usr/libexec/firmware") arguments:@[]];
    if ([self firmwarePackageValid]) return;

    // 2) 兜底：把 firmware 段落删掉后重新写入一个格式正确的条目（版本取 iOS 营销版本）
    NSString *statusPath = JBROOT_PATH(@"/Library/dpkg/status");
    NSString *status = [NSString stringWithContentsOfFile:statusPath encoding:NSUTF8StringEncoding error:nil];
    if (!status) return;
    NSString *ver = [self firmwareVersion];
    if (!ver) ver = @"18.0";
    // 删除已有的 firmware 段落（防止旧 build 写入了 build 号版本）
    NSMutableString *cleaned = [NSMutableString stringWithString:status];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(^|\n)Package: firmware\n.*?\n\n" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    [regex replaceMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@""];
    // 确保以双换行结尾
    if (![cleaned hasSuffix:@"\n"]) [cleaned appendString:@"\n"];
    if (![cleaned hasSuffix:@"\n\n"]) [cleaned appendString:@"\n"];
    [cleaned appendFormat:@"Package: firmware\nStatus: install ok installed\nPriority: required\nSection: System\nInstalled-Size: 0\nVersion: %@\nArchitecture: iphoneos-arm64e\nDescription: iOS firmware\n\n", ver];
    [cleaned writeToFile:statusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)ensureToolchainInstalled
{
    // bootstrap 不含 file/gawk/libxar1/plutil 等基础工具链（RootHide Patcher 依赖它们），
    // 这些包在 roothide procursus 源里，但越狱时未必刷新过源/有网络。
    // 直接把对应 deb 打包进 App，用 --force-depends 幂等安装（installPackage 已带该参数）。
    // build38.36: 改走带超时 exec，避免任一 dpkg 卡住阻塞 finalize。
    NSArray *toolchain = @[@"file.deb", @"gawk.deb", @"libxar1.deb", @"plutil.deb", @"libmagic1.deb", @"libmpfr6.deb"];
    for (NSString *deb in toolchain) {
        NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:deb];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Installing %@", deb] debug:YES];
        int r = [self execTrustedWithTimeout:15.0 binary:JBROOT_PATH(@"/usr/bin/dpkg") arguments:@[@"--force-depends", @"-i", path]];
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"%@ install result: %d", deb, r] debug:YES];
    }
}

- (void)ensureRoothideManagerInstalled
{
    // Roothide Manager（黑名单管理工具，com.roothide.manager）幂等安装 + 刷新图标。
    // 每次越狱都跑：既修复首次没装上的情况，也保证图标被 uicache 注册。
    NSString *roothideManager = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"roothideapp.deb"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:roothideManager]) {
        // build38.36: 带超时
        int r = [self execTrustedWithTimeout:15.0 binary:JBROOT_PATH(@"/usr/bin/dpkg") arguments:@[@"--force-depends", @"-i", roothideManager]];
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"roothideapp.deb install result: %d", r] debug:YES];
    }
    // 刷新 RootHide Manager 图标（只刷单个 app，避免 3.x 里 uicache -a 被注释掉的全局刷新可能触发的问题）
    NSString *uicache = JBROOT_PATH(@"/usr/bin/uicache");
    if ([[NSFileManager defaultManager] fileExistsAtPath:uicache]) {
        NSString *rootHideApp = JBROOT_PATH(@"/Applications/RootHide.app");
        int r = [self execTrustedWithTimeout:15.0 binary:uicache arguments:@[@"-p", rootHideApp]];
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"uicache(RootHide.app) result: %d", r] debug:YES];
    }
}

- (void)ensureExtraPackagesInstalled
{
    // 用户指定的预装包：AppSync Unified（ai.akemi.appsyncunified，允许装未签名/伪签名 app）
    // + TrollStore Lite（com.opa334.trollstorelite，roothide 版 TrollStore，装 /Applications/TrollStoreLite.app）。
    // 幂等安装（installPackage 带 --force-depends），每次越狱都跑；缺文件时静默跳过。
    // build38.35 新增 roothide 插件运行时三件套（顺序即依赖顺序）：
    //   1. patchloader.deb（com.roothide.patchloader，RootHide Dynamic Patches Loader，
    //      产物 /usr/lib/roothidepatch.dylib，systemhook 的 roothider_main.c 要 dlopen 它。
    //      bootstrap 不含它（rh2 时代由用户在 Sileo 手动装），缺它 → DynamicPatches 不加载 →
    //      rootless 插件装了也无效。官方源最新 0.0.8。）
    //   2. rootless-compat.deb（rootless 路径兼容层，AutoPatches.dylib 做 /var/jb 重定向，
    //      Depends com.roothide.patchloader>=0.0.4，用户设备导出版 2.0 = 官方最新）
    //   3. ellekit.deb（mobilesubstrate 替身：Provides mobilesubstrate(=99) + 提供
    //      libsubstrate/TweakInject 符号链，rootless 插件的依赖检查与链接需要。官方源 1.2。）
    // build38.37: AppSync 必须在 ellekit 之后装——appsync 的 Depends 是
    // mobilesubstrate (>= 0.9.5100)，而 ellekit 是 mobilesubstrate 的提供者。
    // 38.35/38.36 把 appsync 排最前 → dpkg 强装后依赖仍不满足 → Sileo 数据库里
    // AppSync 状态异常 → 弹 "needs to be reinstalled, but I can't find an archive for it"。
    NSArray *extraDebs = @[@"patchloader.deb", @"rootless-compat.deb", @"ellekit.deb", @"appsync.deb", @"tslite.deb"];
    for (NSString *deb in extraDebs) {
        NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:deb];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Installing %@", deb] debug:YES];
        int r = [self execTrustedWithTimeout:15.0 binary:JBROOT_PATH(@"/usr/bin/dpkg") arguments:@[@"--force-depends", @"-i", path]];
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"%@ install result: %d", deb, r] debug:YES];
    }
    // TSLite 是 /Applications 里的 app，装完刷新图标（同样带超时，uicache 在 3.x 偶发卡住）
    NSString *uicache = JBROOT_PATH(@"/usr/bin/uicache");
    if ([[NSFileManager defaultManager] fileExistsAtPath:uicache]) {
        NSString *tsliteApp = JBROOT_PATH(@"/Applications/TrollStoreLite.app");
        int r = [self execTrustedWithTimeout:15.0 binary:uicache arguments:@[@"-p", tsliteApp]];
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"uicache result: %d", r] debug:YES];
    }
}


- (void)ensureSileoAndAptDirectories
{
    // Sileo 报“文件夹 'xxx-_Packages' 不存在”（实测 roothide.github.io-_Packages），
    // 经核对 Sileo 源码，出错的那次写入是
    //   DependencyResolverAccelerator.getDependencies() 第 167 行
    //   try sourcesData.append(to: newSourcesFile)
    //   newSourcesFile = depResolverPrefix + "/<repo>_Packages"
    //   depResolverPrefix = CommandPath.sileolists = <jbroot>/var/lib/apt/sileolists
    // → 真正缺失的父目录是 <jbroot>/var/lib/apt/sileolists。
    //
    // 该目录本应由 Sileo 自己在 DependencyResolverAccelerator.init() 里建：
    //   spawnAsRoot(mkdir -p sileolists) + chown -R mobile:mobile + chmod -R 0755
    // 但 spawnAsRoot 依赖 persona 提权（posix_spawnattr_set_persona_np(99, OVERRIDE) +
    // persona_uid=0，iOS 17.6+ 还要经 systemhook 改写 + launchdhook 的
    // JBS_SYSTEMWIDE_PERSONA_FIX 事后改 ucred）。这条链上任何一环降级，子进程就以
    // mobile 身份运行，mkdir 在 root:wheel 的 /var/lib/apt 下直接 EACCES，
    // 目录建不出来 → 写文件报“文件夹不存在”。
    //
    // 这里用越狱 App 的 root 权限（exec_cmd_trusted 必定是 root）提前把目录建好，
    // 并按 Sileo 自己的做法 chown mobile:mobile，这样即使 Sileo 的 spawnAsRoot 失效，
    // 目录也存在且 mobile 可写。Sileo init() 里会先 rm -rf 再 mkdir：
    // 提权正常时它自己重建，提权失效时 rm 也一并失败，我们建的目录得以保留，两种情况都成立。
    //
    // 【38.31 的修复为何无效】那一版建的是 JBROOT_PATH("/var/mobile/Library/Caches/Sileo")：
    //   1) 清单里根本没有 sileolists，没命中真正报错的目录；
    //   2) Sileo 的 app cache 走的是 rootfs 上真实的 /var/mobile/Library/Caches/Sileo
    //      （见 Sileo AppDelegate.swift 注释 "but why stil got file:///var/mobile/Library/Caches/Sileo"），
    //      套 JBROOT_PATH 后建到了 jbroot 内，是个没人用的空目录；
    //   3) 该 cache 由 Sileo 以 mobile 身份自建，用 root 去建反而会把 owner 变成
    //      root:wheel 挡住 Sileo。故此处移除对它的处理。

    // 1) root 拥有的路径下、但需要 mobile 写入的目录 → 建完 chown mobile:mobile
    // build38.37: /var/lib/apt 本身也必须 mobile 可写——Sileo init() 每次启动会
    // rm -rf sileolists 再 mkdir -p 重建（spawnAsRoot）。若提权降级为 mobile，
    // rm 能删掉 mobile 拥有的 sileolists（38.31 已 chown），但 mkdir 时父目录
    // /var/lib/apt 若仍是 root:wheel 0755 → mobile 无权限建目录 → “文件夹不存在”
    // 依旧。把 /var/lib/apt 及 sileolists 全部 chown mobile:mobile，两条路径都成立。
    exec_cmd_trusted(JBROOT_PATH("/bin/mkdir"), "-p", JBROOT_PATH("/var/lib/apt"), NULL);
    exec_cmd_trusted(JBROOT_PATH("/usr/bin/chown"), "-R", "mobile:mobile", JBROOT_PATH("/var/lib/apt"), NULL);
    exec_cmd_trusted(JBROOT_PATH("/usr/bin/chmod"), "-R", "0755", JBROOT_PATH("/var/lib/apt"), NULL);
    NSArray *mobileOwnedDirs = @[
        @"/var/lib/apt/sileolists",             // 图三报错的父目录
        @"/var/lib/apt/sileolists/operations",  // buildOperations() 用 try! 创建，父目录缺失会直接崩溃
    ];
    for (NSString *d in mobileOwnedDirs) {
        NSString *p = JBROOT_PATH(d);
        exec_cmd_trusted(JBROOT_PATH("/bin/mkdir"), "-p", p.fileSystemRepresentation, NULL);
        exec_cmd_trusted(JBROOT_PATH("/usr/bin/chown"), "-R", "mobile:mobile", p.fileSystemRepresentation, NULL);
        exec_cmd_trusted(JBROOT_PATH("/usr/bin/chmod"), "-R", "0755", p.fileSystemRepresentation, NULL);
    }

    // 2) apt / dpkg 自用目录，保持 root:wheel。
    //    /Library/dpkg/updates 是 dpkg 的 status journal 目录，Sileo 与 apt 判定
    //    “dpkg 被中断”读的就是它，缺失会让 dpkg 无法写事务日志。
    NSArray *rootOwnedDirs = @[
        @"/var/lib/apt/lists/partial",
        @"/var/cache/apt/archives/partial",
        @"/var/log/apt",
        @"/Library/dpkg/updates",
        @"/Library/dpkg/triggers",
        @"/Library/dpkg/parts",
    ];
    for (NSString *d in rootOwnedDirs) {
        NSString *p = JBROOT_PATH(d);
        exec_cmd_trusted(JBROOT_PATH("/bin/mkdir"), "-p", p.fileSystemRepresentation, NULL);
    }
}

- (void)ensureDpkgConsistent
{
    // 【图一/图二：Sileo 弹“dpkg 被中断”】
    // 判定条件（Sileo DpkgWrapper.dpkgInterrupted()，与 apt debSystem::CheckUpdates() 一致）：
    //   <jbroot>/Library/dpkg/updates/ 下存在文件名全为数字的 status journal。
    // journal 是 dpkg 事务日志，正常退出（哪怕 postinst 返回非 0）都会被清理，
    // 只有 dpkg 进程被硬杀才会残留——例如提权降级后 dpkg 中途失败、
    // userspace 重启、掉电。dpkg 每次以写模式启动都会先 replay 再清空 journal。
    //
    // 所以这里在所有装包动作之后跑一次 --configure -a，一次解决两个弹窗：
    //   1) replay 并清空 journal → “dpkg 被中断”消失；
    //   2) 把 unpacked / half-configured 的包配置完 → Sileo 的 foundBroken 弹窗消失。
    //
    // --force-depends / --force-configure-any 是必须的：roothide bootstrap 里
    // 没有 mobilesubstrate、也没有 ellekit（已核对 bootstrap 的 Library/dpkg/status，
    // 78 个包中两者皆无），而 appsync 的 Depends 写着 mobilesubstrate (>= 0.9.5100)。
    // 不加 force，dpkg 会拒绝配置这类包，反而把 broken 状态留在数据库里。
    //
    // build38.36: 改走带超时 exec——历史中断留下的 dpkg 锁/半状态可能让 --configure -a
    // 永久卡住（阻塞 finalize → 看门狗杀 app → “闪退”）。超时后杀子进程继续流程。
    NSString *dpkg = JBROOT_PATH(@"/usr/bin/dpkg");
    [[DOUIManager sharedInstance] sendLog:@"Running dpkg --configure -a" debug:YES];
    int r = [self execTrustedWithTimeout:15.0 binary:dpkg arguments:@[@"--force-depends", @"--force-configure-any", @"--configure", @"-a"]];
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"dpkg --configure -a result: %d", r] debug:YES];
}

- (void)writeDpkgDiagnostics
{
    // 把 dpkg / Sileo 相关的现场状态落盘，便于用 AFC（爱思、iMazing 等）
    // 从 /var/mobile/Media/ 直接取出，不必装 Filza 也能定位问题。
    // 追加写入，保留历次越狱记录。
    // build38.40: 避开 JBROOT_PATH(@"") 的 NSString overload，该重载在 iOS 18 arm64e
    // 某些运行时会因 path.fileSystemRepresentation 内部访问 NSSubrangeData 而崩溃。
    const char *jbrootC = get_jbroot() ?: "";
    NSString *jbroot = [NSString stringWithUTF8String:jbrootC];
    NSString *script = [NSString stringWithFormat:
        @"exec >> /var/mobile/Media/dopamine_dpkg_diag.log 2>&1; "
         "echo \"===== $(date) =====\"; "
         "echo '--- dpkg journal (updates/) ---'; ls -la '%@/Library/dpkg/updates/'; "
         "echo '--- dpkg locks ---'; ls -la '%@/Library/dpkg/lock' '%@/Library/dpkg/lock-frontend' 2>&1; "
         "echo '--- dpkg processes ---'; ps -A | grep -i dpkg | grep -v grep; "
         "echo '--- sileolists ---'; ls -ld '%@/var/lib/apt/sileolists' '%@/var/lib/apt/sileolists/operations'; "
         "echo '--- apt lists ---'; ls -ld '%@/var/lib/apt/lists'; "
         "echo '--- roothidepatch / DynamicPatches ---'; ls -la '%@/usr/lib/roothidepatch.dylib' '%@/usr/lib/DynamicPatches/' 2>&1; "
         "echo '--- dpkg --audit ---'; '%@/usr/bin/dpkg' --audit; "
         "echo '--- not-installed-ok pkgs ---'; '%@/usr/bin/dpkg' -l | grep -v '^ii' | head -40; "
         "echo; ",
        jbroot, jbroot, jbroot, jbroot, jbroot, jbroot, jbroot, jbroot, jbroot];
    exec_cmd_trusted(JBROOT_PATH("/bin/sh"), "-c", script.fileSystemRepresentation, NULL);
    // 交给 mobile，AFC 才能正常读取
    exec_cmd_trusted(JBROOT_PATH("/usr/bin/chown"), "mobile:mobile", "/var/mobile/Media/dopamine_dpkg_diag.log", NULL);
}

- (NSError *)finalizeBootstrap
{
    // Initial setup on first jailbreak
    if ([[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/prep_bootstrap.sh")]) {
        [[DOUIManager sharedInstance] sendLog:@"Finalizing Bootstrap" debug:NO];

        // 注：bootstrap 预信任已提前到 DOJailbreaker 流程（loadBasebinTrustcache 之后），
        // 覆盖此处的 prep_bootstrap.sh 与之前的 killall（iconservicesagent）。

        int r = exec_cmd_trusted(JBROOT_PATH("/bin/sh"), JBROOT_PATH("/prep_bootstrap.sh"), NULL);
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"prep_bootstrap.sh returned %d\n", r]}];
        }
        
        NSError *error = [self installPackageManagers];
        if (error) return error;
        
        // 清理首次越狱完全激活前由 uicache 触发的残留快照（rh2 同样处理）
        [NSFileManager.defaultManager removeItemAtPath:@"/var/mobile/Library/SplashBoard/Snapshots/xyz.willy.Zebra" error:nil];
        [NSFileManager.defaultManager removeItemAtPath:@"/var/mobile/Library/SplashBoard/Snapshots/com.roothide.manager" error:nil];
        [NSFileManager.defaultManager removeItemAtPath:@"/var/mobile/Library/SplashBoard/Snapshots/org.coolstar.SileoStore" error:nil];
    }
    
    // ===== roothide 环境修正（每次越狱都跑，幂等）=====
    // 3.x 版 Dopamine App 以真实根运行（非 jbroot 为根），导致 prep_bootstrap.sh 里的
    // /usr/libexec/firmware 跑不到 → firmware 虚拟包没生成；bootstrap 也不含 file/gawk/
    // libxar1/plutil 等基础工具链。这些必须在越狱环境里补齐，否则任何依赖 firmware 或
    // 这些工具的包（sileo / roothideapp / RootHide Patcher / 任意 tweak）都会装失败。
    [[DOUIManager sharedInstance] sendLog:@"Fixing roothide environment" debug:NO];
    [self ensureFirmwarePackage];
    [self ensureToolchainInstalled];
    [self ensureRoothideManagerInstalled];
    // build38.36: 装新包前先清历史 dpkg journal/半状态——用户设备历史上 dpkg 中断过，
    // 若 updates/ 残留 journal，后续 dpkg -i 会先 replay 旧事务（可能卡住/报错）。
    // 先 --configure -a 清干净，再装三件套，最后收尾再清一次。
    [self ensureDpkgConsistent];
    [self ensureExtraPackagesInstalled];
    [self ensureSileoAndAptDirectories];
    [self ensureJbrootSelfLink];
    
    // roothide specific: libroot-dopamine / libkrw0-dopamine 由 roothide bootstrap 自带
    // （libroothide.dylib 提供 jbroot()/rootfs()，libkrw.0.dylib 提供内核读写），
    // 跳过 3.x 的 arm64 deb——它们与 roothide procursus 的 arm64e 体系架构不匹配，
    // dpkg 会报 "package architecture (iphoneos-arm64) does not match system (iphoneos-arm64e)"
    BOOL shouldInstallLibroot = NO;
    BOOL shouldInstallLibkrw = NO;
    BOOL shouldInstallBasebinLink = [self shouldInstallPackage:@"dopamine-basebin-link"];
    BOOL shouldInstallLaunchctl = NO;
    if (__builtin_available(iOS 19.0, *)) {
        shouldInstallLaunchctl = [self shouldInstallPackage:@"launchctl"];
    }
    
    if (shouldInstallLibroot || shouldInstallLibkrw || shouldInstallBasebinLink || shouldInstallLaunchctl) {
        [[DOUIManager sharedInstance] sendLog:@"Updating Bundled Packages" debug:NO];

        if (shouldInstallLaunchctl) {
            NSString *launchctlPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"launchctl_1_1.2.0_iphoneos-arm64.deb"];
            int r = [self installPackage:launchctlPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install launchctl: %d\n", r]}];
        }

        if (shouldInstallLibroot) {
            NSString *librootPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libroot.deb"];
            int r = [self installPackage:librootPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install libroot: %d\n", r]}];
        }
        
        if (shouldInstallLibkrw) {
            NSString *libkrwPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libkrw-dopamine.deb"];
            int r = [self installPackage:libkrwPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install the libkrw plugin: %d\n", r]}];
        }
        
        if (shouldInstallBasebinLink) {
            // Clean symlinks from earlier Dopamine versions
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/opainject")]) {
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/opainject") error:nil];
            }
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/jbctl")]) {
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/jbctl") error:nil];
            }
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/lib/libjailbreak.dylib")]) {
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/lib/libjailbreak.dylib") error:nil];
            }
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/libjailbreak.dylib")]) {
                // Yes this exists >.< was a typo
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/libjailbreak.dylib") error:nil];
            }
            
            NSString *basebinLinkPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin-link.deb"];
            int r = [self installPackage:basebinLinkPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install basebin link: %d\n", r]}];
        }
    }

    // ===== dpkg 一致性收尾 =====
    // 必须放在所有 installPackage 之后：这里跑的 dpkg --configure -a 会 replay 并清空
    // status journal，若后面还有 dpkg -i，又会留下新的 journal，Sileo 照样弹“dpkg 被中断”。
    [[DOUIManager sharedInstance] sendLog:@"Reconciling dpkg database" debug:NO];
    [self ensureDpkgConsistent];
    [self writeDpkgDiagnostics];

    return nil;
}

- (NSError *)deleteBootstrap
{
    // roothide specific: jbroot 位于 /var/containers/Bundle/Application/.jbroot-XXXX 及其 AppGroup 隐藏副本。
    // 原 3.x 实现用 rootPath.stringByDeletingLastPathComponent 会删除整个 Application 目录 → 物理删除所有第三方 App。
    // 这里用 is_jbroot_name() 白名单精确匹配，只删 jbroot 自身（移植自 roothide 2.x deleteBootstrap）。
    NSError *error = [self ensurePrivatePrebootIsWritable];
    if (error) return error;

    NSFileManager *fm = NSFileManager.defaultManager;

    // 1) 删除 /var/containers/Bundle/Application/ 下的随机 jbroot 目录
    NSString *appDir = @"/var/containers/Bundle/Application/";
    NSArray *appItems = [fm contentsOfDirectoryAtPath:appDir error:nil];
    for (NSString *item in appItems) {
        if (is_jbroot_name(item.UTF8String)) {
            [fm removeItemAtPath:[appDir stringByAppendingPathComponent:item] error:&error];
            if (error) return error;
        }
    }

    // 2) 删除 AppGroup 下隐藏的 jbroot（含 /var 数据、RootHideConfig.plist 等）
    NSString *agDir = @"/var/mobile/Containers/Shared/AppGroup/";
    NSArray *agItems = [fm contentsOfDirectoryAtPath:agDir error:nil];
    for (NSString *item in agItems) {
        if (is_jbroot_name(item.UTF8String)) {
            [fm removeItemAtPath:[agDir stringByAppendingPathComponent:item] error:&error];
            if (error) return error;
        }
    }

    // 3) 兼容 rootless 残留的 /var/jb
    [fm removeItemAtPath:@"/var/jb" error:nil];

    return nil;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (downloadTask == _bootstrapDownloadTask) {
        NSString *sizeString = [NSByteCountFormatter stringFromByteCount:totalBytesWritten countStyle:NSByteCountFormatterCountStyleFile];
        NSString *writtenBytesString = [NSByteCountFormatter stringFromByteCount:totalBytesExpectedToWrite countStyle:NSByteCountFormatterCountStyleFile];
        
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Downloading Bootstrap (%@/%@)", sizeString, writtenBytesString] debug:NO update:YES];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    _downloadCompletionBlock(nil, error);
}

- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location
{
    _downloadCompletionBlock(location, nil);
}

@end
