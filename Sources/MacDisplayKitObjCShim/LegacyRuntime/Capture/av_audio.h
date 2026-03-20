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

@property (nonatomic, retain) AVCaptureSession *audioCaptureSession;
@property (nonatomic, retain) AVCaptureConnection *audioConnection;
@property (nonatomic, retain) NSCondition *samplesArrivedSignal;
@property (nonatomic, assign) UInt32 sampleRate;
@property (nonatomic, assign) UInt32 frameSize;
@property (nonatomic, assign) UInt8 channels;
@property (nonatomic, assign) BOOL captureStopped;

+ (NSArray *)microphoneNames;
+ (AVCaptureDevice *)findMicrophone:(NSString *)name;

- (int)setupMicrophone:(AVCaptureDevice *)device sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;
- (int)setupSystemAudioWithDisplayID:(CGDirectDisplayID)displayID sampleRate:(UInt32)sampleRate frameSize:(UInt32)frameSize channels:(UInt8)channels;
- (void)stopCapture;

@end
