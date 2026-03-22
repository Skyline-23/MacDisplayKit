/**
 * @file src/platform/macos/av_audio.h
 * @brief Declarations for audio capture on macOS.
 */
#pragma once

// platform includes
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// lib includes
#include "../third-party/TPCircularBuffer/TPCircularBuffer.h"

#define kBufferLength 4096

@interface AVAudio: NSObject <AVCaptureAudioDataOutputSampleBufferDelegate> {
@public
  TPCircularBuffer audioSampleBuffer;
}

@property (nonatomic, copy) void (^sampleHandler)(NSData *samples,
                                                  uint64_t sourceTimeNanoseconds,
                                                  UInt32 sampleRate,
                                                  UInt8 channels,
                                                  UInt32 frameCount);
@property (nonatomic, retain) AVCaptureSession *audioCaptureSession;
@property (nonatomic, retain) AVCaptureConnection *audioConnection;
@property (nonatomic, retain) NSCondition *samplesArrivedSignal;
@property (nonatomic, assign) UInt32 sampleRate;
@property (nonatomic, assign) UInt32 frameSize;
@property (nonatomic, assign) UInt8 channels;
@property (nonatomic, assign) BOOL captureStopped;

+ (NSArray<AVCaptureDevice *> *)microphones;
+ (NSArray *)microphoneNames;
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)microphoneDescriptors;
+ (AVCaptureDevice *)findMicrophone:(NSString *)name;
+ (AVCaptureDevice *)findMicrophoneByID:(NSString *)uniqueID;

- (int)setupMicrophone:(AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;
- (int)setupSystemAudioWithDisplayID:(CGDirectDisplayID)displayID sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;
- (void)stopCapture;

@end
