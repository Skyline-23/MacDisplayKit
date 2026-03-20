/**
 * @file src/platform/macos/av_audio.m
 * @brief Definitions for audio capture on macOS.
 */
// local includes
#import "av_audio.h"

static NSString *const kSunshineAudioCaptureQueue = @"dev.lizardbyte.sunshine.audio.capture";

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@interface AVAudio (ScreenCaptureKitPrivate)
- (void)handleScreenCaptureKitSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3));
@end

@interface AVAudioStreamOutput: NSObject <SCStreamOutput>
@property (nonatomic, assign) AVAudio *owner;
- (instancetype)initWithOwner:(AVAudio *)owner;
@end

@implementation AVAudioStreamOutput

- (instancetype)initWithOwner:(AVAudio *)owner {
  self = [super init];
  if (self != nil) {
    self.owner = owner;
  }
  return self;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  AVAudio *owner = self.owner;
  if (owner != nil) {
    [owner handleScreenCaptureKitSampleBuffer:sampleBuffer ofType:type];
  }
}

@end
#endif

@implementation AVAudio

+ (BOOL)shouldUseScreenCaptureKitAudio {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 13.0, *)) {
    return YES;
  }
#endif

  return NO;
}

+ (NSArray<AVCaptureDevice *> *)microphones {
  if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})]) {
    // This will generate a warning about AVCaptureDeviceDiscoverySession being
    // unavailable before macOS 10.15, but we have a guard to prevent it from
    // being called on those earlier systems.
    // Unfortunately the supported way to silence this warning, using @available,
    // produces linker errors for __isPlatformVersionAtLeast, so we have to use
    // a different method.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone, AVCaptureDeviceTypeExternalUnknown]
                                                                                                               mediaType:AVMediaTypeAudio
                                                                                                                position:AVCaptureDevicePositionUnspecified];
    return discoverySession.devices;
#pragma clang diagnostic pop
  } else {
    // We're intentionally using a deprecated API here specifically for versions
    // of macOS where it's not deprecated, so we can ignore any deprecation
    // warnings:
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop
  }
}

+ (NSArray<NSString *> *)microphoneNames {
  NSMutableArray *result = [[NSMutableArray alloc] init];

  for (AVCaptureDevice *device in [AVAudio microphones]) {
    [result addObject:[device localizedName]];
  }

  return result;
}

+ (AVCaptureDevice *)findMicrophone:(NSString *)name {
  for (AVCaptureDevice *device in [AVAudio microphones]) {
    if ([[device localizedName] isEqualToString:name]) {
      return device;
    }
  }

  return nil;
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
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

- (void)prepareAudioBuffer {
  self.samplesArrivedSignal = [[[NSCondition alloc] init] autorelease];
  self.captureStopped = NO;
  TPCircularBufferInit(&self->audioSampleBuffer, kBufferLength * self.channels * sizeof(float));
}

- (void)stopCapture {
  self.captureStopped = YES;

  [self.samplesArrivedSignal lock];
  [self.samplesArrivedSignal signal];
  [self.samplesArrivedSignal unlock];

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (self.stream != nil) {
    dispatch_semaphore_t stopSignal = dispatch_semaphore_create(0);
    SCStream *stream = [self.stream retain];
    AVAudioStreamOutput *streamOutput = [self.streamOutput retain];
    self.stream = nil;
    self.streamOutput = nil;
    self.sampleHandlerQueue = nil;

    [stream stopCaptureWithCompletionHandler:^(__unused NSError *stopError) {
      dispatch_semaphore_signal(stopSignal);
    }];
    dispatch_semaphore_wait(stopSignal, DISPATCH_TIME_FOREVER);
    streamOutput.owner = nil;
    [streamOutput release];
    [stream release];
  }
#endif

  if (self.audioCaptureSession != nil) {
    [self.audioCaptureSession stopRunning];
  }
}

- (void)dealloc {
  // make sure we don't process any further samples
  self.audioConnection = nil;
  [self stopCapture];

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  [self.streamOutput release];
  [self.shareableDisplay release];
#endif

  [self.audioCaptureSession release];

  // make sure nothing gets stuck on this signal
  [self.samplesArrivedSignal release];
  TPCircularBufferCleanup(&audioSampleBuffer);
  [super dealloc];
}

- (int)setupMicrophone:(AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
  self.sampleRate = sampleRate;
  self.frameSize = frameSize;
  self.channels = channels;
  self.audioCaptureSession = [[[AVCaptureSession alloc] init] autorelease];

  NSError *error;
  AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (audioInput == nil) {
    return -1;
  }

  if ([self.audioCaptureSession canAddInput:audioInput]) {
    [self.audioCaptureSession addInput:audioInput];
  } else {
    [audioInput dealloc];
    return -1;
  }

  AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];

  [audioOutput setAudioSettings:@{
    (NSString *) AVFormatIDKey: [NSNumber numberWithUnsignedInt:kAudioFormatLinearPCM],
    (NSString *) AVSampleRateKey: [NSNumber numberWithUnsignedInt:sampleRate],
    (NSString *) AVNumberOfChannelsKey: [NSNumber numberWithUnsignedInt:channels],
    (NSString *) AVLinearPCMBitDepthKey: [NSNumber numberWithUnsignedInt:32],
    (NSString *) AVLinearPCMIsFloatKey: @YES,
    (NSString *) AVLinearPCMIsNonInterleaved: @NO
  }];

  dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
  dispatch_queue_t recordingQueue = dispatch_queue_create(kSunshineAudioCaptureQueue.UTF8String, qos);

  [audioOutput setSampleBufferDelegate:self queue:recordingQueue];

  if ([self.audioCaptureSession canAddOutput:audioOutput]) {
    [self.audioCaptureSession addOutput:audioOutput];
  } else {
    [audioInput release];
    [audioOutput release];
    return -1;
  }

  self.audioConnection = [audioOutput connectionWithMediaType:AVMediaTypeAudio];

  [self.audioCaptureSession startRunning];

  [audioInput release];
  [audioOutput release];

  [self prepareAudioBuffer];

  return 0;
}

- (void)appendInterleavedFloatSamples:(const float *)samples sampleCount:(UInt32)sampleCount {
  if (samples == NULL || sampleCount == 0) {
    return;
  }

  TPCircularBufferProduceBytes(&self->audioSampleBuffer, samples, sampleCount * sizeof(float));
  [self.samplesArrivedSignal lock];
  [self.samplesArrivedSignal signal];
  [self.samplesArrivedSignal unlock];
}

- (void)appendSamplesFromBufferList:(const AudioBufferList *)audioBufferList
                         frameCount:(UInt32)frameCount
                              asbd:(const AudioStreamBasicDescription *)streamDescription {
  static BOOL warnedUnsupportedFormat = NO;

  if (audioBufferList == NULL || streamDescription == NULL || frameCount == 0) {
    return;
  }

  BOOL isFloat = (streamDescription->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  BOOL isNonInterleaved = (streamDescription->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

  if (!isFloat || streamDescription->mBitsPerChannel != 32) {
    if (!warnedUnsupportedFormat) {
      warnedUnsupportedFormat = YES;
      NSLog(@"Unsupported macOS audio capture format. Expected 32-bit float PCM.");
    }
    return;
  }

  if (!isNonInterleaved && audioBufferList->mNumberBuffers == 1) {
    const AudioBuffer audioBuffer = audioBufferList->mBuffers[0];
    [self appendInterleavedFloatSamples:(const float *) audioBuffer.mData
                            sampleCount:frameCount * self.channels];
    return;
  }

  if (isNonInterleaved && audioBufferList->mNumberBuffers >= self.channels) {
    NSMutableData *interleavedSamples = [NSMutableData dataWithLength:frameCount * self.channels * sizeof(float)];
    float *interleaved = (float *) interleavedSamples.mutableBytes;

    for (UInt32 frame = 0; frame < frameCount; frame++) {
      for (UInt32 channel = 0; channel < self.channels; channel++) {
        const AudioBuffer audioBuffer = audioBufferList->mBuffers[channel];
        const float *channelSamples = (const float *) audioBuffer.mData;
        interleaved[(frame * self.channels) + channel] = channelSamples[frame];
      }
    }

    [self appendInterleavedFloatSamples:interleaved sampleCount:frameCount * self.channels];
  }
}

- (void)handleCapturedSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  if (sampleBuffer == nil || !CMSampleBufferIsValid(sampleBuffer)) {
    return;
  }

  CMAudioFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
  const AudioStreamBasicDescription *streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
  if (streamDescription == NULL) {
    return;
  }

  AudioBufferList audioBufferList;
  CMBlockBufferRef blockBuffer = nil;
  if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &audioBufferList, sizeof(audioBufferList), NULL, NULL, 0, &blockBuffer) != noErr) {
    return;
  }

  UInt32 frameCount = (UInt32) CMSampleBufferGetNumSamples(sampleBuffer);
  [self appendSamplesFromBufferList:&audioBufferList frameCount:frameCount asbd:streamDescription];

  if (blockBuffer != nil) {
    CFRelease(blockBuffer);
  }
}

- (int)setupSystemAudioWithDisplayID:(CGDirectDisplayID)displayID sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (![AVAudio shouldUseScreenCaptureKitAudio]) {
    return -1;
  }

  self.sampleRate = sampleRate;
  self.frameSize = frameSize;
  self.channels = channels;

  NSError *error = nil;
  self.shareableDisplay = [AVAudio shareableDisplayWithID:displayID error:&error];
  if (self.shareableDisplay == nil) {
    return -1;
  }

  [self prepareAudioBuffer];

  if (@available(macOS 13.0, *)) {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:self.shareableDisplay
                                                 excludingApplications:@[]
                                                      exceptingWindows:@[]];
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    configuration.width = 2;
    configuration.height = 2;
    configuration.minimumFrameInterval = kCMTimeZero;
    configuration.queueDepth = 3;
    configuration.showsCursor = NO;
    configuration.capturesAudio = YES;
    configuration.sampleRate = sampleRate;
    configuration.channelCount = channels;
    configuration.excludesCurrentProcessAudio = YES;

    self.sampleHandlerQueue = dispatch_queue_create(kSunshineAudioCaptureQueue.UTF8String, DISPATCH_QUEUE_SERIAL);
    self.streamOutput = [[[AVAudioStreamOutput alloc] initWithOwner:self] autorelease];
    self.stream = [[[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self] autorelease];

    NSError *streamError = nil;
    if (![self.stream addStreamOutput:self.streamOutput type:SCStreamOutputTypeAudio sampleHandlerQueue:self.sampleHandlerQueue error:&streamError]) {
      self.stream = nil;
      self.streamOutput = nil;
      [configuration release];
      [filter release];
      return -1;
    }
    if (![self.stream addStreamOutput:self.streamOutput type:SCStreamOutputTypeScreen sampleHandlerQueue:self.sampleHandlerQueue error:&streamError]) {
      self.stream = nil;
      self.streamOutput = nil;
      [configuration release];
      [filter release];
      return -1;
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
      [self.stream stopCaptureWithCompletionHandler:^(__unused NSError *stopError) {
      }];
      self.stream = nil;
      self.streamOutput = nil;
      [startError release];
      return -1;
    }

    return 0;
  }
#endif

  return -1;
}

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  if (connection == self.audioConnection) {
    [self handleCapturedSampleBuffer:sampleBuffer];
  }
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (void)handleScreenCaptureKitSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type == SCStreamOutputTypeAudio) {
    [self handleCapturedSampleBuffer:sampleBuffer];
  }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  [self handleScreenCaptureKitSampleBuffer:sampleBuffer ofType:type];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
}
#endif

@end
