//
//  Bootstrapper.h
//  Dopamine
//
//  Created by Lars Fröder on 09.01.24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const bootstrapErrorDomain;
typedef NS_ENUM(NSInteger, BootstrapErrorCode) {
    BootstrapErrorCodeFailedToGetURL            = -1,
    BootstrapErrorCodeFailedToDownload          = -2,
    BootstrapErrorCodeFailedDecompressing       = -3,
    BootstrapErrorCodeFailedExtracting          = -4,
    BootstrapErrorCodeFailedRemount             = -5,
    BootstrapErrorCodeFailedFinalising          = -6,
    BootstrapErrorCodeFailedReplacing           = -7,
};

@interface DOBootstrapper : NSObject <NSURLSessionDelegate, NSURLSessionDownloadDelegate>
{
    NSURLSession *_urlSession;
    NSURLSessionDownloadTask *_bootstrapDownloadTask;
    void (^_downloadCompletionBlock)(NSURL * _Nullable location, NSError * _Nullable error);
}

- (void)prepareBootstrapWithCompletion:(void (^)(NSError *))completion;
- (NSError *)updateVarJbSymlink;
- (NSError *)ensurePrivatePrebootIsWritable;
- (NSError *)installPackageManagers;
- (NSError *)finalizeBootstrap;
- (NSError *)deleteBootstrap;
// build38.45: 把 sileolists/apt 目录权限修复从 finalizeBootstrap 中拆出独立方法，
// 供 DOJailbreaker 主流程在越狱早期（elevatePrivileges 后）显式调用——
// PPL bypass 阶段 panic 会打断 finalize，导致 chown 从未执行（Sileo 报 sileolists 无权限）。
- (void)ensureSileoAndAptDirectories;

// roothide specific: jbrand 随机 jbroot 路径机制
- (NSError *)ensureJbrandRootExists;
- (int)buildPackageSources:(void (^)(NSError *))completion;

@end

// roothide specific: jbrand 路径函数（供 DOEnvironmentManager 等跨文件调用）
NSString *find_jbroot(BOOL force);
uint64_t jbrand_current();
NSString *jbrootPrefix(NSString *path);
NSString *rootfsPrefix(NSString *path);

NS_ASSUME_NONNULL_END
