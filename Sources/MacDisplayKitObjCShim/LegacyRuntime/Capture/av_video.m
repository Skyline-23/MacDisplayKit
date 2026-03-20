/**
 * @file src/platform/macos/av_video.m
 * @brief Definitions for video capture on macOS.
 */
// local includes
#import "av_video.h"
#import <os/lock.h>

static NSString *const kSunshineVideoCaptureQueue = @"dev.lizardbyte.sunshine.video.capture";
static NSUInteger const kScreenCaptureQueueCompactionThreshold = 64;
static CFTimeInterval const kScreenCaptureKitStartupTimeoutSeconds = 1.5;
static CFTimeInterval const kScreenCaptureKitStallTimeoutSeconds = 0.75;
static NSUInteger const kScreenCaptureKitShareableDisplayRefreshAttempts = 20;
enum : NSUInteger {
  kMaxPendingScreenCaptureSamples = 8,
};
static uint64_t const kScreenCaptureKitMinWakePollMilliseconds = 8;
static uint64_t const kScreenCaptureKitMaxWakePollMilliseconds = 33;

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
@interface AVVideo (ScreenCaptureKitPrivate)
- (void)handleScreenCaptureKitSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3));
@end

@interface AVVideoScreenStreamOutput: NSObject <SCStreamOutput>
@property (nonatomic, assign) AVVideo *owner;
- (instancetype)initWithOwner:(AVVideo *)owner;
@end

@implementation AVVideoScreenStreamOutput

- (instancetype)initWithOwner:(AVVideo *)owner {
  self = [super init];
  if (self != nil) {
    self.owner = owner;
  }
  return self;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  AVVideo *owner = self.owner;
  if (owner != nil) {
    [owner handleScreenCaptureKitSampleBuffer:sampleBuffer ofType:type];
  }
}

@end
#endif

@interface AVVideo () {
@public
  os_unfair_lock _pendingSampleBufferLock;
  CMSampleBufferRef _pendingSampleBufferRing[kMaxPendingScreenCaptureSamples];
  NSUInteger _pendingSampleBufferReadIndex;
  NSUInteger _pendingSampleBufferWriteIndex;
  NSUInteger _pendingSampleBufferCount;
}
@end

static void ScreenCaptureKitClearPendingBuffersLocked(AVVideo *video) {
  for (NSUInteger index = 0; index < kMaxPendingScreenCaptureSamples; ++index) {
    if (video->_pendingSampleBufferRing[index] != nil) {
      CFRelease(video->_pendingSampleBufferRing[index]);
      video->_pendingSampleBufferRing[index] = nil;
    }
  }
  video->_pendingSampleBufferReadIndex = 0;
  video->_pendingSampleBufferWriteIndex = 0;
  video->_pendingSampleBufferCount = 0;
}

static void ScreenCaptureKitResetPendingBuffers(AVVideo *video) {
  os_unfair_lock_lock(&video->_pendingSampleBufferLock);
  ScreenCaptureKitClearPendingBuffersLocked(video);
  os_unfair_lock_unlock(&video->_pendingSampleBufferLock);
}

static CMSampleBufferRef ScreenCaptureKitDequeuePendingBufferLocked(AVVideo *video) {
  if (video->_pendingSampleBufferCount == 0) {
    return nil;
  }

  CMSampleBufferRef sampleBuffer = video->_pendingSampleBufferRing[video->_pendingSampleBufferReadIndex];
  video->_pendingSampleBufferRing[video->_pendingSampleBufferReadIndex] = nil;
  video->_pendingSampleBufferReadIndex = (video->_pendingSampleBufferReadIndex + 1) % kMaxPendingScreenCaptureSamples;
  video->_pendingSampleBufferCount -= 1;
  return sampleBuffer;
}

static NSUInteger ScreenCaptureKitEnqueuePendingBufferLocked(AVVideo *video, CMSampleBufferRef sampleBuffer) {
  if (sampleBuffer == nil) {
    return video->_pendingSampleBufferCount;
  }

  if (video->_pendingSampleBufferCount == kMaxPendingScreenCaptureSamples) {
    CMSampleBufferRef oldest = ScreenCaptureKitDequeuePendingBufferLocked(video);
    if (oldest != nil) {
      CFRelease(oldest);
    }
  }

  video->_pendingSampleBufferRing[video->_pendingSampleBufferWriteIndex] = (CMSampleBufferRef) CFRetain(sampleBuffer);
  video->_pendingSampleBufferWriteIndex = (video->_pendingSampleBufferWriteIndex + 1) % kMaxPendingScreenCaptureSamples;
  video->_pendingSampleBufferCount += 1;
  return video->_pendingSampleBufferCount;
}

@implementation AVVideo

static CMTime ScreenCaptureFrameDurationForRequestedRate(int frameRate) {
  if (frameRate <= 0) {
    return CMTimeMake(1, 60);
  }

  if (frameRate > 60) {
    return kCMTimeZero;
  }

  return CMTimeMake(1, frameRate);
}

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
static SCCaptureResolutionType ScreenCaptureKitResolutionForSession(void) {
  const char *configuredResolution = getenv("SUNSHINE_MACOS_SCK_CAPTURE_RESOLUTION");
  if (configuredResolution != NULL) {
    if (strcasecmp(configuredResolution, "best") == 0) {
      return SCCaptureResolutionBest;
    }
    if (strcasecmp(configuredResolution, "nominal") == 0) {
      return SCCaptureResolutionNominal;
    }
    if (strcasecmp(configuredResolution, "auto") == 0 || strcasecmp(configuredResolution, "automatic") == 0) {
      return SCCaptureResolutionAutomatic;
    }
  }

  return SCCaptureResolutionAutomatic;
}
#endif

static NSUInteger ScreenCaptureKitQueueDepthForSession(AVVideo *video) {
  if (video == nil) {
    return 6;
  }

  const bool highFramerate = CMTIME_IS_VALID(video.minFrameDuration) &&
                             CMTIME_IS_NUMERIC(video.minFrameDuration) &&
                             !CMTIME_IS_INDEFINITE(video.minFrameDuration) &&
                             video.minFrameDuration.value > 0 &&
                             video.minFrameDuration.timescale > 0 &&
                             CMTimeGetSeconds(video.minFrameDuration) > 0.0 &&
                             CMTimeGetSeconds(video.minFrameDuration) <= (1.0 / 60.0);

  if (highFramerate && CMTimeGetSeconds(video.minFrameDuration) <= (1.0 / 100.0)) {
    return 3;
  }

  return highFramerate ? 4 : 6;
}

static dispatch_time_t ScreenCaptureKitWakeDeadline(AVVideo *video) {
  double frameIntervalSeconds = 1.0 / 60.0;
  if (video != nil &&
      CMTIME_IS_VALID(video.minFrameDuration) &&
      CMTIME_IS_NUMERIC(video.minFrameDuration) &&
      !CMTIME_IS_INDEFINITE(video.minFrameDuration) &&
      video.minFrameDuration.value > 0 &&
      video.minFrameDuration.timescale > 0) {
    const double candidateInterval = CMTimeGetSeconds(video.minFrameDuration);
    if (candidateInterval > 0.0) {
      frameIntervalSeconds = candidateInterval;
    }
  }

  uint64_t pollMilliseconds = (uint64_t) llround(frameIntervalSeconds * 2000.0);
  if (pollMilliseconds < kScreenCaptureKitMinWakePollMilliseconds) {
    pollMilliseconds = kScreenCaptureKitMinWakePollMilliseconds;
  } else if (pollMilliseconds > kScreenCaptureKitMaxWakePollMilliseconds) {
    pollMilliseconds = kScreenCaptureKitMaxWakePollMilliseconds;
  }
  return dispatch_time(DISPATCH_TIME_NOW, (int64_t) pollMilliseconds * (int64_t) NSEC_PER_MSEC);
}

+ (BOOL)shouldUseScreenCaptureKit {
  const char *captureBackend = getenv("SUNSHINE_MACOS_CAPTURE_BACKEND");
  if (captureBackend != NULL) {
    if (strcasecmp(captureBackend, "legacy") == 0 || strcasecmp(captureBackend, "avfoundation") == 0) {
      return NO;
    }
    if (strcasecmp(captureBackend, "sck") == 0 || strcasecmp(captureBackend, "screencapturekit") == 0) {
      return YES;
    }
  }

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if (@available(macOS 12.3, *)) {
    return YES;
  }
#endif

  return NO;
}

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
+ (SCShareableContent *)shareableContent:(NSError **)error API_AVAILABLE(macos(12.3)) {
  __block SCShareableContent *shareableContent = nil;
  __block NSError *shareableContentError = nil;
  dispatch_semaphore_t signal = dispatch_semaphore_create(0);

  [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                            onScreenWindowsOnly:NO
                                              completionHandler:^(SCShareableContent *content, NSError *contentError) {
                                                shareableContent = [content retain];
                                                shareableContentError = [contentError retain];
                                                dispatch_semaphore_signal(signal);
                                              }];

  dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

  if (error != NULL) {
    *error = [shareableContentError autorelease];
  } else if (shareableContentError != nil) {
    [shareableContentError release];
  }

  return [shareableContent autorelease];
}

+ (SCDisplay *)shareableDisplayWithID:(CGDirectDisplayID)displayID error:(NSError **)error API_AVAILABLE(macos(12.3)) {
  SCShareableContent *content = [self shareableContent:error];
  if (content == nil) {
    return nil;
  }

  for (SCDisplay *display in content.displays) {
    if (display.displayID == displayID) {
      return display;
    }
  }

  return nil;
}
#endif

// XXX: Currently, this function only returns the screen IDs as names,
// which is not very helpful to the user. The API to retrieve names
// was deprecated with 10.9+.
// However, there is a solution with little external code that can be used:
// https://stackoverflow.com/questions/20025868/cgdisplayioserviceport-is-deprecated-in-os-x-10-9-how-to-replace
+ (NSArray<NSDictionary *> *)displayNames {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if ([self shouldUseScreenCaptureKit]) {
    NSError *error = nil;
    SCShareableContent *content = [self shareableContent:&error];
    if (content != nil) {
      NSMutableArray *result = [NSMutableArray arrayWithCapacity:content.displays.count];

      for (SCDisplay *display in content.displays) {
        [result addObject:@{
          @"id": [NSNumber numberWithUnsignedInt:display.displayID],
          @"name": [NSString stringWithFormat:@"%u", display.displayID],
          @"displayName": [self getDisplayName:display.displayID] ?: [NSString stringWithFormat:@"%u", display.displayID],
        }];
      }

      return result;
    }
  }
#endif

  CGDirectDisplayID displays[kMaxDisplays];
  uint32_t count;
  if (CGGetActiveDisplayList(kMaxDisplays, displays, &count) != kCGErrorSuccess) {
    return [NSArray array];
  }

  NSMutableArray *result = [NSMutableArray array];

  for (uint32_t i = 0; i < count; i++) {
    [result addObject:@{
      @"id": [NSNumber numberWithUnsignedInt:displays[i]],
      @"name": [NSString stringWithFormat:@"%d", displays[i]],
      @"displayName": [self getDisplayName:displays[i]],
    }];
  }

  return [NSArray arrayWithArray:result];
}

+ (NSString *)getDisplayName:(CGDirectDisplayID)displayID {
  for (NSScreen *screen in [NSScreen screens]) {
    if ([screen.deviceDescription[@"NSScreenNumber"] isEqualToNumber:[NSNumber numberWithUnsignedInt:displayID]]) {
      return screen.localizedName;
    }
  }
  return nil;
}

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];

  if (self == nil) {
    return nil;
  }

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  _pendingSampleBufferLock = OS_UNFAIR_LOCK_INIT;
  ScreenCaptureKitClearPendingBuffersLocked(self);

  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  self.minFrameDuration = ScreenCaptureFrameDurationForRequestedRate(frameRate);
  self.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
  self.colorSpaceName = kCGColorSpaceITUR_709;
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if (@available(macOS 15.0, *)) {
    self.captureDynamicRange = SCCaptureDynamicRangeSDR;
  }
#endif

  CFRelease(mode);

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if ([AVVideo shouldUseScreenCaptureKit]) {
    NSError *error = nil;
    self.shareableDisplay = [AVVideo shareableDisplayWithID:self.displayID error:&error];
    if (self.shareableDisplay != nil) {
      return self;
    }
  }
#endif

  self.session = [[[AVCaptureSession alloc] init] autorelease];
  self.legacyVideoOutputs = [[[NSMapTable alloc] init] autorelease];
  self.legacyCaptureCallbacks = [[[NSMapTable alloc] init] autorelease];
  self.legacyCaptureSignals = [[[NSMapTable alloc] init] autorelease];

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:self.displayID];
  [screenInput setMinFrameDuration:self.minFrameDuration];

  if ([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
    [screenInput release];
  } else {
    [screenInput release];
    return nil;
  }

  [self.session startRunning];

  return self;
}

- (void)dealloc {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if (self.stream != nil) {
    [self stopScreenCaptureKitStream];
  }

  [self.shareableDisplay release];
  [self.stream release];
  [self.streamOutput release];
#endif

  ScreenCaptureKitResetPendingBuffers(self);

  [self.captureCallback release];
  [self.legacyVideoOutputs release];
  [self.legacyCaptureCallbacks release];
  [self.legacyCaptureSignals release];
  [self.session stopRunning];
  [self.session release];
  [super dealloc];
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;
}

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
- (BOOL)screenCaptureKitAvailableForDisplay {
  if (![AVVideo shouldUseScreenCaptureKit]) {
    return NO;
  }

  return self.shareableDisplay != nil;
}

- (BOOL)sampleBufferIsComplete:(CMSampleBufferRef)sampleBuffer API_AVAILABLE(macos(12.3)) {
  if (sampleBuffer == nil || !CMSampleBufferIsValid(sampleBuffer)) {
    return NO;
  }
  if (CMSampleBufferGetImageBuffer(sampleBuffer) == nil) {
    return NO;
  }

  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments == nil || CFArrayGetCount(attachments) == 0) {
    return YES;
  }

  CFDictionaryRef attachment = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
  CFTypeRef statusValue = CFDictionaryGetValue(attachment, SCStreamFrameInfoStatus);
  if (statusValue == nil) {
    return YES;
  }

  NSInteger status = [(__bridge NSNumber *) statusValue integerValue];
  return status == SCFrameStatusComplete ||
         status == SCFrameStatusStarted ||
         status == SCFrameStatusIdle;
}

- (BOOL)startScreenCaptureKitStream:(NSError **)error API_AVAILABLE(macos(12.3)) {
  if (![self screenCaptureKitAvailableForDisplay]) {
    return NO;
  }

  if (self.stream != nil) {
    [self stopScreenCaptureKitStream];
  }

  SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:self.shareableDisplay
                                               excludingApplications:@[]
                                                    exceptingWindows:@[]];
  SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];

  configuration.width = (size_t) MAX(self.frameWidth, 1);
  configuration.height = (size_t) MAX(self.frameHeight, 1);
  configuration.minimumFrameInterval = self.minFrameDuration;
  configuration.pixelFormat = self.pixelFormat;
  configuration.showsCursor = YES;
  configuration.queueDepth = ScreenCaptureKitQueueDepthForSession(self);
  configuration.colorMatrix = self.colorMatrix;
  configuration.colorSpaceName = self.colorSpaceName;

  if (@available(macOS 13.0, *)) {
    configuration.capturesAudio = NO;
  }

  if (@available(macOS 14.0, *)) {
    configuration.captureResolution = ScreenCaptureKitResolutionForSession();
    configuration.ignoreShadowsDisplay = YES;
  }

  if (@available(macOS 15.0, *)) {
    configuration.captureDynamicRange = self.captureDynamicRange;
  }

  const double requestedFrameRate =
    CMTIME_IS_VALID(self.minFrameDuration) &&
        CMTIME_IS_NUMERIC(self.minFrameDuration) &&
        !CMTIME_IS_INDEFINITE(self.minFrameDuration) &&
        self.minFrameDuration.value > 0 &&
        self.minFrameDuration.timescale > 0 ?
      (1.0 / CMTimeGetSeconds(self.minFrameDuration)) :
      0.0;
  NSLog(@"AVVideo ScreenCaptureKit stream config path=manual width=%zu height=%zu fps=%.3f queueDepth=%lu pixelFormat=%u dynamicRange=%ld captureResolution=%ld",
        configuration.width,
        configuration.height,
        requestedFrameRate,
        (unsigned long) configuration.queueDepth,
        (unsigned int) configuration.pixelFormat,
        (long) (self.captureDynamicRange),
        (long) (@available(macOS 14.0, *) ? configuration.captureResolution : SCCaptureResolutionAutomatic));

  dispatch_queue_attr_t captureQos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  self.sampleHandlerQueue = dispatch_queue_create(kSunshineVideoCaptureQueue.UTF8String, captureQos);
  self.streamOutput = [[[AVVideoScreenStreamOutput alloc] initWithOwner:self] autorelease];
  self.stream = [[[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self] autorelease];

  NSError *streamError = nil;
  if (![self.stream addStreamOutput:self.streamOutput type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleHandlerQueue error:&streamError]) {
    if (error != NULL) {
      *error = streamError;
    }

    self.stream = nil;
    self.streamOutput = nil;
    [configuration release];
    [filter release];
    return NO;
  }

  dispatch_semaphore_t signal = dispatch_semaphore_create(0);
  __block NSError *startError = nil;
  [self.stream startCaptureWithCompletionHandler:^(NSError *captureError) {
    startError = [captureError retain];
    dispatch_semaphore_signal(signal);
  }];
  dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

  [configuration release];
  [filter release];

  if (startError != nil) {
    if (error != NULL) {
      *error = [startError autorelease];
    } else {
      [startError release];
    }

    [self.stream stopCaptureWithCompletionHandler:^(__unused NSError *stopError) {
    }];
    self.stream = nil;
    self.streamOutput = nil;
    return NO;
  }

  return YES;
}

- (BOOL)refreshShareableDisplay:(NSError **)error API_AVAILABLE(macos(12.3)) {
  NSError *refreshError = nil;
  SCDisplay *display = nil;

  for (NSUInteger attempt = 0; attempt < kScreenCaptureKitShareableDisplayRefreshAttempts; ++attempt) {
    display = [AVVideo shareableDisplayWithID:self.displayID error:&refreshError];
    if (display != nil) {
      break;
    }

    [NSThread sleepForTimeInterval:0.1];
  }

  if (display == nil) {
    if (error != NULL) {
      *error = refreshError;
    }
    return NO;
  }

  self.shareableDisplay = display;
  return YES;
}

- (void)stopScreenCaptureKitStream API_AVAILABLE(macos(12.3)) {
  if (self.stream == nil) {
    return;
  }

  dispatch_semaphore_t signal = dispatch_semaphore_create(0);
  SCStream *stream = [self.stream retain];
  AVVideoScreenStreamOutput *streamOutput = [self.streamOutput retain];
  self.stream = nil;
  self.streamOutput = nil;
  self.sampleHandlerQueue = nil;

  [stream stopCaptureWithCompletionHandler:^(__unused NSError *stopError) {
    dispatch_semaphore_signal(signal);
  }];
  dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

  streamOutput.owner = nil;
  [streamOutput release];
  [stream release];
}

- (BOOL)beginScreenCaptureKitCapture:(NSError **)error API_AVAILABLE(macos(12.3)) {
  self.frameAvailableSignal = dispatch_semaphore_create(0);
  self.captureStopped = NO;
  self.captureSignal = nil;
  self.captureCallback = nil;
  self.screenCaptureFrameCount = 0;
  self.screenCaptureCallbackCount = 0;
  self.screenCaptureDroppedFrameCount = 0;
  self.screenCaptureStartTime = CFAbsoluteTimeGetCurrent();
  self.screenCaptureLastFrameTime = self.screenCaptureStartTime;
  ScreenCaptureKitResetPendingBuffers(self);

  NSError *refreshError = nil;
  if (![self refreshShareableDisplay:&refreshError]) {
    if (error != NULL) {
      *error = refreshError;
    }
    self.frameAvailableSignal = nil;
    return NO;
  }

  if (![self startScreenCaptureKitStream:error]) {
    self.frameAvailableSignal = nil;
    return NO;
  }

  return YES;
}

- (CMSampleBufferRef)copyNextScreenCaptureKitSampleBuffer API_AVAILABLE(macos(12.3)) {
  while (true) {
    dispatch_semaphore_t frameSignal = self.frameAvailableSignal;
    if (frameSignal == nil) {
      return nil;
    }

    dispatch_time_t wakeDeadline = ScreenCaptureKitWakeDeadline(self);
    if (dispatch_semaphore_wait(frameSignal, wakeDeadline) != 0) {
      @synchronized(self) {
        if (self.captureStopped || self.frameAvailableSignal == nil) {
          break;
        }
        if (self.screenCaptureFrameCount > 0 &&
            (CFAbsoluteTimeGetCurrent() - self.screenCaptureLastFrameTime) >= kScreenCaptureKitStallTimeoutSeconds) {
          NSLog(@"AVVideo ScreenCaptureKit stalled after %llu queued frames; restarting capture", self.screenCaptureFrameCount);
          return nil;
        }
        if (self.screenCaptureFrameCount == 0 &&
            (CFAbsoluteTimeGetCurrent() - self.screenCaptureStartTime) >= kScreenCaptureKitStartupTimeoutSeconds) {
          NSLog(@"AVVideo ScreenCaptureKit did not produce an initial frame within %.1fs", kScreenCaptureKitStartupTimeoutSeconds);
          return nil;
        }
      }
      continue;
    }

    CMSampleBufferRef sampleBuffer = nil;
    BOOL captureStopped = NO;
    os_unfair_lock_lock(&_pendingSampleBufferLock);
    sampleBuffer = ScreenCaptureKitDequeuePendingBufferLocked(self);
    captureStopped = self.captureStopped;
    os_unfair_lock_unlock(&_pendingSampleBufferLock);

    if (sampleBuffer == nil) {
      if (captureStopped) {
        break;
      }
      continue;
    }
    return sampleBuffer;
  }

  return nil;
}

- (void)finishScreenCaptureKitCapture API_AVAILABLE(macos(12.3)) {
  dispatch_semaphore_t frameSignal = self.frameAvailableSignal;
  os_unfair_lock_lock(&_pendingSampleBufferLock);
  self.captureStopped = YES;
  ScreenCaptureKitClearPendingBuffersLocked(self);
  os_unfair_lock_unlock(&_pendingSampleBufferLock);
  if (frameSignal != nil) {
    dispatch_semaphore_signal(frameSignal);
  }
  [self stopScreenCaptureKitStream];
  self.frameAvailableSignal = nil;
}

- (void)handleScreenCaptureKitSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  self.screenCaptureCallbackCount += 1;
  if (self.screenCaptureCallbackCount <= 10 || (self.screenCaptureCallbackCount % 120) == 0) {
    CVImageBufferRef imageBuffer = sampleBuffer != nil ? CMSampleBufferGetImageBuffer(sampleBuffer) : nil;
    NSLog(@"AVVideo ScreenCaptureKit callback #%llu imageBuffer=%s",
          self.screenCaptureCallbackCount,
          imageBuffer != nil ? "yes" : "no");
  }

  if (![self sampleBufferIsComplete:sampleBuffer]) {
    self.screenCaptureDroppedFrameCount += 1;
    if (self.screenCaptureDroppedFrameCount <= 10 || (self.screenCaptureDroppedFrameCount % 120) == 0) {
      NSInteger status = -1;
      CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
      if (attachments != nil && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = (CFDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
        CFTypeRef statusValue = CFDictionaryGetValue(attachment, SCStreamFrameInfoStatus);
        if (statusValue != nil) {
          status = [(__bridge NSNumber *) statusValue integerValue];
        }
      }
      NSLog(@"AVVideo ScreenCaptureKit dropped frame status=%ld dropped=%llu callbacks=%llu",
            (long) status,
            self.screenCaptureDroppedFrameCount,
            self.screenCaptureCallbackCount);
    }
    return;
  }

  dispatch_semaphore_t frameSignal = self.frameAvailableSignal;
  if (frameSignal == nil) {
    return;
  }

  NSUInteger pendingCount = 0;
  os_unfair_lock_lock(&_pendingSampleBufferLock);
  pendingCount = ScreenCaptureKitEnqueuePendingBufferLocked(self, sampleBuffer);
  self.screenCaptureFrameCount += 1;
  self.screenCaptureLastFrameTime = CFAbsoluteTimeGetCurrent();
  os_unfair_lock_unlock(&_pendingSampleBufferLock);
  if (self.screenCaptureFrameCount <= 5 || (self.screenCaptureFrameCount % 120) == 0) {
    NSLog(@"AVVideo ScreenCaptureKit queued frame #%llu callbacks=%llu pending=%lu",
          self.screenCaptureFrameCount,
          self.screenCaptureCallbackCount,
          (unsigned long) pendingCount);
  }
  dispatch_semaphore_signal(frameSignal);
}
#endif

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
#if SUNSHINE_HAVE_SCREENCAPTUREKIT
  if ([self screenCaptureKitAvailableForDisplay]) {
    return nil;
  }
#endif

  @synchronized(self) {
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];

    [videoOutput setVideoSettings:@{
      (NSString *) kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:self.pixelFormat],
      (NSString *) kCVPixelBufferWidthKey: [NSNumber numberWithInt:self.frameWidth],
      (NSString *) kCVPixelBufferHeightKey: [NSNumber numberWithInt:self.frameHeight],
      (NSString *) AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    }];

    dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
    dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);
    [videoOutput setSampleBufferDelegate:self queue:recordingQueue];

    [self.session stopRunning];

    if ([self.session canAddOutput:videoOutput]) {
      [self.session addOutput:videoOutput];
    } else {
      [videoOutput release];
      return nil;
    }

    AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);

    [self.legacyVideoOutputs setObject:videoOutput forKey:videoConnection];
    [self.legacyCaptureCallbacks setObject:frameCallback forKey:videoConnection];
    [self.legacyCaptureSignals setObject:signal forKey:videoConnection];

    [self.session startRunning];

    return signal;
  }
}

#if SUNSHINE_HAVE_SCREENCAPTUREKIT
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  [self handleScreenCaptureKitSampleBuffer:sampleBuffer ofType:type];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
  dispatch_semaphore_t frameSignal = self.frameAvailableSignal;
  NSLog(@"AVVideo ScreenCaptureKit stream stopped with error: %@", error);
  os_unfair_lock_lock(&_pendingSampleBufferLock);
  self.captureStopped = YES;
  ScreenCaptureKitClearPendingBuffersLocked(self);
  os_unfair_lock_unlock(&_pendingSampleBufferLock);

  if (frameSignal != nil) {
    dispatch_semaphore_signal(frameSignal);
  }
}
#endif

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  FrameCallbackBlock callback = [self.legacyCaptureCallbacks objectForKey:connection];

  if (callback != nil) {
    if (!callback(sampleBuffer)) {
      @synchronized(self) {
        [self.session stopRunning];
        [self.legacyCaptureCallbacks removeObjectForKey:connection];
        [self.session removeOutput:[self.legacyVideoOutputs objectForKey:connection]];
        [self.legacyVideoOutputs removeObjectForKey:connection];
        dispatch_semaphore_signal([self.legacyCaptureSignals objectForKey:connection]);
        [self.legacyCaptureSignals removeObjectForKey:connection];
        [self.session startRunning];
      }
    }
  }
}

@end
