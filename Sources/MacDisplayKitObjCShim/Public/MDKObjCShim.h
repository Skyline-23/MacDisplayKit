#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *MDKShimVersionString(void);
FOUNDATION_EXPORT NSURL *MDKShimRepositoryRootURL(void);
FOUNDATION_EXPORT NSURL *MDKShimLegacyRuntimeSourceRootURL(void);
FOUNDATION_EXPORT NSArray<NSString *> *MDKShimPlannedModuleNames(void);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *MDKShimListDisplays(void);
FOUNDATION_EXPORT NSString * _Nullable MDKShimDisplayName(NSUInteger displayID);
FOUNDATION_EXPORT BOOL MDKShimScreenCaptureAccessAuthorized(void);
FOUNDATION_EXPORT BOOL MDKShimVideoAVFoundationAvailableForDisplay(NSUInteger displayID, NSInteger frameRate);
FOUNDATION_EXPORT BOOL MDKShimVideoCGDisplayStreamAvailableForDisplay(NSUInteger displayID);
FOUNDATION_EXPORT BOOL MDKShimVideoPrivateDesktopCaptureAvailable(void);
FOUNDATION_EXPORT BOOL MDKShimVideoPrivateDisplayIOSurfaceCaptureAvailable(void);
FOUNDATION_EXPORT BOOL MDKShimVideoPrivateDisplayIOSurfaceCaptureWithOptionsAvailable(void);
FOUNDATION_EXPORT BOOL MDKShimVideoPrivateCaptureExtendedRangeOptionAvailable(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateCaptureSingleFrame(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateCaptureBenchmark(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSTimeInterval sampleDuration,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSArray<NSString *> *MDKShimMicrophoneNames(void);
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
