//
//  EnvironmentManager.h
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import <Foundation/Foundation.h>
#import "DOBootstrapper.h"

NS_ASSUME_NONNULL_BEGIN

@interface DOEnvironmentManager : NSObject
{
    DOBootstrapper *_bootstrapper;
    BOOL _isJailbroken;
    NSString *_jailbrokenVersion;
    BOOL _bootstrapNeedsMigration;
}

+ (instancetype)sharedManager;

- (NSString *)appVersion;
- (NSString *)appVersionDisplayString;
- (NSString *)nightlyHash;

- (NSString *)privatePrebootPath;
- (NSString *)activePrebootPath;

- (BOOL)isInstalledThroughTrollStore;
- (BOOL)isJailbroken;
- (BOOL)isJailbrokenWithOtherJailbreak;
- (BOOL)isBootstrapped;
- (NSString *)jailbrokenVersion;
- (NSString *)systemVersion;

- (BOOL)isSupported;
- (BOOL)isArm64e;
- (BOOL)isSPTM;
- (NSString *)versionSupportString;
- (NSString *)accessibleKernelPath;
- (NSString *)accessibleSPTMPath;
- (NSString *)accessibleTXMPath;
- (void)locateJailbreakRoot;
- (NSError *)ensureJailbreakRootExists;

- (void)setJailbroken:(BOOL)jailbroken;


- (void)runUnsandboxed:(void (^)(void))unsandboxBlock;
- (void)runAsRoot:(void (^)(void))rootBlock;

- (void)respring;
- (void)rebootUserspace;
- (void)refreshJailbreakApps;
- (void)reboot;
- (void)changeMobilePassword:(NSString *)newPassword;
- (NSError*)updateEnvironment;
- (void)updateJailbreakFromTIPA:(NSString *)tipaPath;

- (BOOL)isTweakInjectionEnabled;
- (void)setTweakInjectionEnabled:(BOOL)enabled;
- (BOOL)isIDownloadEnabled;
- (void)setIDownloadEnabled:(BOOL)enabled needsUnsandbox:(BOOL)needsUnsandbox;
- (void)setIDownloadLoaded:(BOOL)loaded needsUnsandbox:(BOOL)needsUnsandbox;
- (BOOL)isFakelibMounted;
- (int)setFakelibMounted:(BOOL)mounted;
- (int)setPrivatePrebootProtected:(BOOL)protected;
- (BOOL)isJailbreakHidden;
- (void)setJailbreakHidden:(BOOL)hidden;

- (BOOL)isPACBypassRequired;
- (BOOL)isPPLBypassRequired;

- (NSError *)prepareBootstrap;
- (NSError *)finalizeBootstrap;
- (NSError *)deleteBootstrap;
// build38.45: 转发到 DOBootstrapper，供 DOJailbreaker 主流程在越狱早期调用
//（修复 sileolists/apt 目录权限，防止 PPL panic 打断 finalize 导致 Sileo 无权限）
- (void)ensureSileoAndAptDirectories;
- (NSError *)reinstallPackageManagers;
- (NSError *)updateBootLogo;
- (void)mountDictionary:(NSDictionary *)dictionary writeToFile:(NSString *)path;
- (void)fakeMount:(NSString *)path unmount:(BOOL)unmount shouldDeleteMntFiles:(BOOL)shouldDeleteMntFiles;
@end

NS_ASSUME_NONNULL_END
