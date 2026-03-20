/**
 * @file src/platform/macos/av_video.h
 * @brief Declarations for video capture on macOS.
 */
#pragma once

// platform includes
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  #import <ScreenCaptureKit/ScreenCaptureKit.h>
  #define SUNSHINE_HAVE_SCREENCAPTUREKIT 1
#else
  #define SUNSHINE_HAVE_SCREENCAPTUREKIT 0
#endif

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
@class AVVideoScreenStreamOutput;
#endif

@interface AVVideo: NSObject <AVCaptureVideoDataOutputSampleBufferDelegate
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
, SCStreamDelegate, SCStreamOutput
#endif
>

#define kMaxDisplays 32

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) CMTime minFrameDuration;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;
@property (nonatomic, assign) CFStringRef colorMatrix;
@property (nonatomic, assign) CFStringRef colorSpaceName;
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
@property (nonatomic, assign) SCCaptureDynamicRange captureDynamicRange API_AVAILABLE(macos(15.0));
#endif

typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

@property (nonatomic, retain) AVCaptureSession *session;
@property (nonatomic, retain) NSMapTable<AVCaptureConnection *, AVCaptureVideoDataOutput *> *legacyVideoOutputs;
@property (nonatomic, retain) NSMapTable<AVCaptureConnection *, FrameCallbackBlock> *legacyCaptureCallbacks;
@property (nonatomic, retain) NSMapTable<AVCaptureConnection *, dispatch_semaphore_t> *legacyCaptureSignals;
@property (nonatomic, copy) FrameCallbackBlock captureCallback;
@property (nonatomic, retain) dispatch_semaphore_t captureSignal;
@property (nonatomic, retain) dispatch_semaphore_t frameAvailableSignal;
@property (nonatomic, assign) BOOL captureStopped;
@property (nonatomic, assign) uint64_t screenCaptureFrameCount;
@property (nonatomic, assign) uint64_t screenCaptureCallbackCount;
@property (nonatomic, assign) uint64_t screenCaptureDroppedFrameCount;
@property (nonatomic, assign) CFAbsoluteTime screenCaptureStartTime;
@property (nonatomic, assign) CFAbsoluteTime screenCaptureLastFrameTime;

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
@property (nonatomic, retain) SCDisplay *shareableDisplay;
@property (nonatomic, retain) SCStream *stream;
@property (nonatomic, retain) AVVideoScreenStreamOutput *streamOutput;
@property (nonatomic, retain) dispatch_queue_t sampleHandlerQueue;

- (BOOL)refreshShareableDisplay:(NSError **)error API_AVAILABLE(macos(12.3));
- (BOOL)screenCaptureKitAvailableForDisplay API_AVAILABLE(macos(12.3));
- (BOOL)beginScreenCaptureKitCapture:(NSError **)error API_AVAILABLE(macos(12.3));
- (CMSampleBufferRef)copyNextScreenCaptureKitSampleBuffer API_AVAILABLE(macos(12.3));
- (void)finishScreenCaptureKitCapture API_AVAILABLE(macos(12.3));
#endif

+ (NSArray<NSDictionary *> *)displayNames;
+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID;

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback;

@end
