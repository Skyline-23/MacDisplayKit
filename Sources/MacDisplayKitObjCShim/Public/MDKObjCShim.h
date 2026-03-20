#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *MDKShimVersionString(void);
FOUNDATION_EXPORT NSURL *MDKShimRepositoryRootURL(void);
FOUNDATION_EXPORT NSURL *MDKShimLegacyRuntimeSourceRootURL(void);
FOUNDATION_EXPORT NSArray<NSString *> *MDKShimPlannedModuleNames(void);
FOUNDATION_EXPORT NSString * _Nullable MDKShimCreateVirtualDisplay(
    NSString *clientIdentifier,
    NSString *clientName,
    NSUInteger logicalWidth,
    NSUInteger logicalHeight,
    NSUInteger refreshRateMilliHz,
    NSInteger scaleFactor,
    BOOL hiDPI,
    BOOL hdrEnabled,
    NSInteger displayGamut,
    NSInteger displayTransfer
);
FOUNDATION_EXPORT BOOL MDKShimUpdateVirtualDisplay(
    NSString *clientIdentifier,
    NSUInteger logicalWidth,
    NSUInteger logicalHeight,
    NSUInteger refreshRateMilliHz,
    NSInteger displayTransfer
);
FOUNDATION_EXPORT BOOL MDKShimRemoveVirtualDisplay(NSString *clientIdentifier);

NS_ASSUME_NONNULL_END
