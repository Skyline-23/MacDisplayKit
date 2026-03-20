/**
 * @file src/platform/macos/av_audio.m
 * @brief Definitions for audio capture on macOS.
 */
// local includes
#import "av_audio.h"

@implementation AVAudio

+ (NSArray<AVCaptureDevice *> *)microphones {
  if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:((NSOperatingSystemVersion) {10, 15, 0})]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone, AVCaptureDeviceTypeExternalUnknown]
                                                                                                               mediaType:AVMediaTypeAudio
                                                                                                                position:AVCaptureDevicePositionUnspecified];
    return discoverySession.devices;
#pragma clang diagnostic pop
  } else {
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

- (void)prepareAudioBuffer {
  self.samplesArrivedSignal = [[NSCondition alloc] init];
  self.captureStopped = NO;
  TPCircularBufferInit(&self->audioSampleBuffer, kBufferLength * self.channels * sizeof(float));
}

- (void)stopCapture {
  self.captureStopped = YES;

  [self.samplesArrivedSignal lock];
  [self.samplesArrivedSignal signal];
  [self.samplesArrivedSignal unlock];

  if (self.audioCaptureSession != nil) {
    [self.audioCaptureSession stopRunning];
  }
}

- (void)dealloc {
  self.audioConnection = nil;
  [self stopCapture];
  TPCircularBufferCleanup(&audioSampleBuffer);
}

- (int)setupMicrophone:(AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels {
  self.sampleRate = sampleRate;
  self.frameSize = frameSize;
  self.channels = channels;
  self.audioCaptureSession = [[AVCaptureSession alloc] init];

  NSError *error;
  AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (audioInput == nil) {
    return -1;
  }

  if ([self.audioCaptureSession canAddInput:audioInput]) {
    [self.audioCaptureSession addInput:audioInput];
  } else {
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
  dispatch_queue_t recordingQueue = dispatch_queue_create("dev.lizardbyte.sunshine.audio.capture", qos);

  [audioOutput setSampleBufferDelegate:self queue:recordingQueue];

  if ([self.audioCaptureSession canAddOutput:audioOutput]) {
    [self.audioCaptureSession addOutput:audioOutput];
  } else {
    return -1;
  }

  self.audioConnection = [audioOutput connectionWithMediaType:AVMediaTypeAudio];

  [self.audioCaptureSession startRunning];
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
  (void) displayID;
  (void) sampleRate;
  (void) frameSize;
  (void) channels;
  return -1;
}

- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  if (connection == self.audioConnection) {
    [self handleCapturedSampleBuffer:sampleBuffer];
  }
}

@end
