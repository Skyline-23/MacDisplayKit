#import <Foundation/Foundation.h>
#import <mach/mach_time.h>

#import "MDKObjCShim.h"

#import "../LegacyRuntime/Capture/av_audio.h"

#include <atomic>
#include <thread>

namespace {
uint64_t MDKCurrentHostTimeNanoseconds() {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });

    const uint64_t now = mach_absolute_time();
    return (now * timebase.numer) / timebase.denom;
}

AVCaptureDevice *MDKResolveMicrophoneDevice(NSString *inputID) {
    if (inputID.length > 0) {
        return [AVAudio findMicrophoneByID:inputID];
    }

    return AVAudio.microphones.firstObject;
}
}  // namespace

NSArray<NSDictionary<NSString *, NSString *> *> *MDKShimMicrophoneDescriptors(void) {
    return [AVAudio microphoneDescriptors];
}

@implementation MDKShimMicrophoneCaptureSession {
    AVAudio *_audioCapture;
    MDKShimAudioCaptureFrameHandler _frameHandler;
    std::atomic<bool> _running;
    std::thread _readerThread;
}

- (instancetype)initWithInputID:(NSString * _Nullable)inputID
                     sampleRate:(NSUInteger)sampleRate
                      frameSize:(NSUInteger)frameSize
                       channels:(NSUInteger)channels
                   frameHandler:(MDKShimAudioCaptureFrameHandler)frameHandler {
    self = [super init];
    if (!self) {
        return nil;
    }

    _inputID = [inputID copy];
    _sampleRate = MAX(sampleRate, 1);
    _frameSize = MAX(frameSize, 1);
    _channels = MAX(channels, 1);
    _frameHandler = [frameHandler copy];
    _running.store(false);
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning {
    return _running.load(std::memory_order_acquire);
}

- (BOOL)start:(NSError * _Nullable * _Nullable)error {
    if (_running.exchange(true, std::memory_order_acq_rel)) {
        return YES;
    }

    AVCaptureDevice *device = MDKResolveMicrophoneDevice(_inputID);
    if (device == nil) {
        _running.store(false, std::memory_order_release);
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.AudioCapture"
                                         code:1
                                     userInfo:@ {
                                         NSLocalizedDescriptionKey: @"Unable to resolve the requested microphone input."
                                     }];
        }
        return NO;
    }

    _inputID = [device.uniqueID copy];
    _audioCapture = [[AVAudio alloc] init];
    if (_audioCapture == nil ||
        [_audioCapture setupMicrophone:device
                            sampleRate:(UInt32) _sampleRate
                             frameSize:(UInt32) _frameSize
                              channels:(UInt8) _channels] != 0) {
        _running.store(false, std::memory_order_release);
        if (_audioCapture != nil) {
            [_audioCapture stopCapture];
            _audioCapture = nil;
        }
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.AudioCapture"
                                         code:2
                                     userInfo:@ {
                                         NSLocalizedDescriptionKey: @"Unable to start microphone capture."
                                     }];
        }
        return NO;
    }

    __weak MDKShimMicrophoneCaptureSession *weakSelf = self;
    _readerThread = std::thread([weakSelf]() {
        @autoreleasepool {
            [weakSelf drainBufferedSamples];
        }
    });
    return YES;
}

- (int32_t)stop {
    const bool wasRunning = _running.exchange(false, std::memory_order_acq_rel);
    if (_audioCapture != nil) {
        [_audioCapture stopCapture];
    }
    if (_readerThread.joinable()) {
        _readerThread.join();
    }
    if (_audioCapture != nil) {
        _audioCapture = nil;
    }
    return wasRunning ? 0 : 0;
}

- (void)drainBufferedSamples {
    const uint32_t bytesPerFrame = (uint32_t) (_channels * sizeof(float));
    const uint32_t bytesPerChunk = (uint32_t) (_frameSize * bytesPerFrame);

    while (_running.load(std::memory_order_acquire)) {
        if (_audioCapture == nil) {
            break;
        }

        uint32_t availableBytes = 0;
        void *tail = TPCircularBufferTail(&_audioCapture->audioSampleBuffer, &availableBytes);

        while (_running.load(std::memory_order_acquire) && availableBytes < bytesPerChunk) {
            if (_audioCapture.captureStopped) {
                return;
            }

            [_audioCapture.samplesArrivedSignal lock];
            [_audioCapture.samplesArrivedSignal waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            [_audioCapture.samplesArrivedSignal unlock];

            tail = TPCircularBufferTail(&_audioCapture->audioSampleBuffer, &availableBytes);
        }

        if (!_running.load(std::memory_order_acquire) || tail == nullptr || availableBytes < bytesPerChunk) {
            continue;
        }

        NSData *pcmData = [NSData dataWithBytes:tail length:bytesPerChunk];
        TPCircularBufferConsume(&_audioCapture->audioSampleBuffer, bytesPerChunk);
        _frameHandler(
            MDKCurrentHostTimeNanoseconds(),
            pcmData,
            _frameSize,
            _channels,
            _sampleRate
        );
    }
}

@end
