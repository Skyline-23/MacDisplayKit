#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MDKShimSkyLightDisplayStreamFrameHandler)(
    CGDisplayStreamFrameStatus status,
    uint64_t displayTime,
    IOSurfaceRef _Nullable frameSurface
);

@interface MDKShimSkyLightDisplayStreamSession : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithDisplayID:(NSUInteger)displayID
                 minimumFrameTime:(double)minimumFrameTime
                       queueDepth:(NSInteger)queueDepth
                       showCursor:(BOOL)showCursor
                      outputWidth:(NSUInteger)outputWidth
                     outputHeight:(NSUInteger)outputHeight
                      pixelFormat:(uint32_t)pixelFormat
                     frameHandler:(MDKShimSkyLightDisplayStreamFrameHandler)frameHandler NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) NSUInteger displayID;
@property (nonatomic, readonly) double minimumFrameTime;
@property (nonatomic, readonly) NSInteger queueDepth;
@property (nonatomic, readonly) BOOL showCursor;
@property (nonatomic, readonly) NSUInteger outputWidth;
@property (nonatomic, readonly) NSUInteger outputHeight;
@property (nonatomic, readonly) uint32_t pixelFormat;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (BOOL)start:(NSError * _Nullable * _Nullable)error;
- (int32_t)stop;

@end

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
FOUNDATION_EXPORT BOOL MDKShimVideoPrivateDisplayIOSurfaceProxyCaptureAvailable(void);
FOUNDATION_EXPORT BOOL MDKShimVideoPrivateDisplayStreamProxyAvailable(void);
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
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateProxyCaptureSingleFrame(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateProxyCaptureBenchmark(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSTimeInterval sampleDuration,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateDisplayStreamProbe(
    NSUInteger displayID,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateDisplayStreamProbeWithParameters(
    NSUInteger displayID,
    NSInteger streamPropertiesProfile,
    NSInteger portMode,
    NSInteger selectiveSharingMode,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoSkyLightDisplayStreamBenchmark(
    NSUInteger displayID,
    NSTimeInterval sampleDuration,
    BOOL request120LikeProperties,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoSkyLightDisplayStreamBenchmarkWithParameters(
    NSUInteger displayID,
    NSTimeInterval sampleDuration,
    double minimumFrameTime,
    NSInteger queueDepth,
    BOOL showCursor,
    NSUInteger outputWidth,
    NSUInteger outputHeight,
    uint32_t pixelFormat,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoTraceScreenCaptureKitProxyHandshake(
    NSUInteger displayID,
    NSTimeInterval timeout,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoTraceScreenCaptureKitPassiveHandshake(
    NSUInteger displayID,
    NSTimeInterval timeout,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoTraceScreenCaptureKitTiming(
    NSUInteger displayID,
    NSTimeInterval timeout,
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MDKShimVideoInspectScreenCaptureKitRuntime(
    NSError * _Nullable * _Nullable error
);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *MDKShimMicrophoneDescriptors(void);
FOUNDATION_EXPORT NSArray<NSString *> *MDKShimMicrophoneNames(void);

typedef void (^MDKShimAudioCaptureFrameHandler)(
    uint64_t hostTimeNanoseconds,
    NSData *pcmFloat32LE,
    NSUInteger frameCount,
    NSUInteger channelCount,
    NSUInteger sampleRate
);

@interface MDKShimMicrophoneCaptureSession : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithInputID:(NSString * _Nullable)inputID
                     sampleRate:(NSUInteger)sampleRate
                      frameSize:(NSUInteger)frameSize
                       channels:(NSUInteger)channels
                   frameHandler:(MDKShimAudioCaptureFrameHandler)frameHandler NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly, nullable) NSString *inputID;
@property (nonatomic, readonly) NSUInteger sampleRate;
@property (nonatomic, readonly) NSUInteger frameSize;
@property (nonatomic, readonly) NSUInteger channels;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (BOOL)start:(NSError * _Nullable * _Nullable)error;
- (int32_t)stop;

@end

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
