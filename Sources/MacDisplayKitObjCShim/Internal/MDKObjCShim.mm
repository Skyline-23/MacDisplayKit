#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <pthread.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <xpc/xpc.h>

#import "MDKObjCShim.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

#import "../LegacyRuntime/Capture/av_audio.h"
#import "../LegacyRuntime/Capture/av_video.h"
#include "../LegacyRuntime/VirtualDisplay/virtual_display.h"

namespace {
constexpr int MDKBlockHasCopyDispose = (1 << 25);
constexpr int MDKBlockHasSignature = (1 << 30);

struct MDKBlockDescriptor {
    unsigned long reserved;
    unsigned long size;
    void (*copy_helper)(void *dst, const void *src);
    void (*dispose_helper)(const void *src);
    const char *signature;
    const char *layout;
};

struct MDKBlockLiteral {
    void *isa;
    int flags;
    int reserved;
    void (*invoke)(void *, ...);
    MDKBlockDescriptor *descriptor;
};
}  // namespace

NSString *MDKShimVersionString(void) {
    return @"0.1.0";
}

NSURL *MDKShimRepositoryRootURL(void) {
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    return [NSURL fileURLWithPath:cwd isDirectory:YES];
}

NSURL *MDKShimLegacyRuntimeSourceRootURL(void) {
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString *path = [cwd stringByAppendingPathComponent:@"Sources/MacDisplayKitObjCShim/LegacyRuntime"];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

NSArray<NSString *> *MDKShimPlannedModuleNames(void) {
    return @[
        @"MacDisplayCaptureKit",
        @"MacDisplayVirtualDisplayKit",
        @"MacDisplayKit",
        @"MacDisplayKitObjCShim",
    ];
}

NSArray<NSDictionary<NSString *, id> *> *MDKShimListDisplays(void) {
    return [AVVideo displayNames];
}

NSString * _Nullable MDKShimDisplayName(NSUInteger displayID) {
    return [AVVideo getDisplayName:static_cast<CGDirectDisplayID>(displayID)];
}

BOOL MDKShimScreenCaptureAccessAuthorized(void) {
    return CGPreflightScreenCaptureAccess();
}

BOOL MDKShimVideoAVFoundationAvailableForDisplay(NSUInteger displayID, NSInteger frameRate) {
    AVVideo *video = [[AVVideo alloc] initWithDisplay:static_cast<CGDirectDisplayID>(displayID) frameRate:static_cast<int>(frameRate)];
    return video != nil;
}

BOOL MDKShimVideoCGDisplayStreamAvailableForDisplay(NSUInteger displayID) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(static_cast<CGDirectDisplayID>(displayID));
    if (mode == nil) {
        return NO;
    }

    const size_t width = std::max(static_cast<size_t>(CGDisplayModeGetPixelWidth(mode)), static_cast<size_t>(1));
    const size_t height = std::max(static_cast<size_t>(CGDisplayModeGetPixelHeight(mode)), static_cast<size_t>(1));
    CFRelease(mode);

    dispatch_queue_t queue = dispatch_queue_create("com.skyline23.MacDisplayKit.cgdisplaystream.probe", DISPATCH_QUEUE_SERIAL);
    CGDisplayStreamRef stream = CGDisplayStreamCreateWithDispatchQueue(
        static_cast<CGDirectDisplayID>(displayID),
        width,
        height,
        static_cast<int32_t>(kCVPixelFormatType_32BGRA),
        nil,
        queue,
        ^(__unused CGDisplayStreamFrameStatus status,
          __unused uint64_t displayTime,
          __unused IOSurfaceRef frameSurface,
          __unused CGDisplayStreamUpdateRef updateRef) {
        }
    );

    if (stream == nil) {
        return NO;
    }

    CFRelease(stream);
    return YES;
}

static void *MDKLookupCaptureSymbolInImage(const char *imagePath, const char *symbolName) {
    void *handle = dlopen(imagePath, RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
        handle = RTLD_DEFAULT;
    }

    return dlsym(handle, symbolName);
}

static void MDKEnsureCaptureImageLoaded(const char *imagePath) {
    dlopen(imagePath, RTLD_NOW | RTLD_GLOBAL);
}

static void *MDKLookupCaptureSymbol(const char *symbolName) {
    return MDKLookupCaptureSymbolInImage(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        symbolName
    );
}

static void *MDKLookupScreenCaptureKitSymbol(const char *symbolName) {
    return MDKLookupCaptureSymbolInImage(
        "/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit",
        symbolName
    );
}

static void *MDKLookupCMCaptureSymbol(const char *symbolName) {
    return MDKLookupCaptureSymbolInImage(
        "/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture",
        symbolName
    );
}

static void MDKAppendFilteredMethodNamesForClassToSet(Class cls, NSMutableSet<NSString *> *names) {
    if (cls == Nil) {
        return;
    }

    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"queue",
            @"remote",
            @"sample",
            @"surface",
            @"capture",
            @"stream",
            @"frame",
            @"receive",
            @"video",
            @"audio",
        ];
    });

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int index = 0; index < methodCount; index += 1) {
        SEL selector = method_getName(methods[index]);
        if (selector == nullptr) {
            continue;
        }

        NSString *selectorName = [NSString stringWithUTF8String:sel_getName(selector)];
        NSString *lowercaseSelectorName = selectorName.lowercaseString;
        for (NSString *keyword in keywords) {
            if ([lowercaseSelectorName containsString:keyword]) {
                [names addObject:selectorName];
                break;
            }
        }
    }
    free(methods);
}

static NSArray<NSString *> *MDKFilteredMethodNamesForRuntimeClass(NSString *className) {
    if (className.length == 0) {
        return @[];
    }

    NSMutableSet<NSString *> *methodNames = [NSMutableSet set];
    Class cls = NSClassFromString(className);
    MDKAppendFilteredMethodNamesForClassToSet(cls, methodNames);
    if (cls != Nil) {
        MDKAppendFilteredMethodNamesForClassToSet(object_getClass(cls), methodNames);
    }

    return [methodNames.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static NSDictionary<NSString *, NSNumber *> *MDKRuntimeSymbolAvailabilityForNames(
    NSArray<NSString *> *symbolNames,
    BOOL useCMCapture
) {
    NSMutableDictionary<NSString *, NSNumber *> *availability = [NSMutableDictionary dictionaryWithCapacity:symbolNames.count];
    for (NSString *symbolName in symbolNames) {
        const char *cSymbolName = symbolName.UTF8String;
        void *symbol = useCMCapture ? MDKLookupCMCaptureSymbol(cSymbolName) : MDKLookupScreenCaptureKitSymbol(cSymbolName);
        availability[symbolName] = @(symbol != nullptr);
    }

    return availability;
}

static std::uint32_t MDKMainConnectionID(void) {
    using MDKMainConnectionIDFn = std::uint32_t (*)(void);
    static const auto symbol = reinterpret_cast<MDKMainConnectionIDFn>(
        MDKLookupCaptureSymbol("SLSMainConnectionID")
    );
    if (symbol == nullptr) {
        return 0;
    }

    return symbol();
}

BOOL MDKShimVideoPrivateDesktopCaptureAvailable(void) {
    return MDKLookupCaptureSymbol("CGSHWCaptureDesktop") != nullptr;
}

BOOL MDKShimVideoPrivateDisplayIOSurfaceCaptureAvailable(void) {
    return MDKLookupCaptureSymbol("CGSHWCaptureDisplayIntoIOSurface") != nullptr;
}

BOOL MDKShimVideoPrivateDisplayIOSurfaceCaptureWithOptionsAvailable(void) {
    return MDKLookupCaptureSymbol("CGSHWCaptureDisplayIntoIOSurfaceWithOptions") != nullptr;
}

BOOL MDKShimVideoPrivateDisplayIOSurfaceProxyCaptureAvailable(void) {
    return MDKLookupScreenCaptureKitSymbol("SLSHWCaptureDisplayIntoIOSurfaceProxying") != nullptr;
}

BOOL MDKShimVideoPrivateDisplayStreamProxyAvailable(void) {
    return MDKLookupScreenCaptureKitSymbol("SLSDisplayStreamCreateProxying") != nullptr;
}

BOOL MDKShimVideoPrivateCaptureExtendedRangeOptionAvailable(void) {
    return MDKLookupCaptureSymbol("kSLSCaptureExtendedRange") != nullptr;
}

static mach_port_t MDKCreateProbePortWithMode(NSInteger portMode, NSError * _Nullable * _Nullable error);

static mach_port_t MDKCreateProbePortWithMode(NSInteger portMode, NSError * _Nullable * _Nullable error) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t status = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (status != KERN_SUCCESS) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:static_cast<NSInteger>(status)
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Failed to allocate a mach receive right for the private display stream probe."
                                     }];
        }
        return MACH_PORT_NULL;
    }

    if (portMode == 0) {
        status = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
        if (status != KERN_SUCCESS) {
            mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
            if (error != nullptr) {
                *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                             code:static_cast<NSInteger>(status)
                                         userInfo:@{
                                             NSLocalizedDescriptionKey: @"Failed to install a send right for the private display stream probe port."
                                         }];
            }
            return MACH_PORT_NULL;
        }
    }

    return port;
}

static void MDKDisposeProbePort(mach_port_t port) {
    if (port == MACH_PORT_NULL) {
        return;
    }

    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, -1);
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
}

static NSDictionary<NSString *, id> *MDKCreateMachPortSnapshot(mach_port_t port) {
    mach_port_status_t receiveStatus = {};
    mach_msg_type_number_t receiveStatusCount = MACH_PORT_RECEIVE_STATUS_COUNT;
    const kern_return_t status = mach_port_get_attributes(
        mach_task_self(),
        port,
        MACH_PORT_RECEIVE_STATUS,
        reinterpret_cast<mach_port_info_t>(&receiveStatus),
        &receiveStatusCount
    );

    mach_port_type_t portType = 0;
    const kern_return_t typeStatus = mach_port_type(mach_task_self(), port, &portType);

    return @{
        @"portStatus": @(status),
        @"portTypeStatus": @(typeStatus),
        @"portType": @(portType),
        @"portMessageCount": status == KERN_SUCCESS ? @(receiveStatus.mps_msgcount) : @0,
        @"portQueueLimit": status == KERN_SUCCESS ? @(receiveStatus.mps_qlimit) : @0,
        @"portSequenceNumber": status == KERN_SUCCESS ? @(receiveStatus.mps_seqno) : @0,
        @"portMessagesWaiting": @((status == KERN_SUCCESS) && (receiveStatus.mps_msgcount > 0)),
    };
}

@interface MDKShimStreamOutputCollector : NSObject
@end

static NSMutableDictionary<NSString *, id> *MDKActiveSCKTraceState = nil;
static NSObject *MDKActiveSCKTraceLock = nil;
static NSMutableArray<id> *MDKActiveSCKRemoteQueues = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *MDKActiveSCKRemoteQueueEntries = nil;
static dispatch_queue_t MDKActiveSCKScreenSampleHandlerQueue = nil;
static void *MDKActiveSCRemoteQueueWrapper = nullptr;
static dispatch_queue_t MDKActiveSCRemoteQueueWrapperQueue = nil;
static dispatch_semaphore_t MDKActiveSCRemoteQueueWrapperSemaphore = nil;
static NSMutableDictionary<NSString *, id> *MDKActiveSCRemoteQueueWrapperState = nil;
static void *MDKActiveFigRemoteQueueReceiver = nullptr;
static dispatch_queue_t MDKActiveFigRemoteQueueReceiverQueue = nil;
static dispatch_semaphore_t MDKActiveFigRemoteQueueReceiverSemaphore = nil;
static NSMutableDictionary<NSString *, id> *MDKActiveFigRemoteQueueReceiverState = nil;
static BOOL MDKActiveSCKAllowPrivateQueueProbes = NO;

struct MDKFigRemoteQueueMessage {
    const void *payloadBlock;
    IOSurfaceRef surface;
    int messageType;
};

static void MDKRecordSCKTraceEvent(NSString *kind, NSDictionary<NSString *, id> *payload);
static NSDictionary<NSString *, id> *MDKSummarizeSampleBuffer(CMSampleBufferRef sampleBuffer);
static NSDictionary<NSString *, id> *MDKSummarizeIOSurface(IOSurfaceRef surface);
static NSDictionary<NSString *, id> *MDKCopySCStreamInternalState(id stream);
static NSDictionary<NSString *, id> *MDKSummarizeXPCObject(xpc_object_t object);
static NSDictionary<NSString *, id> *MDKSummarizeSampleCarrier(id sample);
static NSDictionary<NSString *, id> *MDKSummarizePointerValue(const void *pointer);
static NSString *MDKCopyBlockSignatureString(id block);
static NSDictionary<NSString *, id> *MDKCopySCKRemoteQueueEntrySummaryForType(unsigned char queueType);
static NSDictionary<NSString *, id> *MDKCopySCKRemoteQueueEntryForType(unsigned char queueType);
static void MDKUpdateSCKSampleBufferDiagnostics(CMSampleBufferRef sampleBuffer);
static BOOL MDKPrimeSCRemoteQueueWrapperIfPossible(id remoteQueue);
static NSString *MDKBucketMilliseconds(double milliseconds);
static void MDKIncrementMutableHistogram(NSMutableDictionary<NSString *, NSNumber *> *histogram, NSString *bucket);
static NSString *MDKClassifyCadenceHistogram(NSDictionary<NSString *, NSNumber *> *histogram, NSUInteger deltaCount);

@implementation MDKShimStreamOutputCollector

- (void)stream:(id)stream
didOutputSampleBuffer:(id)sampleBuffer
        ofType:(NSInteger)type {
    if (sampleBuffer == nil || ![sampleBuffer isKindOfClass:[NSObject class]]) {
        return;
    }

    MDKUpdateSCKSampleBufferDiagnostics((__bridge CMSampleBufferRef) sampleBuffer);

    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger sampleBufferEventCount = [MDKActiveSCKTraceState[@"sampleBufferEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"sampleBufferEventCount"] = @(sampleBufferEventCount);
            shouldRecord = sampleBufferEventCount <= 4;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(
        @"stream-output-sample-buffer",
        @{
            @"type": @(type),
            @"sampleBuffer": MDKSummarizeSampleBuffer((__bridge CMSampleBufferRef) sampleBuffer),
            @"streamState": MDKCopySCStreamInternalState(stream),
        }
    );
}

@end

using MDKProxyCoreGraphicsFn = void (*)(id, SEL, unsigned char, id, id, id);
using MDKStartRemoteQueueFn = void (*)(id, SEL, id, id);
using MDKStartCaptureProxyFn = void (*)(id, SEL, id, id, id, id, id, id, id);
using MDKFetchDisplayFn = void (*)(id, SEL, unsigned int, id);
using MDKUpdateStreamConfigurationFn = void (*)(id, SEL, id, id, id, id, id);
using MDKUpdateStreamContentFilterFn = void (*)(id, SEL, id, id, id, id, id, id);
using MDKStreamDidStartFn = void (*)(id, SEL, id, id);
using MDKStreamOutputEffectDidStartFn = void (*)(id, SEL, BOOL, id);
using MDKStartRemoteReceiveQueueConsumerFn = void (*)(id, SEL, id);
using MDKCollectStreamDataFn = void (*)(id, SEL);
using MDKManagerStartRemoteQueueFn = void (*)(id, SEL, id, id);
using MDKManagerUpdateClientOutputTypeFn = void (*)(id, SEL, id, NSUInteger);
using MDKManagerStreamUpdateWithFilterFn = void (*)(id, SEL, id, id);
using MDKManagerStreamOutputEffectDidStartFn = void (*)(id, SEL, BOOL, id);
using MDKRPIOSurfaceSetFn = void (*)(id, SEL, IOSurfaceRef);
using MDKRPIOSurfaceGetFn = IOSurfaceRef (*)(id, SEL);
using MDKCaptureHandlerWithSampleFn = void (*)(id, SEL, id, id);
using MDKCAContentStreamProduceSurfaceFn = void (*)(id, SEL, unsigned int, const void *);
using MDKCAContentStreamReleaseSurfaceFn = BOOL (*)(id, SEL, IOSurfaceRef, NSError **);
using MDKCAContentStreamReleaseSurfaceWithIDFn = BOOL (*)(id, SEL, unsigned int, NSError **);
using MDKIOSurfaceRemoteAddSurfaceFn = void (*)(id, SEL, void *, void *, std::uint64_t, id);
using MDKIOSurfaceRemoteSetSurfaceStatesFn = void (*)(id, SEL, id);
using MDKIOSurfaceRemoteRemoveSurfaceFn = BOOL (*)(id, SEL, unsigned int);
using MDKFrameReceiverInitFn = id (*)(id, SEL, id, id);
using MDKBWRenderSampleBufferFn = void (*)(id, SEL, CMSampleBufferRef, id);
using MDKBWHandleDroppedSampleFn = void (*)(id, SEL, id, id);
using MDKFigSetSinkNodeFn = void (*)(id, SEL, id);
using MDKSCRemoteQueueSetRemoteQueueFn = void (*)(id, SEL, id);
using MDKSCRemoteQueueSetQueueTypeFn = void (*)(id, SEL, unsigned char);

static MDKProxyCoreGraphicsFn MDKOriginalProxyCoreGraphics = nullptr;
static MDKStartRemoteQueueFn MDKOriginalStartRemoteQueue = nullptr;
static MDKStartCaptureProxyFn MDKOriginalStartCaptureProxy = nullptr;
static MDKFetchDisplayFn MDKOriginalFetchDisplay = nullptr;
static MDKUpdateStreamConfigurationFn MDKOriginalUpdateStreamConfiguration = nullptr;
static MDKUpdateStreamContentFilterFn MDKOriginalUpdateStreamContentFilter = nullptr;
static MDKStreamDidStartFn MDKOriginalStreamDidStart = nullptr;
static MDKStreamOutputEffectDidStartFn MDKOriginalStreamOutputEffectDidStart = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteReceiveQueue = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteVideoReceiveQueue = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteAudioReceiveQueue = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteMicrophoneReceiveQueue = nullptr;
static MDKCollectStreamDataFn MDKOriginalCollectStreamData = nullptr;
static MDKManagerStartRemoteQueueFn MDKOriginalManagerStartRemoteQueue = nullptr;
static MDKManagerUpdateClientOutputTypeFn MDKOriginalManagerUpdateClientOutputType = nullptr;
static MDKManagerStreamUpdateWithFilterFn MDKOriginalManagerStreamUpdateWithFilter = nullptr;
static MDKManagerStreamUpdateWithFilterFn MDKOriginalManagerStreamDidRequestUpdateFilter = nullptr;
static MDKManagerStreamOutputEffectDidStartFn MDKOriginalManagerStreamOutputEffectDidStart = nullptr;
static MDKRPIOSurfaceSetFn MDKOriginalRPIOSurfaceSet = nullptr;
static MDKRPIOSurfaceGetFn MDKOriginalRPIOSurfaceGet = nullptr;
static MDKCaptureHandlerWithSampleFn MDKOriginalDaemonCaptureHandlerWithSample = nullptr;
static MDKCaptureHandlerWithSampleFn MDKOriginalScreenRecorderCaptureHandlerWithSample = nullptr;
static MDKCAContentStreamProduceSurfaceFn MDKOriginalCAContentStreamProduceSurface = nullptr;
static MDKCAContentStreamReleaseSurfaceFn MDKOriginalCAContentStreamReleaseSurface = nullptr;
static MDKCAContentStreamReleaseSurfaceWithIDFn MDKOriginalCAContentStreamReleaseSurfaceWithID = nullptr;
static MDKIOSurfaceRemoteAddSurfaceFn MDKOriginalIOSurfaceRemoteAddSurface = nullptr;
static MDKIOSurfaceRemoteSetSurfaceStatesFn MDKOriginalIOSurfaceRemoteSetSurfaceStates = nullptr;
static MDKIOSurfaceRemoteRemoveSurfaceFn MDKOriginalIOSurfaceRemoteRemoveSurface = nullptr;
static MDKFrameReceiverInitFn MDKOriginalFrameReceiverInit = nullptr;
static MDKBWRenderSampleBufferFn MDKOriginalBWRenderSampleBuffer = nullptr;
static MDKBWHandleDroppedSampleFn MDKOriginalBWHandleDroppedSample = nullptr;
static MDKFigSetSinkNodeFn MDKOriginalFigSetSinkNode = nullptr;
static MDKSCRemoteQueueSetRemoteQueueFn MDKOriginalSCRemoteQueueSetRemoteQueue = nullptr;
static MDKSCRemoteQueueSetQueueTypeFn MDKOriginalSCRemoteQueueSetQueueType = nullptr;

static uint64_t MDKCurrentTraceTimestampNanos(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static uint64_t MDKCurrentTraceThreadID(void) {
    uint64_t threadID = 0;
    pthread_threadid_np(nullptr, &threadID);
    return threadID;
}

static NSString *MDKCurrentTraceQueueLabel(void) {
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (label == nullptr || label[0] == '\0') {
        return @"";
    }

    return [NSString stringWithUTF8String:label] ?: @"";
}

static id MDKPerformObjectGetter(id object, SEL selector) {
    if (object == nil || selector == nullptr || ![object respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL)) objc_msgSend)(object, selector);
}

static NSNumber * _Nullable MDKPerformUnsignedCharGetter(id object, SEL selector) {
    if (object == nil || selector == nullptr || ![object respondsToSelector:selector]) {
        return nil;
    }

    const unsigned char value = ((unsigned char (*)(id, SEL)) objc_msgSend)(object, selector);
    return @(value);
}

static NSString *MDKStringFromXPCType(xpc_type_t type) {
    if (type == XPC_TYPE_DICTIONARY) {
        return @"dictionary";
    }
    if (type == XPC_TYPE_UINT64) {
        return @"uint64";
    }
    if (type == XPC_TYPE_INT64) {
        return @"int64";
    }
    if (type == XPC_TYPE_BOOL) {
        return @"bool";
    }
    if (type == XPC_TYPE_STRING) {
        return @"string";
    }
    if (type == XPC_TYPE_SHMEM) {
        return @"shmem";
    }
    if (type == XPC_TYPE_FD) {
        return @"fd";
    }
    if (type == XPC_TYPE_ARRAY) {
        return @"array";
    }
    if (type == XPC_TYPE_DATA) {
        return @"data";
    }
    if (type == XPC_TYPE_ERROR) {
        return @"error";
    }
    if (type == XPC_TYPE_NULL) {
        return @"null";
    }
    return @"unknown";
}

static NSDictionary<NSString *, id> *MDKSummarizeXPCValue(xpc_object_t value) {
    if (value == nullptr) {
        return @{
            @"present": @NO
        };
    }

    xpc_type_t type = xpc_get_type(value);
    NSMutableDictionary<NSString *, id> *summary = [@{
        @"present": @YES,
        @"xpcType": MDKStringFromXPCType(type),
    } mutableCopy];

    if (type == XPC_TYPE_UINT64) {
        summary[@"value"] = @(xpc_uint64_get_value(value));
    } else if (type == XPC_TYPE_INT64) {
        summary[@"value"] = @(xpc_int64_get_value(value));
    } else if (type == XPC_TYPE_BOOL) {
        summary[@"value"] = @(xpc_bool_get_value(value));
    } else if (type == XPC_TYPE_STRING) {
        const char *raw = xpc_string_get_string_ptr(value);
        summary[@"value"] = raw != nullptr ? [NSString stringWithUTF8String:raw] ?: @"" : @"";
    } else if (type == XPC_TYPE_SHMEM) {
        void *mappedRegion = nullptr;
        size_t mappedSize = xpc_shmem_map(value, &mappedRegion);
        summary[@"mapped"] = @(mappedRegion != nullptr);
        summary[@"size"] = @(mappedSize);
    } else if (type == XPC_TYPE_ARRAY) {
        summary[@"count"] = @(xpc_array_get_count(value));
    }

    const char *description = xpc_copy_description(value);
    if (description != nullptr) {
        summary[@"description"] = [NSString stringWithUTF8String:description] ?: @"";
        free(const_cast<char *>(description));
    }

    return summary;
}

static NSDictionary<NSString *, id> *MDKSummarizeXPCObject(xpc_object_t object) {
    if (object == nullptr) {
        return @{
            @"present": @NO
        };
    }

    xpc_type_t type = xpc_get_type(object);
    NSMutableDictionary<NSString *, id> *summary = [@{
        @"present": @YES,
        @"xpcType": MDKStringFromXPCType(type),
    } mutableCopy];

    if (type == XPC_TYPE_DICTIONARY) {
        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        NSMutableDictionary<NSString *, id> *selectedValues = [NSMutableDictionary dictionary];
        xpc_dictionary_apply(object, ^bool(const char *key, xpc_object_t value) {
            if (key == nullptr) {
                return true;
            }

            NSString *nsKey = [NSString stringWithUTF8String:key] ?: @"";
            [keys addObject:nsKey];
            if ([nsKey isEqualToString:@"QueueData"] ||
                [nsKey isEqualToString:@"SharedRegion"] ||
                [nsKey isEqualToString:@"QueueOffset"] ||
                [nsKey isEqualToString:@"RecvFd"] ||
                [nsKey isEqualToString:@"IOSurfaceReceiver"] ||
                [nsKey isEqualToString:@"SendFd"]) {
                selectedValues[nsKey] = MDKSummarizeXPCValue(value);
            }
            return true;
        });
        summary[@"xpcKeys"] = [keys sortedArrayUsingSelector:@selector(compare:)];
        if (selectedValues.count > 0) {
            summary[@"xpcSelectedValues"] = selectedValues;
        }
    } else {
        [summary addEntriesFromDictionary:MDKSummarizeXPCValue(object)];
    }

    const char *description = xpc_copy_description(object);
    if (description != nullptr) {
        summary[@"description"] = [NSString stringWithUTF8String:description] ?: @"";
        free(const_cast<char *>(description));
    }

    return summary;
}

static NSArray<NSString *> * _Nullable MDKSortedDictionaryKeys(id object) {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSArray<NSString *> *keys = [(NSDictionary *) object allKeys];
    return [keys sortedArrayUsingSelector:@selector(compare:)];
}

static NSDictionary<NSString *, id> *MDKSummarizeObject(id object) {
    if (object == nil) {
        return @{
            @"present": @NO
        };
    }

    NSMutableDictionary<NSString *, id> *summary = [NSMutableDictionary dictionary];
    summary[@"present"] = @YES;
    summary[@"className"] = NSStringFromClass([object class]) ?: @"<unknown>";
    NSString *className = summary[@"className"];

    if ([className hasPrefix:@"OS_xpc_"]) {
        [summary addEntriesFromDictionary:MDKSummarizeXPCObject((xpc_object_t)object)];
    } else if ([object isKindOfClass:[NSDictionary class]]) {
        summary[@"keys"] = MDKSortedDictionaryKeys(object) ?: @[];
    } else if ([object isKindOfClass:[NSArray class]]) {
        summary[@"count"] = @([(NSArray *) object count]);
    } else if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]]) {
        summary[@"value"] = object;
    }

    id serialized = MDKPerformObjectGetter(object, sel_registerName("serialize"));
    NSArray<NSString *> *serializedKeys = MDKSortedDictionaryKeys(serialized);
    if (serialized != nil) {
        summary[@"serializedClassName"] = NSStringFromClass([serialized class]) ?: @"<unknown>";
        if (serializedKeys != nil) {
            summary[@"serializedKeys"] = serializedKeys;
        }
    }

    id filterID = MDKPerformObjectGetter(object, sel_registerName("filterID"));
    if ([filterID isKindOfClass:[NSString class]]) {
        summary[@"filterID"] = filterID;
    }

    id streamID = MDKPerformObjectGetter(object, sel_registerName("streamID"));
    if ([streamID isKindOfClass:[NSString class]]) {
        summary[@"streamID"] = streamID;
    }

    id displayInfo = MDKPerformObjectGetter(object, sel_registerName("displayInfo"));
    NSArray<NSString *> *displayInfoKeys = MDKSortedDictionaryKeys(displayInfo);
    if (displayInfoKeys != nil) {
        summary[@"displayInfoKeys"] = displayInfoKeys;
    }

    NSNumber *queueType = MDKPerformUnsignedCharGetter(object, sel_registerName("queueType"));
    if (queueType != nil) {
        summary[@"queueType"] = queueType;
    }

    id remoteQueue = MDKPerformObjectGetter(object, sel_registerName("remoteQueue"));
    if (remoteQueue != nil) {
        summary[@"remoteQueueClassName"] = NSStringFromClass([remoteQueue class]) ?: @"<unknown>";
        summary[@"remoteQueueDescription"] = [remoteQueue description] ?: @"";
        if ([summary[@"remoteQueueClassName"] hasPrefix:@"OS_xpc_"]) {
            summary[@"remoteQueueStructured"] = MDKSummarizeXPCObject((xpc_object_t) remoteQueue);
        }
        const char *xpcDescription = xpc_copy_description((xpc_object_t) remoteQueue);
        if (xpcDescription != nullptr) {
            summary[@"remoteQueueXPCDescription"] = [NSString stringWithUTF8String:xpcDescription] ?: @"";
            free(const_cast<char *>(xpcDescription));
        }
    }

    id machPort = MDKPerformObjectGetter(object, sel_registerName("machPort"));
    if (machPort != nil) {
        summary[@"wrappedMachPortClassName"] = NSStringFromClass([machPort class]) ?: @"<unknown>";
        summary[@"wrappedMachPortDescription"] = [machPort description] ?: @"";
    }

    return summary;
}

static NSValue * _Nullable MDKCopyRawPointerIvar(id object, const char *name) {
    if (object == nil || name == nullptr) {
        return nil;
    }

    Ivar ivar = class_getInstanceVariable([object class], name);
    if (ivar == nullptr) {
        return nil;
    }

    const ptrdiff_t offset = ivar_getOffset(ivar);
    void *value = nullptr;
    const uint8_t *base = reinterpret_cast<const uint8_t *>((__bridge const void *)object);
    memcpy(&value, base + offset, sizeof(value));
    if (value == nullptr) {
        return nil;
    }

    return [NSValue valueWithPointer:value];
}

static id MDKCopyObjectIvar(id object, const char *name) {
    if (object == nil || name == nullptr) {
        return nil;
    }

    Ivar ivar = class_getInstanceVariable([object class], name);
    if (ivar == nullptr) {
        return nil;
    }

    const char *encoding = ivar_getTypeEncoding(ivar);
    if (encoding == nullptr || encoding[0] != '@') {
        return nil;
    }

    return object_getIvar(object, ivar);
}

static NSDictionary<NSString *, id> *MDKDescribeRemoteQueueWrapperSlot(
    const void *slotValue,
    size_t offset,
    BOOL inspectForBlockSignature
) {
    NSMutableDictionary<NSString *, id> *summary = [@{
        @"offset": @(offset),
    } mutableCopy];
    if (slotValue == nullptr) {
        summary[@"present"] = @NO;
        return summary;
    }

    summary[@"present"] = @YES;
    summary[@"pointer"] = [NSString stringWithFormat:@"%p", slotValue];

    const size_t allocationSize = malloc_size(const_cast<void *>(slotValue));
    if (allocationSize > 0) {
        summary[@"mallocSize"] = @(allocationSize);
    }

    if (inspectForBlockSignature && allocationSize > 0) {
        NSString *signature = MDKCopyBlockSignatureString((__bridge id) slotValue);
        if (signature != nil) {
            summary[@"blockSignature"] = signature;
        }
    }

    return summary;
}

static NSDictionary<NSString *, id> *MDKDescribeRemoteQueueWrapper(const void *wrapperPointer) {
    if (wrapperPointer == nullptr) {
        return @{
            @"present": @NO
        };
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *slots = [NSMutableArray array];
    const uint8_t *base = reinterpret_cast<const uint8_t *>(wrapperPointer);
    for (size_t offset = 0; offset <= 0x28; offset += sizeof(void *)) {
        void *slotValue = nullptr;
        memcpy(&slotValue, base + offset, sizeof(slotValue));
        const BOOL inspectForBlockSignature = (offset == 0x28);
        [slots addObject:MDKDescribeRemoteQueueWrapperSlot(slotValue, offset, inspectForBlockSignature)];
    }

    return @{
        @"present": @YES,
        @"pointer": [NSString stringWithFormat:@"%p", wrapperPointer],
        @"slots": slots,
    };
}

static NSDictionary<NSString *, id> *MDKSummarizeSampleBuffer(CMSampleBufferRef sampleBuffer) {
    if (sampleBuffer == nullptr) {
        return @{
            @"present": @NO
        };
    }

    NSMutableDictionary<NSString *, id> *summary = [@{
        @"present": @YES,
        @"numSamples": @(CMSampleBufferGetNumSamples(sampleBuffer)),
        @"isValid": @(CMSampleBufferIsValid(sampleBuffer)),
    } mutableCopy];

    const CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_NUMERIC(presentationTimeStamp)) {
        summary[@"presentationTimeSeconds"] = @(CMTimeGetSeconds(presentationTimeStamp));
    }

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer != nullptr && CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID()) {
        CVPixelBufferRef pixelBuffer = reinterpret_cast<CVPixelBufferRef>(imageBuffer);
        summary[@"pixelWidth"] = @(CVPixelBufferGetWidth(pixelBuffer));
        summary[@"pixelHeight"] = @(CVPixelBufferGetHeight(pixelBuffer));
        summary[@"pixelFormat"] = @(CVPixelBufferGetPixelFormatType(pixelBuffer));
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
        summary[@"hasIOSurface"] = @(surface != nullptr);
        if (surface != nullptr) {
            summary[@"surface"] = MDKSummarizeIOSurface(surface);
        }
    } else {
        summary[@"hasIOSurface"] = @NO;
    }

    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (formatDescription != nullptr) {
        summary[@"mediaSubType"] = @(CMFormatDescriptionGetMediaSubType(formatDescription));
    }

    return summary;
}

static NSDictionary<NSString *, id> *MDKSummarizeSampleCarrier(id sample) {
    if (sample == nil) {
        return @{
            @"present": @NO
        };
    }

    CFTypeRef cfSample = (__bridge CFTypeRef)sample;
    if (CFGetTypeID(cfSample) == CMSampleBufferGetTypeID()) {
        return MDKSummarizeSampleBuffer((__bridge CMSampleBufferRef)sample);
    }

    return MDKSummarizeObject(sample);
}

static NSDictionary<NSString *, id> *MDKSummarizePointerValue(const void *pointer) {
    if (pointer == nullptr) {
        return @{
            @"present": @NO
        };
    }

    return @{
        @"present": @YES,
        @"pointer": [NSString stringWithFormat:@"%p", pointer],
    };
}

static NSString *MDKCopyBlockSignatureString(id block) {
    if (block == nil) {
        return nil;
    }

    const auto *literal = (__bridge const MDKBlockLiteral *) block;
    if (literal == nullptr || literal->descriptor == nullptr) {
        return nil;
    }

    if ((literal->flags & MDKBlockHasSignature) == 0) {
        return nil;
    }

    const uint8_t *descriptor = reinterpret_cast<const uint8_t *>(literal->descriptor);
    descriptor += sizeof(unsigned long) * 2;
    if ((literal->flags & MDKBlockHasCopyDispose) != 0) {
        descriptor += sizeof(void (*)(void *, const void *));
        descriptor += sizeof(void (*)(const void *));
    }

    const char *signature = *reinterpret_cast<const char * const *>(descriptor);
    if (signature == nullptr) {
        return nil;
    }

    return [NSString stringWithUTF8String:signature];
}

static NSString *MDKPointerKey(id object) {
    if (object == nil) {
        return nil;
    }

    return [NSString stringWithFormat:@"%p", (__bridge const void *) object];
}

static NSDictionary<NSString *, id> *MDKCopySCRemoteQueueContainerState(id container) {
    if (container == nil) {
        return @{
            @"present": @NO
        };
    }

    NSMutableDictionary<NSString *, id> *summary = [@{
        @"present": @YES,
        @"container": MDKSummarizeObject(container),
    } mutableCopy];

    NSDictionary<NSString *, NSString *> *pointerIvarNames = @{
        @"videoReceiveQueuePointer": @"_videoReceiveQueue",
        @"audioReceiveQueuePointer": @"_audioReceiveQueue",
        @"microphoneReceiveQueuePointer": @"_microphoneReceiveQueue",
    };
    [pointerIvarNames enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *ivarName, __unused BOOL *stop) {
        NSValue *value = MDKCopyRawPointerIvar(container, ivarName.UTF8String);
        summary[key] = value != nil ? [NSString stringWithFormat:@"%p", value.pointerValue] : @"";
        if (value != nil) {
            NSString *wrapperKey = [key stringByReplacingOccurrencesOfString:@"Pointer" withString:@"Wrapper"];
            summary[wrapperKey] = MDKDescribeRemoteQueueWrapper(value.pointerValue);
        }
    }];

    NSDictionary<NSString *, NSString *> *objectIvarNames = @{
        @"videoReceiveQueue": @"_videoReceiveQueue",
        @"audioReceiveQueue": @"_audioReceiveQueue",
        @"microphoneReceiveQueue": @"_microphoneReceiveQueue",
    };
    [objectIvarNames enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *ivarName, __unused BOOL *stop) {
        id value = MDKCopyObjectIvar(container, ivarName.UTF8String);
        if (value != nil) {
            summary[key] = MDKSummarizeObject(value);
        }
    }];

    return summary;
}

static NSDictionary<NSString *, id> *MDKCopySCKRemoteQueueEntrySummaryForType(unsigned char queueType) {
    NSDictionary<NSString *, id> *entry = MDKCopySCKRemoteQueueEntryForType(queueType);
    if (entry == nil) {
        return @{
            @"present": @NO,
            @"queueType": @(queueType),
        };
    }

    NSMutableDictionary<NSString *, id> *summary = [NSMutableDictionary dictionary];
    summary[@"queueType"] = @(queueType);
    if (entry[@"queueObject"] != nil) {
        summary[@"queueObject"] = MDKSummarizeObject(entry[@"queueObject"]);
    }
    if (entry[@"remoteQueue"] != nil) {
        summary[@"remoteQueue"] = MDKSummarizeObject(entry[@"remoteQueue"]);
    }
    return summary;
}

static NSDictionary<NSString *, id> *MDKCopySCKRemoteQueueEntryForType(unsigned char queueType) {
    @synchronized(MDKActiveSCKTraceLock) {
        for (NSMutableDictionary<NSString *, id> *entry in MDKActiveSCKRemoteQueueEntries.allValues) {
            NSNumber *entryQueueType = entry[@"queueType"];
            if (entryQueueType != nil && entryQueueType.unsignedCharValue == queueType) {
                return [entry copy];
            }
        }
    }

    return nil;
}

static NSDictionary<NSString *, id> *MDKCopySCStreamInternalState(id stream) {
    if (stream == nil) {
        return @{
            @"present": @NO
        };
    }

    NSMutableDictionary<NSString *, id> *summary = [@{
        @"present": @YES,
        @"stream": MDKSummarizeObject(stream),
    } mutableCopy];

    id screenStreamOutput = MDKCopyObjectIvar(stream, "_screenStreamOutput");
    if (screenStreamOutput != nil) {
        summary[@"screenStreamOutput"] = MDKSummarizeObject(screenStreamOutput);
    }

    id sharingSession = MDKCopyObjectIvar(stream, "_sharingSession");
    if (sharingSession != nil) {
        summary[@"sharingSession"] = MDKSummarizeObject(sharingSession);
    }

    id streamManager = MDKCopyObjectIvar(stream, "_streamManager");
    if (streamManager != nil) {
        summary[@"streamManager"] = MDKSummarizeObject(streamManager);
        summary[@"streamManagerState"] = MDKCopySCRemoteQueueContainerState(streamManager);
    }

    dispatch_queue_t sampleHandlerQueue = reinterpret_cast<dispatch_queue_t>(MDKCopyObjectIvar(stream, "_screenSampleHandlerQueue"));
    if (sampleHandlerQueue != nullptr) {
        summary[@"screenSampleHandlerQueueLabel"] =
            [NSString stringWithUTF8String:dispatch_queue_get_label(sampleHandlerQueue)] ?: @"";
    }

    [summary addEntriesFromDictionary:MDKCopySCRemoteQueueContainerState(stream)];
    summary[@"videoQueueEntry"] = MDKCopySCKRemoteQueueEntrySummaryForType(1);
    summary[@"audioQueueEntry"] = MDKCopySCKRemoteQueueEntrySummaryForType(0);
    summary[@"microphoneQueueEntry"] = MDKCopySCKRemoteQueueEntrySummaryForType(2);

    return summary;
}

static void MDKResetSCKTraceState(NSUInteger displayID, NSTimeInterval timeout) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        MDKActiveSCKTraceLock = [[NSObject alloc] init];
    });

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKTraceState = [@{
            @"displayID": @(displayID),
            @"timeout": @(timeout),
            @"events": [NSMutableArray array],
            @"notes": [NSMutableArray array],
            @"sawStartCaptureProxy": @NO,
            @"sawStartRemoteQueue": @NO,
            @"sawProxyCoreGraphics": @NO,
            @"startCaptureCompletionObserved": @NO,
            @"startCaptureCompletionSucceeded": @NO,
            @"collectStreamDataCallCount": @0,
            @"sampleBufferEventCount": @0,
            @"sampleBufferArrivalDeltaCount": @0,
            @"sampleBufferArrivalDeltaHistogram": [NSMutableDictionary dictionary],
            @"sampleBufferPresentationDeltaCount": @0,
            @"sampleBufferPresentationDeltaHistogram": [NSMutableDictionary dictionary],
            @"sampleBufferConsecutiveSurfaceReuseCount": @0,
            @"sampleBufferSurfaceUseCountHistogram": [NSMutableDictionary dictionary],
            @"sampleBufferSurfaceUseCountMax": @0,
            @"sampleBufferUniqueSurfacePointers": [NSMutableSet set],
            @"sampleBufferUniqueSurfaceCount": @0,
            @"rpIOSurfaceEventCount": @0,
            @"captureHandlerSampleEventCount": @0,
            @"contentStreamEventCount": @0,
            @"surfaceTransportEventCount": @0,
            @"frameReceiverEventCount": @0,
            @"remoteQueueSinkEventCount": @0,
            @"remoteQueueObjectEventCount": @0,
        } mutableCopy];
        MDKActiveSCKRemoteQueues = [NSMutableArray array];
        MDKActiveSCKRemoteQueueEntries = [NSMutableDictionary dictionary];
        MDKActiveSCKScreenSampleHandlerQueue = nil;
        MDKActiveSCRemoteQueueWrapper = nullptr;
        MDKActiveSCRemoteQueueWrapperQueue = nil;
        MDKActiveSCRemoteQueueWrapperSemaphore = nil;
        MDKActiveSCRemoteQueueWrapperState = nil;
        MDKActiveFigRemoteQueueReceiver = nullptr;
        MDKActiveFigRemoteQueueReceiverQueue = nil;
        MDKActiveFigRemoteQueueReceiverSemaphore = nil;
        MDKActiveFigRemoteQueueReceiverState = nil;
        MDKActiveSCKAllowPrivateQueueProbes = NO;
    }
}

static void MDKAppendSCKTraceNote(NSString *note) {
    if (note.length == 0) {
        return;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return;
        }

        NSMutableArray<NSString *> *notes = MDKActiveSCKTraceState[@"notes"];
        [notes addObject:note];
    }
}

static void MDKRecordSCKTraceEvent(NSString *kind, NSDictionary<NSString *, id> *payload) {
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return;
        }

        NSMutableArray *events = MDKActiveSCKTraceState[@"events"];
        NSMutableDictionary<NSString *, id> *event = [payload mutableCopy];
        event[@"kind"] = kind;
        event[@"index"] = @(events.count);
        event[@"timestampNanos"] = @(MDKCurrentTraceTimestampNanos());
        event[@"threadID"] = @(MDKCurrentTraceThreadID());
        NSString *queueLabel = MDKCurrentTraceQueueLabel();
        if (queueLabel.length > 0) {
            event[@"queueLabel"] = queueLabel;
        }
        [events addObject:event];
    }
}

static NSDictionary<NSString *, id> * _Nullable MDKCopySCKTraceStateSnapshot(void) {
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return nil;
        }

        return [MDKActiveSCKTraceState copy];
    }
}

static NSUInteger MDKCapturedSCKRemoteQueueCount(void) {
    @synchronized(MDKActiveSCKTraceLock) {
        return MDKActiveSCKRemoteQueues.count;
    }
}

static BOOL MDKPrimeSCRemoteQueueWrapperIfPossible(id remoteQueue) {
    using MDKSCRemoteQueueCreateReceiverQueueFn = BOOL (*)(xpc_object_t, id, dispatch_queue_t, void **);

    auto createSymbol = reinterpret_cast<MDKSCRemoteQueueCreateReceiverQueueFn>(
        MDKLookupScreenCaptureKitSymbol("SCRemoteQueue_CreateReceiverQueue")
    );

    NSMutableDictionary<NSString *, id> *state = [NSMutableDictionary dictionary];
    state[@"remoteQueue"] = MDKSummarizeObject(remoteQueue);
    state[@"createSymbolPresent"] = @(createSymbol != nullptr);
    state[@"createStatus"] = @NO;
    state[@"callbackCount"] = @0;
    state[@"callbackDeltaCount"] = @0;
    state[@"callbackDeltaHistogram"] = [NSMutableDictionary dictionary];
    state[@"wrapperCreated"] = @NO;

    if (createSymbol == nullptr || remoteQueue == nil) {
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveSCRemoteQueueWrapperState = state;
        }
        return NO;
    }

    dispatch_queue_t queue = nil;
    @synchronized(MDKActiveSCKTraceLock) {
        queue = MDKActiveSCKScreenSampleHandlerQueue;
    }
    if (queue == nil) {
        queue = dispatch_queue_create(
            "com.skyline23.MacDisplayKit.sc-remote-queue-wrapper",
            DISPATCH_QUEUE_SERIAL
        );
        state[@"usedPreferredSampleHandlerQueue"] = @NO;
    } else {
        state[@"usedPreferredSampleHandlerQueue"] = @YES;
        state[@"preferredSampleHandlerQueueLabel"] =
            [NSString stringWithUTF8String:dispatch_queue_get_label(queue)] ?: @"";
    }
    dispatch_semaphore_t callbackSemaphore = dispatch_semaphore_create(0);
    __block NSUInteger callbackCount = 0;
    void *receiverQueue = nullptr;
    BOOL createStatus = createSymbol(
        (xpc_object_t) remoteQueue,
        ^(int status, MDKFigRemoteQueueMessage *item, void *context) {
            @synchronized(MDKActiveSCKTraceLock) {
                if (MDKActiveSCRemoteQueueWrapperState != nil) {
                    callbackCount += 1;
                    MDKActiveSCRemoteQueueWrapperState[@"callbackCount"] = @(callbackCount);
                    MDKActiveSCRemoteQueueWrapperState[@"callbackStatus"] = @(status);
                    const uint64_t callbackTimestampNanos = MDKCurrentTraceTimestampNanos();
                    NSNumber *lastCallbackTimestampNanos = MDKActiveSCRemoteQueueWrapperState[@"lastCallbackTimestampNanos"];
                    if (lastCallbackTimestampNanos != nil) {
                        const double callbackDeltaMilliseconds =
                            static_cast<double>(callbackTimestampNanos - lastCallbackTimestampNanos.unsignedLongLongValue) / 1000000.0;
                        MDKIncrementMutableHistogram(
                            MDKActiveSCRemoteQueueWrapperState[@"callbackDeltaHistogram"],
                            MDKBucketMilliseconds(callbackDeltaMilliseconds)
                        );
                        MDKActiveSCRemoteQueueWrapperState[@"callbackDeltaCount"] =
                            @([MDKActiveSCRemoteQueueWrapperState[@"callbackDeltaCount"] unsignedIntegerValue] + 1);
                    }
                    MDKActiveSCRemoteQueueWrapperState[@"callbackTimestampNanos"] = @(callbackTimestampNanos);
                    MDKActiveSCRemoteQueueWrapperState[@"lastCallbackTimestampNanos"] = @(callbackTimestampNanos);
                    MDKActiveSCRemoteQueueWrapperState[@"callbackContext"] = MDKSummarizePointerValue(context);
                    if (item != nullptr) {
                        MDKActiveSCRemoteQueueWrapperState[@"callbackMessageType"] = @(item->messageType);
                        if (item->surface != nil) {
                            MDKActiveSCRemoteQueueWrapperState[@"callbackSurface"] = MDKSummarizeIOSurface(item->surface);
                        }
                    }
                }
            }
            dispatch_semaphore_signal(callbackSemaphore);
        },
        queue,
        &receiverQueue
    );
    state[@"createStatus"] = @(createStatus);
    state[@"wrapperCreated"] = @(receiverQueue != nullptr);

    if (createStatus && receiverQueue != nullptr) {
        MDKActiveSCRemoteQueueWrapper = receiverQueue;
        MDKActiveSCRemoteQueueWrapperQueue = queue;
        MDKActiveSCRemoteQueueWrapperSemaphore = callbackSemaphore;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCRemoteQueueWrapperState = state;
    }

    return createStatus && receiverQueue != nullptr;
}

static void MDKPrimeFigRemoteQueueReceiverIfPossible(id remoteQueue) {
    using MDKFigRemoteQueueReceiverCreateFromXPCObjectFn = int (*)(CFAllocatorRef, xpc_object_t, void **);
    using MDKFigRemoteQueueReceiverSetHandlerFn = void (*)(void *, dispatch_queue_t, id);

    auto createSymbol = reinterpret_cast<MDKFigRemoteQueueReceiverCreateFromXPCObjectFn>(
        MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverCreateFromXPCObject")
    );
    auto setHandlerSymbol = reinterpret_cast<MDKFigRemoteQueueReceiverSetHandlerFn>(
        MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverSetHandler")
    );

    NSMutableDictionary<NSString *, id> *state = [NSMutableDictionary dictionary];
    state[@"remoteQueue"] = MDKSummarizeObject(remoteQueue);
    state[@"createSymbolPresent"] = @(createSymbol != nullptr);
    state[@"setHandlerSymbolPresent"] = @(setHandlerSymbol != nullptr);

    if (createSymbol == nullptr || setHandlerSymbol == nullptr) {
        state[@"createStatus"] = @(-1);
        state[@"handlerStatus"] = @(-1);
        state[@"callbackCount"] = @0;
        state[@"receiverCreated"] = @NO;
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveFigRemoteQueueReceiverState = state;
        }
        return;
    }

    void *receiver = nullptr;
    const int createStatus = createSymbol(kCFAllocatorDefault, (xpc_object_t) remoteQueue, &receiver);
    state[@"createStatus"] = @(createStatus);
    state[@"receiverCreated"] = @(receiver != nullptr);
    state[@"callbackCount"] = @0;
    state[@"callbackDeltaCount"] = @0;
    state[@"callbackDeltaHistogram"] = [NSMutableDictionary dictionary];

    if (createStatus == 0 && receiver != nullptr) {
        dispatch_queue_t queue = dispatch_queue_create(
            "com.skyline23.MacDisplayKit.fig-remote-queue-receiver",
            DISPATCH_QUEUE_SERIAL
        );
        dispatch_semaphore_t callbackSemaphore = dispatch_semaphore_create(0);
        __block NSUInteger callbackCount = 0;
        setHandlerSymbol(receiver, queue, ^(int status, MDKFigRemoteQueueMessage *item, void *context) {
            @synchronized(MDKActiveSCKTraceLock) {
                if (MDKActiveFigRemoteQueueReceiverState != nil) {
                    callbackCount += 1;
                    MDKActiveFigRemoteQueueReceiverState[@"callbackCount"] = @(callbackCount);
                    MDKActiveFigRemoteQueueReceiverState[@"callbackStatus"] = @(status);
                    const uint64_t callbackTimestampNanos = MDKCurrentTraceTimestampNanos();
                    NSNumber *lastCallbackTimestampNanos = MDKActiveFigRemoteQueueReceiverState[@"lastCallbackTimestampNanos"];
                    if (lastCallbackTimestampNanos != nil) {
                        const double callbackDeltaMilliseconds =
                            static_cast<double>(callbackTimestampNanos - lastCallbackTimestampNanos.unsignedLongLongValue) / 1000000.0;
                        MDKIncrementMutableHistogram(
                            MDKActiveFigRemoteQueueReceiverState[@"callbackDeltaHistogram"],
                            MDKBucketMilliseconds(callbackDeltaMilliseconds)
                        );
                        MDKActiveFigRemoteQueueReceiverState[@"callbackDeltaCount"] =
                            @([MDKActiveFigRemoteQueueReceiverState[@"callbackDeltaCount"] unsignedIntegerValue] + 1);
                    }
                    MDKActiveFigRemoteQueueReceiverState[@"callbackTimestampNanos"] = @(callbackTimestampNanos);
                    MDKActiveFigRemoteQueueReceiverState[@"lastCallbackTimestampNanos"] = @(callbackTimestampNanos);
                    MDKActiveFigRemoteQueueReceiverState[@"callbackContext"] = MDKSummarizePointerValue(context);
                    if (item != nullptr) {
                        MDKActiveFigRemoteQueueReceiverState[@"callbackMessageType"] = @(item->messageType);
                        if (item->surface != nil) {
                            MDKActiveFigRemoteQueueReceiverState[@"callbackSurface"] = MDKSummarizeIOSurface(item->surface);
                        }
                    }
                }
            }
            dispatch_semaphore_signal(callbackSemaphore);
        });
        state[@"handlerStatus"] = @0;
        state[@"callbackStatus"] = @0;
        MDKActiveFigRemoteQueueReceiver = receiver;
        MDKActiveFigRemoteQueueReceiverQueue = queue;
        MDKActiveFigRemoteQueueReceiverSemaphore = callbackSemaphore;
    } else {
        state[@"handlerStatus"] = @(-1);
    }

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveFigRemoteQueueReceiverState = state;
    }
}

static NSString *MDKDescribeTraceValue(id value) {
    if (value == nil || value == [NSNull null]) {
        return @"<null>";
    }

    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
        return [value description];
    }

    if ([NSJSONSerialization isValidJSONObject:value]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
        if (data != nil) {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (text != nil) {
                return text;
            }
        }
    }

    return [value description] ?: @"<unknown>";
}

static NSString *MDKBucketMilliseconds(double milliseconds) {
    const double rounded = std::round(milliseconds * 10.0) / 10.0;
    return [NSString stringWithFormat:@"%.1fms", rounded];
}

static double MDKParseHistogramBucketMilliseconds(NSString *bucket) {
    if (![bucket isKindOfClass:[NSString class]] || ![bucket hasSuffix:@"ms"]) {
        return NAN;
    }

    NSString *numericPortion = [bucket substringToIndex:bucket.length - 2];
    return numericPortion.doubleValue;
}

static NSUInteger MDKHistogramCountInRange(
    NSDictionary<NSString *, NSNumber *> *histogram,
    double lowerInclusiveMilliseconds,
    double upperExclusiveMilliseconds
) {
    if (![histogram isKindOfClass:[NSDictionary class]]) {
        return 0;
    }

    NSUInteger total = 0;
    for (NSString *bucket in histogram) {
        NSNumber *count = histogram[bucket];
        const double bucketMilliseconds = MDKParseHistogramBucketMilliseconds(bucket);
        if (!std::isfinite(bucketMilliseconds)) {
            continue;
        }
        if (bucketMilliseconds < lowerInclusiveMilliseconds) {
            continue;
        }
        if (bucketMilliseconds >= upperExclusiveMilliseconds) {
            continue;
        }
        total += count.unsignedIntegerValue;
    }
    return total;
}

static NSString *MDKClassifyCadenceHistogram(NSDictionary<NSString *, NSNumber *> *histogram, NSUInteger deltaCount) {
    if (deltaCount < 20) {
        return @"insufficient-data";
    }

    const NSUInteger fastCount = MDKHistogramCountInRange(histogram, 0.0, 12.5);
    const NSUInteger sixtyLikeCount = MDKHistogramCountInRange(histogram, 12.5, 20.0);
    const NSUInteger longGapCount = MDKHistogramCountInRange(histogram, 20.0, DBL_MAX);
    const double fastRatio = static_cast<double>(fastCount) / static_cast<double>(deltaCount);
    const double sixtyLikeRatio = static_cast<double>(sixtyLikeCount) / static_cast<double>(deltaCount);
    const double longGapRatio = static_cast<double>(longGapCount) / static_cast<double>(deltaCount);

    if (fastRatio >= 0.7) {
        return @"120hz-like";
    }

    if (sixtyLikeRatio >= 0.7) {
        return @"60hz-like";
    }

    if (longGapRatio >= 0.2) {
        return @"coalesced-or-mixed";
    }

    return @"mixed-or-transitional";
}

static void MDKIncrementMutableHistogram(NSMutableDictionary<NSString *, NSNumber *> *histogram, NSString *bucket) {
    if (histogram == nil || bucket == nil) {
        return;
    }

    histogram[bucket] = @([histogram[bucket] unsignedIntegerValue] + 1);
}

static NSDictionary<NSString *, id> *MDKCopyTraceEventCadenceSummary(
    NSArray<NSDictionary<NSString *, id> *> *events,
    NSSet<NSString *> *eventKinds
) {
    NSMutableDictionary<NSString *, NSNumber *> *histogram = [NSMutableDictionary dictionary];
    NSUInteger eventCount = 0;
    NSUInteger deltaCount = 0;
    uint64_t lastTimestampNanos = 0;
    BOOL hasLastTimestamp = NO;
    NSNumber *minDeltaMilliseconds = nil;
    NSNumber *maxDeltaMilliseconds = nil;

    for (NSDictionary<NSString *, id> *event in events) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
        NSNumber *timestampNanos = [event[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? event[@"timestampNanos"] : nil;
        if (kind == nil || timestampNanos == nil || ![eventKinds containsObject:kind]) {
            continue;
        }

        eventCount += 1;
        if (hasLastTimestamp) {
            const double deltaMilliseconds =
                static_cast<double>(timestampNanos.unsignedLongLongValue - lastTimestampNanos) / 1000000.0;
            MDKIncrementMutableHistogram(histogram, MDKBucketMilliseconds(deltaMilliseconds));
            deltaCount += 1;
            if (minDeltaMilliseconds == nil || deltaMilliseconds < minDeltaMilliseconds.doubleValue) {
                minDeltaMilliseconds = @(deltaMilliseconds);
            }
            if (maxDeltaMilliseconds == nil || deltaMilliseconds > maxDeltaMilliseconds.doubleValue) {
                maxDeltaMilliseconds = @(deltaMilliseconds);
            }
        }

        lastTimestampNanos = timestampNanos.unsignedLongLongValue;
        hasLastTimestamp = YES;
    }

    NSDictionary<NSString *, NSNumber *> *immutableHistogram = [histogram copy];
    return @{
        @"eventCount": @(eventCount),
        @"deltaCount": @(deltaCount),
        @"deltaHistogram": immutableHistogram,
        @"deltaMinMilliseconds": minDeltaMilliseconds ?: [NSNull null],
        @"deltaMaxMilliseconds": maxDeltaMilliseconds ?: [NSNull null],
        @"delta120HzEquivalentCount": @(MDKHistogramCountInRange(immutableHistogram, 0.0, 10.0)),
        @"deltaFastCount": @(MDKHistogramCountInRange(immutableHistogram, 0.0, 12.5)),
        @"deltaSixtyLikeCount": @(MDKHistogramCountInRange(immutableHistogram, 12.5, 20.0)),
        @"deltaLongGapCount": @(MDKHistogramCountInRange(immutableHistogram, 20.0, DBL_MAX)),
        @"cadenceClassification": MDKClassifyCadenceHistogram(immutableHistogram, deltaCount),
    };
}

static void MDKUpdateSCKSampleBufferDiagnostics(CMSampleBufferRef sampleBuffer) {
    if (sampleBuffer == nullptr) {
        return;
    }

    const uint64_t arrivalTimestampNanos = MDKCurrentTraceTimestampNanos();
    const CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = nullptr;
    if (imageBuffer != nullptr && CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID()) {
        surface = CVPixelBufferGetIOSurface(reinterpret_cast<CVPixelBufferRef>(imageBuffer));
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return;
        }

        NSNumber *lastArrivalTimestampNanos = MDKActiveSCKTraceState[@"sampleBufferLastArrivalTimestampNanos"];
        if (lastArrivalTimestampNanos != nil) {
            const double arrivalDeltaMs =
                static_cast<double>(arrivalTimestampNanos - lastArrivalTimestampNanos.unsignedLongLongValue) / 1000000.0;
            MDKIncrementMutableHistogram(
                MDKActiveSCKTraceState[@"sampleBufferArrivalDeltaHistogram"],
                MDKBucketMilliseconds(arrivalDeltaMs)
            );
            MDKActiveSCKTraceState[@"sampleBufferArrivalDeltaCount"] =
                @([MDKActiveSCKTraceState[@"sampleBufferArrivalDeltaCount"] unsignedIntegerValue] + 1);
            NSNumber *maxArrivalDeltaMs = MDKActiveSCKTraceState[@"sampleBufferArrivalDeltaMaxMilliseconds"];
            NSNumber *minArrivalDeltaMs = MDKActiveSCKTraceState[@"sampleBufferArrivalDeltaMinMilliseconds"];
            if (maxArrivalDeltaMs == nil || arrivalDeltaMs > maxArrivalDeltaMs.doubleValue) {
                MDKActiveSCKTraceState[@"sampleBufferArrivalDeltaMaxMilliseconds"] = @(arrivalDeltaMs);
            }
            if (minArrivalDeltaMs == nil || arrivalDeltaMs < minArrivalDeltaMs.doubleValue) {
                MDKActiveSCKTraceState[@"sampleBufferArrivalDeltaMinMilliseconds"] = @(arrivalDeltaMs);
            }
        }
        MDKActiveSCKTraceState[@"sampleBufferLastArrivalTimestampNanos"] = @(arrivalTimestampNanos);

        if (CMTIME_IS_NUMERIC(presentationTimeStamp)) {
            const double ptsSeconds = CMTimeGetSeconds(presentationTimeStamp);
            NSNumber *lastPTSSeconds = MDKActiveSCKTraceState[@"sampleBufferLastPresentationTimeSeconds"];
            if (lastPTSSeconds != nil) {
                const double ptsDeltaMs = (ptsSeconds - lastPTSSeconds.doubleValue) * 1000.0;
                MDKIncrementMutableHistogram(
                    MDKActiveSCKTraceState[@"sampleBufferPresentationDeltaHistogram"],
                    MDKBucketMilliseconds(ptsDeltaMs)
                );
                MDKActiveSCKTraceState[@"sampleBufferPresentationDeltaCount"] =
                    @([MDKActiveSCKTraceState[@"sampleBufferPresentationDeltaCount"] unsignedIntegerValue] + 1);
                NSNumber *maxPresentationDeltaMs = MDKActiveSCKTraceState[@"sampleBufferPresentationDeltaMaxMilliseconds"];
                NSNumber *minPresentationDeltaMs = MDKActiveSCKTraceState[@"sampleBufferPresentationDeltaMinMilliseconds"];
                if (maxPresentationDeltaMs == nil || ptsDeltaMs > maxPresentationDeltaMs.doubleValue) {
                    MDKActiveSCKTraceState[@"sampleBufferPresentationDeltaMaxMilliseconds"] = @(ptsDeltaMs);
                }
                if (minPresentationDeltaMs == nil || ptsDeltaMs < minPresentationDeltaMs.doubleValue) {
                    MDKActiveSCKTraceState[@"sampleBufferPresentationDeltaMinMilliseconds"] = @(ptsDeltaMs);
                }
            }
            MDKActiveSCKTraceState[@"sampleBufferLastPresentationTimeSeconds"] = @(ptsSeconds);
        }

        if (surface != nullptr) {
            NSString *surfacePointer = [NSString stringWithFormat:@"%p", surface];
            MDKActiveSCKTraceState[@"sampleBufferLastSurfacePointer"] = surfacePointer;
            NSMutableSet<NSString *> *uniqueSurfacePointers = MDKActiveSCKTraceState[@"sampleBufferUniqueSurfacePointers"];
            [uniqueSurfacePointers addObject:surfacePointer];
            MDKActiveSCKTraceState[@"sampleBufferUniqueSurfaceCount"] = @(uniqueSurfacePointers.count);

            NSString *previousSurfacePointer = MDKActiveSCKTraceState[@"sampleBufferPreviousSurfacePointer"];
            if (previousSurfacePointer != nil && [previousSurfacePointer isEqualToString:surfacePointer]) {
                MDKActiveSCKTraceState[@"sampleBufferConsecutiveSurfaceReuseCount"] =
                    @([MDKActiveSCKTraceState[@"sampleBufferConsecutiveSurfaceReuseCount"] unsignedIntegerValue] + 1);
            }
            MDKActiveSCKTraceState[@"sampleBufferPreviousSurfacePointer"] = surfacePointer;

            const uint32_t useCount = IOSurfaceGetUseCount(surface);
            MDKIncrementMutableHistogram(
                MDKActiveSCKTraceState[@"sampleBufferSurfaceUseCountHistogram"],
                [NSString stringWithFormat:@"%u", useCount]
            );
            if (useCount > [MDKActiveSCKTraceState[@"sampleBufferSurfaceUseCountMax"] unsignedIntValue]) {
                MDKActiveSCKTraceState[@"sampleBufferSurfaceUseCountMax"] = @(useCount);
            }
        }
    }
}

static NSArray<NSString *> *MDKTraceDiagnosticNotes(NSDictionary *event) {
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    if (event[@"timestampNanos"] != nil) {
        [notes addObject:[NSString stringWithFormat:@"timestampNanos=%@", MDKDescribeTraceValue(event[@"timestampNanos"])]];
    }
    if (event[@"threadID"] != nil) {
        [notes addObject:[NSString stringWithFormat:@"threadID=%@", MDKDescribeTraceValue(event[@"threadID"])]];
    }
    if (event[@"queueLabel"] != nil) {
        [notes addObject:[NSString stringWithFormat:@"queueLabel=%@", MDKDescribeTraceValue(event[@"queueLabel"])]];
    }
    return notes;
}

static NSDictionary<NSString *, id> *MDKMakeTraceStep(
    NSString *name,
    NSString *selector,
    NSString * _Nullable symbol,
    NSNumber * _Nullable status,
    NSNumber * _Nullable succeeded,
    NSArray<NSString *> *notes
) {
    NSMutableDictionary<NSString *, id> *step = [@{
        @"name": name,
        @"notes": notes,
    } mutableCopy];
    if (selector != nil) {
        step[@"selector"] = selector;
    }
    if (symbol != nil) {
        step[@"symbol"] = symbol;
    }
    if (status != nil) {
        step[@"status"] = status;
    }
    if (succeeded != nil) {
        step[@"succeeded"] = succeeded;
    }
    return step;
}

static void MDKSwizzledProxyCoreGraphics(
    id self,
    SEL _cmd,
    unsigned char methodType,
    id config,
    id machPort,
    id completionHandler
) {
    MDKRecordSCKTraceEvent(
        @"proxy-core-graphics",
        @{
            @"methodType": @(methodType),
            @"config": MDKSummarizeObject(config),
            @"machPort": MDKSummarizeObject(machPort),
        }
    );

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"sawProxyCoreGraphics"] = @YES;
        }
    }

    MDKOriginalProxyCoreGraphics(self, _cmd, methodType, config, machPort, completionHandler);
}

static void MDKSwizzledStartRemoteQueue(id self, SEL _cmd, id queue, id streamID) {
    MDKRecordSCKTraceEvent(
        @"start-remote-queue",
        @{
            @"queue": MDKSummarizeObject(queue),
            @"streamID": MDKSummarizeObject(streamID),
        }
    );

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"sawStartRemoteQueue"] = @YES;
        }
    }

    MDKOriginalStartRemoteQueue(self, _cmd, queue, streamID);
}

static void MDKSwizzledStartCaptureProxy(
    id self,
    SEL _cmd,
    id stream,
    id contentFilter,
    id preservedFilter,
    id transactionID,
    id properties,
    id extensionToken,
    id completionHandler
) {
    MDKRecordSCKTraceEvent(
        @"start-capture-proxy",
        @{
            @"stream": MDKSummarizeObject(stream),
            @"contentFilter": MDKSummarizeObject(contentFilter),
            @"preservedFilter": MDKSummarizeObject(preservedFilter),
            @"transactionID": MDKSummarizeObject(transactionID),
            @"properties": MDKSummarizeObject(properties),
            @"extensionToken": MDKSummarizeObject(extensionToken),
        }
    );

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"sawStartCaptureProxy"] = @YES;
        }
    }

    MDKOriginalStartCaptureProxy(
        self,
        _cmd,
        stream,
        contentFilter,
        preservedFilter,
        transactionID,
        properties,
        extensionToken,
        completionHandler
    );
}

static void MDKSwizzledFetchDisplay(
    id self,
    SEL _cmd,
    unsigned int displayID,
    id completionHandler
) {
    MDKRecordSCKTraceEvent(
        @"fetch-display",
        @{
            @"displayID": @(displayID),
            @"completionHandler": MDKSummarizeObject(completionHandler),
        }
    );

    MDKOriginalFetchDisplay(self, _cmd, displayID, completionHandler);
}

static void MDKSwizzledUpdateStreamConfiguration(
    id self,
    SEL _cmd,
    id stream,
    id configuration,
    id transactionID,
    id streamData,
    id completionHandler
) {
    MDKRecordSCKTraceEvent(
        @"update-stream-configuration",
        @{
            @"stream": MDKSummarizeObject(stream),
            @"configuration": MDKSummarizeObject(configuration),
            @"transactionID": MDKSummarizeObject(transactionID),
            @"streamData": MDKSummarizeObject(streamData),
            @"completionHandler": MDKSummarizeObject(completionHandler),
        }
    );

    MDKOriginalUpdateStreamConfiguration(
        self,
        _cmd,
        stream,
        configuration,
        transactionID,
        streamData,
        completionHandler
    );
}

static void MDKSwizzledUpdateStreamContentFilter(
    id self,
    SEL _cmd,
    id stream,
    id contentFilter,
    id preservedContentFilter,
    id transactionID,
    id streamData,
    id completionHandler
) {
    MDKRecordSCKTraceEvent(
        @"update-stream-content-filter",
        @{
            @"stream": MDKSummarizeObject(stream),
            @"contentFilter": MDKSummarizeObject(contentFilter),
            @"preservedContentFilter": MDKSummarizeObject(preservedContentFilter),
            @"transactionID": MDKSummarizeObject(transactionID),
            @"streamData": MDKSummarizeObject(streamData),
            @"completionHandler": MDKSummarizeObject(completionHandler),
        }
    );

    MDKOriginalUpdateStreamContentFilter(
        self,
        _cmd,
        stream,
        contentFilter,
        preservedContentFilter,
        transactionID,
        streamData,
        completionHandler
    );
}

static void MDKSwizzledStreamDidStart(id self, SEL _cmd, id configuration, id contentFilter) {
    MDKRecordSCKTraceEvent(
        @"stream-did-start",
        @{
            @"configuration": MDKSummarizeObject(configuration),
            @"contentFilter": MDKSummarizeObject(contentFilter),
        }
    );

    MDKOriginalStreamDidStart(self, _cmd, configuration, contentFilter);
}

static void MDKSwizzledStreamOutputEffectDidStart(id self, SEL _cmd, BOOL started, id streamID) {
    MDKRecordSCKTraceEvent(
        @"stream-output-effect-did-start",
        @{
            @"started": @(started),
            @"streamID": MDKSummarizeObject(streamID),
        }
    );

    MDKOriginalStreamOutputEffectDidStart(self, _cmd, started, streamID);
}

static void MDKSwizzledManagerStartRemoteQueue(id self, SEL _cmd, id queue, id streamID) {
    MDKRecordSCKTraceEvent(
        @"manager-start-remote-queue",
        @{
            @"queue": MDKSummarizeObject(queue),
            @"streamID": MDKSummarizeObject(streamID),
        }
    );

    MDKOriginalManagerStartRemoteQueue(self, _cmd, queue, streamID);
}

static void MDKSwizzledManagerUpdateClientOutputType(id self, SEL _cmd, id stream, NSUInteger clientOutputType) {
    MDKRecordSCKTraceEvent(
        @"manager-update-stream-client-output-type",
        @{
            @"stream": MDKSummarizeObject(stream),
            @"clientOutputType": @(clientOutputType),
        }
    );

    MDKOriginalManagerUpdateClientOutputType(self, _cmd, stream, clientOutputType);
}

static void MDKSwizzledManagerStreamUpdateWithFilter(id self, SEL _cmd, id stream, id filter) {
    MDKRecordSCKTraceEvent(
        @"manager-stream-update-filter",
        @{
            @"stream": MDKSummarizeObject(stream),
            @"filter": MDKSummarizeObject(filter),
        }
    );

    MDKOriginalManagerStreamUpdateWithFilter(self, _cmd, stream, filter);
}

static void MDKSwizzledManagerStreamDidRequestUpdateFilter(id self, SEL _cmd, id stream, id filter) {
    MDKRecordSCKTraceEvent(
        @"manager-stream-did-request-update-filter",
        @{
            @"stream": MDKSummarizeObject(stream),
            @"filter": MDKSummarizeObject(filter),
        }
    );

    MDKOriginalManagerStreamDidRequestUpdateFilter(self, _cmd, stream, filter);
}

static void MDKSwizzledManagerStreamOutputEffectDidStart(id self, SEL _cmd, BOOL started, id streamID) {
    MDKRecordSCKTraceEvent(
        @"manager-stream-output-effect-did-start",
        @{
            @"started": @(started),
            @"streamID": MDKSummarizeObject(streamID),
        }
    );

    MDKOriginalManagerStreamOutputEffectDidStart(self, _cmd, started, streamID);
}

static NSDictionary<NSString *, id> *MDKSummarizeIOSurface(IOSurfaceRef surface) {
    if (surface == nullptr) {
        return @{
            @"present": @NO
        };
    }

    return @{
        @"present": @YES,
        @"width": @(IOSurfaceGetWidth(surface)),
        @"height": @(IOSurfaceGetHeight(surface)),
        @"bytesPerRow": @(IOSurfaceGetBytesPerRow(surface)),
        @"pixelFormat": @(IOSurfaceGetPixelFormat(surface)),
        @"useCount": @(IOSurfaceGetUseCount(surface)),
        @"pointer": [NSString stringWithFormat:@"%p", surface],
    };
}

static void MDKRecordRPIOSurfaceEvent(NSString *kind, IOSurfaceRef surface) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"rpIOSurfaceEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"rpIOSurfaceEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(
        kind,
        @{
            @"surface": MDKSummarizeIOSurface(surface),
        }
    );
}

static void MDKRecordCaptureHandlerSampleEvent(NSString *kind, id sample, id timingData) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"captureHandlerSampleEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"captureHandlerSampleEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(
        kind,
        @{
            @"sample": MDKSummarizeSampleCarrier(sample),
            @"timingData": MDKSummarizeObject(timingData),
        }
    );
}

static void MDKRecordCAContentStreamEvent(NSString *kind, NSDictionary<NSString *, id> *payload) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"contentStreamEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"contentStreamEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordSurfaceTransportEvent(NSString *kind, NSDictionary<NSString *, id> *payload) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"surfaceTransportEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"surfaceTransportEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 6;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordFrameReceiverEvent(NSString *kind, NSDictionary<NSString *, id> *payload) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"frameReceiverEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"frameReceiverEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 6;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordRemoteQueueSinkEvent(NSString *kind, NSDictionary<NSString *, id> *payload) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"remoteQueueSinkEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"remoteQueueSinkEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordRemoteQueueObjectEvent(NSString *kind, NSDictionary<NSString *, id> *payload) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"remoteQueueObjectEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"remoteQueueObjectEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 8;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKSwizzledRPIOSurfaceSet(id self, SEL _cmd, IOSurfaceRef surface) {
    MDKRecordRPIOSurfaceEvent(@"rp-iosurface-set", surface);
    MDKOriginalRPIOSurfaceSet(self, _cmd, surface);
}

static IOSurfaceRef MDKSwizzledRPIOSurfaceGet(id self, SEL _cmd) {
    IOSurfaceRef surface = MDKOriginalRPIOSurfaceGet(self, _cmd);
    MDKRecordRPIOSurfaceEvent(@"rp-iosurface-get", surface);
    return surface;
}

static void MDKSwizzledDaemonCaptureHandlerWithSample(id self, SEL _cmd, id sample, id timingData) {
    MDKRecordCaptureHandlerSampleEvent(@"daemon-capture-handler-sample", sample, timingData);
    MDKOriginalDaemonCaptureHandlerWithSample(self, _cmd, sample, timingData);
}

static void MDKSwizzledScreenRecorderCaptureHandlerWithSample(id self, SEL _cmd, id sample, id timingData) {
    MDKRecordCaptureHandlerSampleEvent(@"screen-recorder-capture-handler-sample", sample, timingData);
    MDKOriginalScreenRecorderCaptureHandlerWithSample(self, _cmd, sample, timingData);
}

static void MDKSwizzledCAContentStreamProduceSurface(id self, SEL _cmd, unsigned int surfaceID, const void *frameInfo) {
    MDKRecordCAContentStreamEvent(
        @"ca-content-stream-produce-surface",
        @{
            @"surfaceID": @(surfaceID),
            @"frameInfo": MDKSummarizePointerValue(frameInfo),
        }
    );
    MDKOriginalCAContentStreamProduceSurface(self, _cmd, surfaceID, frameInfo);
}

static BOOL MDKSwizzledCAContentStreamReleaseSurface(id self, SEL _cmd, IOSurfaceRef surface, NSError **error) {
    BOOL released = MDKOriginalCAContentStreamReleaseSurface(self, _cmd, surface, error);
    MDKRecordCAContentStreamEvent(
        @"ca-content-stream-release-surface",
        @{
            @"surface": MDKSummarizeIOSurface(surface),
            @"released": @(released),
            @"errorDomain": (error != nullptr && *error != nil) ? (*error).domain : [NSNull null],
            @"errorCode": (error != nullptr && *error != nil) ? @((*error).code) : @0,
        }
    );
    return released;
}

static BOOL MDKSwizzledCAContentStreamReleaseSurfaceWithID(id self, SEL _cmd, unsigned int surfaceID, NSError **error) {
    BOOL released = MDKOriginalCAContentStreamReleaseSurfaceWithID(self, _cmd, surfaceID, error);
    MDKRecordCAContentStreamEvent(
        @"ca-content-stream-release-surface-id",
        @{
            @"surfaceID": @(surfaceID),
            @"released": @(released),
            @"errorDomain": (error != nullptr && *error != nil) ? (*error).domain : [NSNull null],
            @"errorCode": (error != nullptr && *error != nil) ? @((*error).code) : @0,
        }
    );
    return released;
}

static void MDKSwizzledIOSurfaceRemoteAddSurface(id self, SEL _cmd, void *surfaceClient, void *mappedAddress, std::uint64_t mappedSize, id extraData) {
    MDKRecordSurfaceTransportEvent(
        @"iosurface-remote-add-surface",
        @{
            @"surfaceClient": MDKSummarizePointerValue(surfaceClient),
            @"mappedAddress": MDKSummarizePointerValue(mappedAddress),
            @"mappedSize": @(mappedSize),
            @"extraData": MDKSummarizeObject(extraData),
        }
    );
    MDKOriginalIOSurfaceRemoteAddSurface(self, _cmd, surfaceClient, mappedAddress, mappedSize, extraData);
}

static void MDKSwizzledIOSurfaceRemoteSetSurfaceStates(id self, SEL _cmd, id surfaceStates) {
    MDKRecordSurfaceTransportEvent(
        @"iosurface-remote-set-surface-states",
        @{
            @"surfaceStates": MDKSummarizeObject(surfaceStates),
        }
    );
    MDKOriginalIOSurfaceRemoteSetSurfaceStates(self, _cmd, surfaceStates);
}

static BOOL MDKSwizzledIOSurfaceRemoteRemoveSurface(id self, SEL _cmd, unsigned int surfaceID) {
    BOOL removed = MDKOriginalIOSurfaceRemoteRemoveSurface(self, _cmd, surfaceID);
    MDKRecordSurfaceTransportEvent(
        @"iosurface-remote-remove-surface",
        @{
            @"surfaceID": @(surfaceID),
            @"removed": @(removed),
        }
    );
    return removed;
}

static id MDKSwizzledFrameReceiverInit(id self, SEL _cmd, id endpoint, id handler) {
    MDKRecordFrameReceiverEvent(
        @"frame-receiver-init",
        @{
            @"endpoint": MDKSummarizeObject(endpoint),
            @"handler": MDKSummarizeObject(handler),
            @"handlerBlockSignature": MDKCopyBlockSignatureString(handler) ?: [NSNull null],
        }
    );

    return MDKOriginalFrameReceiverInit(self, _cmd, endpoint, handler);
}

static void MDKSwizzledBWRenderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-render",
        @{
            @"sampleBuffer": MDKSummarizeSampleBuffer(sampleBuffer),
            @"input": MDKSummarizeObject(input),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWRenderSampleBuffer(self, _cmd, sampleBuffer, input);
}

static void MDKSwizzledBWHandleDroppedSample(id self, SEL _cmd, id sample, id input) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-drop",
        @{
            @"sample": MDKSummarizeObject(sample),
            @"input": MDKSummarizeObject(input),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWHandleDroppedSample(self, _cmd, sample, input);
}

static void MDKSwizzledFigSetSinkNode(id self, SEL _cmd, id sinkNode) {
    MDKRecordRemoteQueueSinkEvent(
        @"fig-remote-queue-set-sink",
        @{
            @"pipeline": MDKSummarizeObject(self),
            @"sinkNode": MDKSummarizeObject(sinkNode),
        }
    );

    MDKOriginalFigSetSinkNode(self, _cmd, sinkNode);
}

static void MDKSwizzledSCRemoteQueueSetRemoteQueue(id self, SEL _cmd, id remoteQueue) {
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil && remoteQueue != nil && MDKActiveSCKRemoteQueues != nil) {
            [MDKActiveSCKRemoteQueues addObject:remoteQueue];
        }
        NSString *queueKey = MDKPointerKey(self);
        if (queueKey != nil && MDKActiveSCKRemoteQueueEntries != nil) {
            NSMutableDictionary<NSString *, id> *entry = MDKActiveSCKRemoteQueueEntries[queueKey];
            if (entry == nil) {
                entry = [NSMutableDictionary dictionary];
                MDKActiveSCKRemoteQueueEntries[queueKey] = entry;
            }
            entry[@"queueObject"] = self;
            if (remoteQueue != nil) {
                entry[@"remoteQueue"] = remoteQueue;
            }
        }
    }

    MDKRecordRemoteQueueObjectEvent(
        @"sc-remote-queue-set-remote-queue",
        @{
            @"queueObject": MDKSummarizeObject(self),
            @"remoteQueue": MDKSummarizeObject(remoteQueue),
        }
    );

    MDKOriginalSCRemoteQueueSetRemoteQueue(self, _cmd, remoteQueue);
}

static void MDKSwizzledSCRemoteQueueSetQueueType(id self, SEL _cmd, unsigned char queueType) {
    @synchronized(MDKActiveSCKTraceLock) {
        NSString *queueKey = MDKPointerKey(self);
        if (queueKey != nil && MDKActiveSCKRemoteQueueEntries != nil) {
            NSMutableDictionary<NSString *, id> *entry = MDKActiveSCKRemoteQueueEntries[queueKey];
            if (entry == nil) {
                entry = [NSMutableDictionary dictionary];
                MDKActiveSCKRemoteQueueEntries[queueKey] = entry;
            }
            entry[@"queueObject"] = self;
            entry[@"queueType"] = @(queueType);
        }
    }

    MDKRecordRemoteQueueObjectEvent(
        @"sc-remote-queue-set-queue-type",
        @{
            @"queueObject": MDKSummarizeObject(self),
            @"queueType": @(queueType),
        }
    );

    MDKOriginalSCRemoteQueueSetQueueType(self, _cmd, queueType);
}

static void MDKRecordRemoteQueueConsumerEvent(NSString *kind, id queue) {
    NSString *queueKey = MDKPointerKey(queue);
    if (queueKey != nil) {
        @synchronized(MDKActiveSCKTraceLock) {
            if (MDKActiveSCKRemoteQueueEntries != nil) {
                NSMutableDictionary<NSString *, id> *entry = MDKActiveSCKRemoteQueueEntries[queueKey];
                if (entry == nil) {
                    entry = [NSMutableDictionary dictionary];
                    MDKActiveSCKRemoteQueueEntries[queueKey] = entry;
                }
                entry[@"queueObject"] = queue;
                NSNumber *queueType = MDKPerformUnsignedCharGetter(queue, sel_registerName("queueType"));
                if (queueType != nil) {
                    entry[@"queueType"] = queueType;
                }
                id remoteQueue = MDKPerformObjectGetter(queue, sel_registerName("remoteQueue"));
                if (remoteQueue != nil) {
                    entry[@"remoteQueue"] = remoteQueue;
                }
            }
        }
    }

    MDKRecordSCKTraceEvent(
        kind,
        @{
            @"queue": MDKSummarizeObject(queue),
        }
    );
}

static void MDKSwizzledStartRemoteReceiveQueue(id self, SEL _cmd, id queue) {
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-receive-queue", queue);
    MDKOriginalStartRemoteReceiveQueue(self, _cmd, queue);
}

static void MDKSwizzledStartRemoteVideoReceiveQueue(id self, SEL _cmd, id queue) {
    BOOL needsPrime = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        needsPrime = MDKActiveSCKAllowPrivateQueueProbes && (MDKActiveSCRemoteQueueWrapper == nullptr);
    }
    if (needsPrime) {
        NSDictionary<NSString *, id> *videoQueueEntry = MDKCopySCKRemoteQueueEntryForType(1);
        id remoteQueueCandidate = videoQueueEntry[@"remoteQueue"];

        BOOL wrapped = NO;
        if (remoteQueueCandidate != nil) {
            wrapped = MDKPrimeSCRemoteQueueWrapperIfPossible(remoteQueueCandidate);
        }
        if (!wrapped) {
            wrapped = MDKPrimeSCRemoteQueueWrapperIfPossible(queue);
        }
    }

    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-video-receive-queue", queue);
    MDKOriginalStartRemoteVideoReceiveQueue(self, _cmd, queue);
    MDKRecordSCKTraceEvent(
        @"stream-post-start-remote-video-state",
        @{
            @"queue": MDKSummarizeObject(queue),
            @"streamState": MDKCopySCStreamInternalState(self),
        }
    );
}

static void MDKSwizzledStartRemoteAudioReceiveQueue(id self, SEL _cmd, id queue) {
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-audio-receive-queue", queue);
    MDKOriginalStartRemoteAudioReceiveQueue(self, _cmd, queue);
}

static void MDKSwizzledStartRemoteMicrophoneReceiveQueue(id self, SEL _cmd, id queue) {
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-microphone-receive-queue", queue);
    MDKOriginalStartRemoteMicrophoneReceiveQueue(self, _cmd, queue);
}

static void MDKSwizzledCollectStreamData(id self, SEL _cmd) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger collectCount = [MDKActiveSCKTraceState[@"collectStreamDataCallCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"collectStreamDataCallCount"] = @(collectCount);
            shouldRecord = collectCount <= 4;
        }
    }
    if (shouldRecord) {
        MDKRecordSCKTraceEvent(
            @"collect-stream-data",
            @{
                @"streamState": MDKCopySCStreamInternalState(self),
            }
        );
    }
    MDKOriginalCollectStreamData(self, _cmd);
}

static void MDKInstallSCKProxyTraceHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW | RTLD_GLOBAL);
        Class daemonProxyClass = NSClassFromString(@"RPDaemonProxy");
        if (daemonProxyClass == Nil) {
            return;
        }

        Method proxyMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:")
        );
        if (proxyMethod != nullptr) {
            MDKOriginalProxyCoreGraphics = reinterpret_cast<MDKProxyCoreGraphicsFn>(method_getImplementation(proxyMethod));
            method_setImplementation(proxyMethod, reinterpret_cast<IMP>(MDKSwizzledProxyCoreGraphics));
        }

        Method startRemoteQueueMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("startRemoteQueue:streamID:")
        );
        if (startRemoteQueueMethod != nullptr) {
            MDKOriginalStartRemoteQueue = reinterpret_cast<MDKStartRemoteQueueFn>(method_getImplementation(startRemoteQueueMethod));
            method_setImplementation(startRemoteQueueMethod, reinterpret_cast<IMP>(MDKSwizzledStartRemoteQueue));
        }

        Method startCaptureMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("startCapture:withContentFilter:preservedFilter:transactionID:properties:extensionToken:completionHandler:")
        );
        if (startCaptureMethod != nullptr) {
            MDKOriginalStartCaptureProxy = reinterpret_cast<MDKStartCaptureProxyFn>(method_getImplementation(startCaptureMethod));
            method_setImplementation(startCaptureMethod, reinterpret_cast<IMP>(MDKSwizzledStartCaptureProxy));
        }

        Method fetchDisplayMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("fetchDisplay:withCompletionHandler:")
        );
        if (fetchDisplayMethod != nullptr) {
            MDKOriginalFetchDisplay = reinterpret_cast<MDKFetchDisplayFn>(method_getImplementation(fetchDisplayMethod));
            method_setImplementation(fetchDisplayMethod, reinterpret_cast<IMP>(MDKSwizzledFetchDisplay));
        }

        Method updateStreamConfigurationMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("updateStream:withStreamConfiguration:transactionID:streamData:completionHandler:")
        );
        if (updateStreamConfigurationMethod != nullptr) {
            MDKOriginalUpdateStreamConfiguration =
                reinterpret_cast<MDKUpdateStreamConfigurationFn>(method_getImplementation(updateStreamConfigurationMethod));
            method_setImplementation(
                updateStreamConfigurationMethod,
                reinterpret_cast<IMP>(MDKSwizzledUpdateStreamConfiguration)
            );
        }

        Method updateStreamContentFilterMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("updateStream:withContentFilter:preservedContentFilter:transactionID:streamData:completionHandler:")
        );
        if (updateStreamContentFilterMethod != nullptr) {
            MDKOriginalUpdateStreamContentFilter =
                reinterpret_cast<MDKUpdateStreamContentFilterFn>(method_getImplementation(updateStreamContentFilterMethod));
            method_setImplementation(
                updateStreamContentFilterMethod,
                reinterpret_cast<IMP>(MDKSwizzledUpdateStreamContentFilter)
            );
        }

        Method streamDidStartMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("streamDidStartWithConfiguration:contentFilter:")
        );
        if (streamDidStartMethod != nullptr) {
            MDKOriginalStreamDidStart =
                reinterpret_cast<MDKStreamDidStartFn>(method_getImplementation(streamDidStartMethod));
            method_setImplementation(
                streamDidStartMethod,
                reinterpret_cast<IMP>(MDKSwizzledStreamDidStart)
            );
        }

        Method streamOutputEffectDidStartMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("streamOutputEffectDidStart:withStreamID:")
        );
        if (streamOutputEffectDidStartMethod != nullptr) {
            MDKOriginalStreamOutputEffectDidStart =
                reinterpret_cast<MDKStreamOutputEffectDidStartFn>(method_getImplementation(streamOutputEffectDidStartMethod));
            method_setImplementation(
                streamOutputEffectDidStartMethod,
                reinterpret_cast<IMP>(MDKSwizzledStreamOutputEffectDidStart)
            );
        }

        Method daemonCaptureHandlerWithSampleMethod = class_getInstanceMethod(
            daemonProxyClass,
            sel_registerName("captureHandlerWithSample:timingData:")
        );
        if (daemonCaptureHandlerWithSampleMethod != nullptr) {
            MDKOriginalDaemonCaptureHandlerWithSample =
                reinterpret_cast<MDKCaptureHandlerWithSampleFn>(method_getImplementation(daemonCaptureHandlerWithSampleMethod));
            method_setImplementation(
                daemonCaptureHandlerWithSampleMethod,
                reinterpret_cast<IMP>(MDKSwizzledDaemonCaptureHandlerWithSample)
            );
        }

        Class streamClass = NSClassFromString(@"SCStream");
        if (streamClass == Nil) {
            return;
        }

        Method startRemoteReceiveQueueMethod = class_getInstanceMethod(
            streamClass,
            sel_registerName("startRemoteReceiveQueue:")
        );
        if (startRemoteReceiveQueueMethod != nullptr) {
            MDKOriginalStartRemoteReceiveQueue =
                reinterpret_cast<MDKStartRemoteReceiveQueueConsumerFn>(method_getImplementation(startRemoteReceiveQueueMethod));
            method_setImplementation(
                startRemoteReceiveQueueMethod,
                reinterpret_cast<IMP>(MDKSwizzledStartRemoteReceiveQueue)
            );
        }

        Method startRemoteVideoReceiveQueueMethod = class_getInstanceMethod(
            streamClass,
            sel_registerName("startRemoteVideoReceiveQueue:")
        );
        if (startRemoteVideoReceiveQueueMethod != nullptr) {
            MDKOriginalStartRemoteVideoReceiveQueue =
                reinterpret_cast<MDKStartRemoteReceiveQueueConsumerFn>(method_getImplementation(startRemoteVideoReceiveQueueMethod));
            method_setImplementation(
                startRemoteVideoReceiveQueueMethod,
                reinterpret_cast<IMP>(MDKSwizzledStartRemoteVideoReceiveQueue)
            );
        }

        Method startRemoteAudioReceiveQueueMethod = class_getInstanceMethod(
            streamClass,
            sel_registerName("startRemoteAudioReceiveQueue:")
        );
        if (startRemoteAudioReceiveQueueMethod != nullptr) {
            MDKOriginalStartRemoteAudioReceiveQueue =
                reinterpret_cast<MDKStartRemoteReceiveQueueConsumerFn>(method_getImplementation(startRemoteAudioReceiveQueueMethod));
            method_setImplementation(
                startRemoteAudioReceiveQueueMethod,
                reinterpret_cast<IMP>(MDKSwizzledStartRemoteAudioReceiveQueue)
            );
        }

        Method startRemoteMicrophoneReceiveQueueMethod = class_getInstanceMethod(
            streamClass,
            sel_registerName("startRemoteMicrophoneReceiveQueue:")
        );
        if (startRemoteMicrophoneReceiveQueueMethod != nullptr) {
            MDKOriginalStartRemoteMicrophoneReceiveQueue =
                reinterpret_cast<MDKStartRemoteReceiveQueueConsumerFn>(method_getImplementation(startRemoteMicrophoneReceiveQueueMethod));
            method_setImplementation(
                startRemoteMicrophoneReceiveQueueMethod,
                reinterpret_cast<IMP>(MDKSwizzledStartRemoteMicrophoneReceiveQueue)
            );
        }

        Method collectStreamDataMethod = class_getInstanceMethod(
            streamClass,
            sel_registerName("collectStreamData")
        );
        if (collectStreamDataMethod != nullptr) {
            MDKOriginalCollectStreamData =
                reinterpret_cast<MDKCollectStreamDataFn>(method_getImplementation(collectStreamDataMethod));
            method_setImplementation(
                collectStreamDataMethod,
                reinterpret_cast<IMP>(MDKSwizzledCollectStreamData)
            );
        }

        Class streamManagerClass = NSClassFromString(@"SCStreamManager");
        if (streamManagerClass != Nil) {
            Method managerStartRemoteQueueMethod = class_getInstanceMethod(
                streamManagerClass,
                sel_registerName("startRemoteQueue:streamID:")
            );
            if (managerStartRemoteQueueMethod != nullptr) {
                MDKOriginalManagerStartRemoteQueue =
                    reinterpret_cast<MDKManagerStartRemoteQueueFn>(method_getImplementation(managerStartRemoteQueueMethod));
                method_setImplementation(
                    managerStartRemoteQueueMethod,
                    reinterpret_cast<IMP>(MDKSwizzledManagerStartRemoteQueue)
                );
            }

            Method managerUpdateClientOutputTypeMethod = class_getInstanceMethod(
                streamManagerClass,
                sel_registerName("updateStream:withClientOutputType:")
            );
            if (managerUpdateClientOutputTypeMethod != nullptr) {
                MDKOriginalManagerUpdateClientOutputType =
                    reinterpret_cast<MDKManagerUpdateClientOutputTypeFn>(method_getImplementation(managerUpdateClientOutputTypeMethod));
                method_setImplementation(
                    managerUpdateClientOutputTypeMethod,
                    reinterpret_cast<IMP>(MDKSwizzledManagerUpdateClientOutputType)
                );
            }

            Method managerStreamUpdateWithFilterMethod = class_getInstanceMethod(
                streamManagerClass,
                sel_registerName("stream:updateWithFilter:")
            );
            if (managerStreamUpdateWithFilterMethod != nullptr) {
                MDKOriginalManagerStreamUpdateWithFilter =
                    reinterpret_cast<MDKManagerStreamUpdateWithFilterFn>(method_getImplementation(managerStreamUpdateWithFilterMethod));
                method_setImplementation(
                    managerStreamUpdateWithFilterMethod,
                    reinterpret_cast<IMP>(MDKSwizzledManagerStreamUpdateWithFilter)
                );
            }

            Method managerStreamDidRequestUpdateFilterMethod = class_getInstanceMethod(
                streamManagerClass,
                sel_registerName("stream:didRequestUpdateFilter:")
            );
            if (managerStreamDidRequestUpdateFilterMethod != nullptr) {
                MDKOriginalManagerStreamDidRequestUpdateFilter =
                    reinterpret_cast<MDKManagerStreamUpdateWithFilterFn>(method_getImplementation(managerStreamDidRequestUpdateFilterMethod));
                method_setImplementation(
                    managerStreamDidRequestUpdateFilterMethod,
                    reinterpret_cast<IMP>(MDKSwizzledManagerStreamDidRequestUpdateFilter)
                );
            }

            Method managerStreamOutputEffectDidStartMethod = class_getInstanceMethod(
                streamManagerClass,
                sel_registerName("streamOutputEffectDidStart:withStreamID:")
            );
            if (managerStreamOutputEffectDidStartMethod != nullptr) {
                MDKOriginalManagerStreamOutputEffectDidStart =
                    reinterpret_cast<MDKManagerStreamOutputEffectDidStartFn>(method_getImplementation(managerStreamOutputEffectDidStartMethod));
                method_setImplementation(
                    managerStreamOutputEffectDidStartMethod,
                    reinterpret_cast<IMP>(MDKSwizzledManagerStreamOutputEffectDidStart)
                );
            }
        }

        Class rpIOSurfaceObjectClass = NSClassFromString(@"RPIOSurfaceObject");
        if (rpIOSurfaceObjectClass != Nil) {
            Method setIOSurfaceMethod = class_getInstanceMethod(
                rpIOSurfaceObjectClass,
                sel_registerName("setIOSurface:")
            );
            if (setIOSurfaceMethod != nullptr) {
                MDKOriginalRPIOSurfaceSet =
                    reinterpret_cast<MDKRPIOSurfaceSetFn>(method_getImplementation(setIOSurfaceMethod));
                method_setImplementation(
                    setIOSurfaceMethod,
                    reinterpret_cast<IMP>(MDKSwizzledRPIOSurfaceSet)
                );
            }

            Method ioSurfaceMethod = class_getInstanceMethod(
                rpIOSurfaceObjectClass,
                sel_registerName("ioSurface")
            );
            if (ioSurfaceMethod != nullptr) {
                MDKOriginalRPIOSurfaceGet =
                    reinterpret_cast<MDKRPIOSurfaceGetFn>(method_getImplementation(ioSurfaceMethod));
                method_setImplementation(
                    ioSurfaceMethod,
                    reinterpret_cast<IMP>(MDKSwizzledRPIOSurfaceGet)
                );
            }
        }

        Class screenRecorderClass = NSClassFromString(@"RPScreenRecorder");
        if (screenRecorderClass != Nil) {
            Method screenRecorderCaptureHandlerWithSampleMethod = class_getInstanceMethod(
                screenRecorderClass,
                sel_registerName("captureHandlerWithSample:timingData:")
            );
            if (screenRecorderCaptureHandlerWithSampleMethod != nullptr) {
                MDKOriginalScreenRecorderCaptureHandlerWithSample =
                    reinterpret_cast<MDKCaptureHandlerWithSampleFn>(method_getImplementation(screenRecorderCaptureHandlerWithSampleMethod));
                method_setImplementation(
                    screenRecorderCaptureHandlerWithSampleMethod,
                    reinterpret_cast<IMP>(MDKSwizzledScreenRecorderCaptureHandlerWithSample)
                );
            }
        }

        Class caContentStreamClass = NSClassFromString(@"CAContentStream");
        if (caContentStreamClass != Nil) {
            Method produceSurfaceMethod = class_getInstanceMethod(
                caContentStreamClass,
                sel_registerName("produceSurface:withFrameInfo:")
            );
            if (produceSurfaceMethod != nullptr) {
                MDKOriginalCAContentStreamProduceSurface =
                    reinterpret_cast<MDKCAContentStreamProduceSurfaceFn>(method_getImplementation(produceSurfaceMethod));
                method_setImplementation(
                    produceSurfaceMethod,
                    reinterpret_cast<IMP>(MDKSwizzledCAContentStreamProduceSurface)
                );
            }

            Method releaseSurfaceMethod = class_getInstanceMethod(
                caContentStreamClass,
                sel_registerName("releaseSurface:error:")
            );
            if (releaseSurfaceMethod != nullptr) {
                MDKOriginalCAContentStreamReleaseSurface =
                    reinterpret_cast<MDKCAContentStreamReleaseSurfaceFn>(method_getImplementation(releaseSurfaceMethod));
                method_setImplementation(
                    releaseSurfaceMethod,
                    reinterpret_cast<IMP>(MDKSwizzledCAContentStreamReleaseSurface)
                );
            }

            Method releaseSurfaceWithIDMethod = class_getInstanceMethod(
                caContentStreamClass,
                sel_registerName("releaseSurfaceWithId:error:")
            );
            if (releaseSurfaceWithIDMethod != nullptr) {
                MDKOriginalCAContentStreamReleaseSurfaceWithID =
                    reinterpret_cast<MDKCAContentStreamReleaseSurfaceWithIDFn>(method_getImplementation(releaseSurfaceWithIDMethod));
                method_setImplementation(
                    releaseSurfaceWithIDMethod,
                    reinterpret_cast<IMP>(MDKSwizzledCAContentStreamReleaseSurfaceWithID)
                );
            }
        }

        Class ioSurfaceRemoteClientClass = NSClassFromString(@"IOSurfaceRemoteRemoteClient");
        if (ioSurfaceRemoteClientClass != Nil) {
            Method addSurfaceMethod = class_getInstanceMethod(
                ioSurfaceRemoteClientClass,
                sel_registerName("_addSurface:mappedAddress:mappedSize:extraData:")
            );
            if (addSurfaceMethod != nullptr) {
                MDKOriginalIOSurfaceRemoteAddSurface =
                    reinterpret_cast<MDKIOSurfaceRemoteAddSurfaceFn>(method_getImplementation(addSurfaceMethod));
                method_setImplementation(
                    addSurfaceMethod,
                    reinterpret_cast<IMP>(MDKSwizzledIOSurfaceRemoteAddSurface)
                );
            }

            Method setSurfaceStatesMethod = class_getInstanceMethod(
                ioSurfaceRemoteClientClass,
                sel_registerName("setSurfaceStates:")
            );
            if (setSurfaceStatesMethod != nullptr) {
                MDKOriginalIOSurfaceRemoteSetSurfaceStates =
                    reinterpret_cast<MDKIOSurfaceRemoteSetSurfaceStatesFn>(method_getImplementation(setSurfaceStatesMethod));
                method_setImplementation(
                    setSurfaceStatesMethod,
                    reinterpret_cast<IMP>(MDKSwizzledIOSurfaceRemoteSetSurfaceStates)
                );
            }

            Method removeSurfaceMethod = class_getInstanceMethod(
                ioSurfaceRemoteClientClass,
                sel_registerName("_removeSurface:")
            );
            if (removeSurfaceMethod != nullptr) {
                MDKOriginalIOSurfaceRemoteRemoveSurface =
                    reinterpret_cast<MDKIOSurfaceRemoteRemoveSurfaceFn>(method_getImplementation(removeSurfaceMethod));
                method_setImplementation(
                    removeSurfaceMethod,
                    reinterpret_cast<IMP>(MDKSwizzledIOSurfaceRemoteRemoveSurface)
                );
            }
        }

        Class frameReceiverClass = NSClassFromString(@"CMCaptureFrameReceiver");
        if (frameReceiverClass != Nil) {
            Method frameReceiverInitMethod = class_getInstanceMethod(
                frameReceiverClass,
                sel_registerName("initWithFrameSenderServerEndpoint:frameReceiverHandler:")
            );
            if (frameReceiverInitMethod != nullptr) {
                MDKOriginalFrameReceiverInit =
                    reinterpret_cast<MDKFrameReceiverInitFn>(method_getImplementation(frameReceiverInitMethod));
                method_setImplementation(
                    frameReceiverInitMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFrameReceiverInit)
                );
            }
        }

        Class bwRemoteQueueSinkNodeClass = NSClassFromString(@"BWRemoteQueueSinkNode");
        if (bwRemoteQueueSinkNodeClass != Nil) {
            Method renderSampleBufferMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("renderSampleBuffer:forInput:")
            );
            if (renderSampleBufferMethod != nullptr) {
                MDKOriginalBWRenderSampleBuffer =
                    reinterpret_cast<MDKBWRenderSampleBufferFn>(method_getImplementation(renderSampleBufferMethod));
                method_setImplementation(
                    renderSampleBufferMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWRenderSampleBuffer)
                );
            }

            Method handleDroppedSampleMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("handleDroppedSample:forInput:")
            );
            if (handleDroppedSampleMethod != nullptr) {
                MDKOriginalBWHandleDroppedSample =
                    reinterpret_cast<MDKBWHandleDroppedSampleFn>(method_getImplementation(handleDroppedSampleMethod));
                method_setImplementation(
                    handleDroppedSampleMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWHandleDroppedSample)
                );
            }
        }

        Class figCaptureRemoteQueueSinkPipelineClass = NSClassFromString(@"FigCaptureRemoteQueueSinkPipeline");
        if (figCaptureRemoteQueueSinkPipelineClass != Nil) {
            Method setSinkNodeMethod = class_getInstanceMethod(
                figCaptureRemoteQueueSinkPipelineClass,
                sel_registerName("setSinkNode:")
            );
            if (setSinkNodeMethod != nullptr) {
                MDKOriginalFigSetSinkNode =
                    reinterpret_cast<MDKFigSetSinkNodeFn>(method_getImplementation(setSinkNodeMethod));
                method_setImplementation(
                    setSinkNodeMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFigSetSinkNode)
                );
            }
        }

        Class scRemoteQueueXPCObjectClass = NSClassFromString(@"SCRemoteQueueXPCObject");
        if (scRemoteQueueXPCObjectClass != Nil) {
            Method setRemoteQueueMethod = class_getInstanceMethod(
                scRemoteQueueXPCObjectClass,
                sel_registerName("setRemoteQueue:")
            );
            if (setRemoteQueueMethod != nullptr) {
                MDKOriginalSCRemoteQueueSetRemoteQueue =
                    reinterpret_cast<MDKSCRemoteQueueSetRemoteQueueFn>(method_getImplementation(setRemoteQueueMethod));
                method_setImplementation(
                    setRemoteQueueMethod,
                    reinterpret_cast<IMP>(MDKSwizzledSCRemoteQueueSetRemoteQueue)
                );
            }

            Method setQueueTypeMethod = class_getInstanceMethod(
                scRemoteQueueXPCObjectClass,
                sel_registerName("setQueueType:")
            );
            if (setQueueTypeMethod != nullptr) {
                MDKOriginalSCRemoteQueueSetQueueType =
                    reinterpret_cast<MDKSCRemoteQueueSetQueueTypeFn>(method_getImplementation(setQueueTypeMethod));
                method_setImplementation(
                    setQueueTypeMethod,
                    reinterpret_cast<IMP>(MDKSwizzledSCRemoteQueueSetQueueType)
                );
            }
        }
    });
}

static void MDKAttemptFigRemoteQueueReceiverProbeForCapturedVideoQueue(NSTimeInterval timeout) {
    using MDKFigRemoteQueueReceiverDequeueFn = int (*)(void *, MDKFigRemoteQueueMessage *);
    using MDKFigRemoteQueueReceiverUnsetHandlerFn = int (*)(void *);
    auto dequeueSymbol = reinterpret_cast<MDKFigRemoteQueueReceiverDequeueFn>(
        MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverDequeue")
    );
    auto unsetHandlerSymbol = reinterpret_cast<MDKFigRemoteQueueReceiverUnsetHandlerFn>(
        MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverUnsetHandler")
    );
    NSMutableDictionary<NSString *, id> *probeState = nil;
    void *receiver = nullptr;
    dispatch_semaphore_t callbackSemaphore = nil;
    long waitResult = -1;
    @synchronized(MDKActiveSCKTraceLock) {
        probeState = [MDKActiveFigRemoteQueueReceiverState mutableCopy];
        receiver = MDKActiveFigRemoteQueueReceiver;
        callbackSemaphore = MDKActiveFigRemoteQueueReceiverSemaphore;
    }

    if (probeState == nil) {
        probeState = [@{
            @"createStatus": @(-1),
            @"handlerStatus": @(-1),
            @"receiverCreated": @NO,
            @"callbackCount": @0,
            @"notes": @[
                @"The direct FigRemoteQueueReceiver probe never primed, so no early video queue attach happened."
            ],
        } mutableCopy];
    }

    const int createStatus = [probeState[@"createStatus"] intValue];
    const int handlerStatus = [probeState[@"handlerStatus"] intValue];
    int dequeueStatus = -1;
    NSDictionary<NSString *, id> *dequeuedSampleSummary = nil;
    if (createStatus == 0 && handlerStatus == 0 && receiver != nullptr && callbackSemaphore != nil) {
        const uint64_t deadlineNanos = MDKCurrentTraceTimestampNanos() + static_cast<uint64_t>(timeout * NSEC_PER_SEC);
        while (MDKCurrentTraceTimestampNanos() < deadlineNanos) {
            const uint64_t remainingNanos = deadlineNanos - MDKCurrentTraceTimestampNanos();
            const int64_t sliceNanos = static_cast<int64_t>(std::min<uint64_t>(remainingNanos, 50 * NSEC_PER_MSEC));
            waitResult = dispatch_semaphore_wait(
                callbackSemaphore,
                dispatch_time(DISPATCH_TIME_NOW, sliceNanos)
            );
        }

        if (dequeueSymbol != nullptr && [probeState[@"callbackCount"] unsignedIntegerValue] == 0) {
            MDKFigRemoteQueueMessage item = {};
            dequeueStatus = dequeueSymbol(receiver, &item);
            if (item.surface != nil) {
                dequeuedSampleSummary = MDKSummarizeIOSurface(item.surface);
                CFRelease(item.surface);
            }
        }

        if (unsetHandlerSymbol != nullptr) {
            unsetHandlerSymbol(receiver);
        }

        @synchronized(MDKActiveSCKTraceLock) {
            if (MDKActiveFigRemoteQueueReceiverState != nil) {
                probeState = [MDKActiveFigRemoteQueueReceiverState mutableCopy];
            }
        }
    }

    NSDictionary<NSString *, NSNumber *> *callbackDeltaHistogram =
        [probeState[@"callbackDeltaHistogram"] isKindOfClass:[NSDictionary class]] ? probeState[@"callbackDeltaHistogram"] : nil;
    const NSUInteger callbackDeltaCount = [probeState[@"callbackDeltaCount"] unsignedIntegerValue];
    NSNumber *callback120HzEquivalentCount = @(MDKHistogramCountInRange(callbackDeltaHistogram, 0.0, 10.0));
    NSString *callbackCadenceClassification = MDKClassifyCadenceHistogram(callbackDeltaHistogram, callbackDeltaCount);

    MDKRecordSCKTraceEvent(
        @"fig-remote-queue-receiver-probe",
        @{
            @"capturedRemoteQueueCount": @(MDKCapturedSCKRemoteQueueCount()),
            @"createStatus": @(createStatus),
            @"handlerStatus": @(handlerStatus),
            @"callbackCount": probeState[@"callbackCount"] ?: @0,
            @"callbackObserved": @([probeState[@"callbackCount"] unsignedIntegerValue] > 0),
            @"callbackTimestampNanos": probeState[@"callbackTimestampNanos"] ?: [NSNull null],
            @"callbackDeltaCount": @(callbackDeltaCount),
            @"callbackDeltaHistogram": callbackDeltaHistogram ?: @{},
            @"callback120HzEquivalentCount": callback120HzEquivalentCount,
            @"callbackCadenceClassification": callbackCadenceClassification ?: [NSNull null],
            @"receiverCreated": @(receiver != nullptr),
            @"waitTimedOut": @(waitResult != 0),
            @"dequeueStatus": @(dequeueStatus),
            @"dequeuedSample": dequeuedSampleSummary ?: [NSNull null],
            @"remoteQueue": probeState[@"remoteQueue"] ?: [NSNull null],
            @"notes": @[
                @"Primes FigRemoteQueueReceiver on the first captured ScreenCaptureKit remote queue before SCStream consumes its IOSurface receiver right.",
                [NSString stringWithFormat:@"unsetHandlerSymbolPresent=%@", unsetHandlerSymbol != nullptr ? @"true" : @"false"],
                [NSString stringWithFormat:@"dequeueSymbolPresent=%@", dequeueSymbol != nullptr ? @"true" : @"false"],
                [NSString stringWithFormat:@"createSymbolPresent=%@", [probeState[@"createSymbolPresent"] boolValue] ? @"true" : @"false"],
                [NSString stringWithFormat:@"setHandlerSymbolPresent=%@", [probeState[@"setHandlerSymbolPresent"] boolValue] ? @"true" : @"false"],
            ],
        }
    );
}

static void MDKAttemptSCRemoteQueueWrapperProbeForCapturedVideoQueue(NSTimeInterval timeout) {
    using MDKSCRemoteQueueCreateReceiverQueueFn = BOOL (*)(xpc_object_t, id, dispatch_queue_t, void **);
    using MDKSCRemoteQueueUpdateReceiverQueueFn = BOOL (*)(void *, dispatch_queue_t);
    using MDKSCRemoteQueueDestroyFn = void (*)(void **);
    auto updateSymbol = reinterpret_cast<MDKSCRemoteQueueUpdateReceiverQueueFn>(
        MDKLookupScreenCaptureKitSymbol("SCRemoteQueue_UpdateReceiverQueue")
    );
    auto destroySymbol = reinterpret_cast<MDKSCRemoteQueueDestroyFn>(
        MDKLookupScreenCaptureKitSymbol("SCRemoteQueue_Destroy")
    );

    NSMutableDictionary<NSString *, id> *probeState = nil;
    void *receiverQueue = nullptr;
    dispatch_queue_t wrapperQueue = nil;
    dispatch_semaphore_t callbackSemaphore = nil;
    long waitResult = -1;
    BOOL updateStatus = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        probeState = [MDKActiveSCRemoteQueueWrapperState mutableCopy];
        receiverQueue = MDKActiveSCRemoteQueueWrapper;
        wrapperQueue = MDKActiveSCRemoteQueueWrapperQueue;
        callbackSemaphore = MDKActiveSCRemoteQueueWrapperSemaphore;
    }

    if (probeState == nil) {
        probeState = [@{
            @"createStatus": @NO,
            @"wrapperCreated": @NO,
            @"callbackCount": @0,
            @"notes": @[
                @"The ScreenCaptureKit remote queue wrapper probe never primed, so no early wrapper attach happened."
            ],
        } mutableCopy];
    }

    const BOOL createStatus = [probeState[@"createStatus"] boolValue];
    if (createStatus && receiverQueue != nullptr && wrapperQueue != nil && updateSymbol != nullptr) {
        updateStatus = updateSymbol(receiverQueue, wrapperQueue);
    }

    if (createStatus && receiverQueue != nullptr && callbackSemaphore != nil) {
        const uint64_t deadlineNanos = MDKCurrentTraceTimestampNanos() + static_cast<uint64_t>(timeout * NSEC_PER_SEC);
        while (MDKCurrentTraceTimestampNanos() < deadlineNanos) {
            const uint64_t remainingNanos = deadlineNanos - MDKCurrentTraceTimestampNanos();
            const int64_t sliceNanos = static_cast<int64_t>(std::min<uint64_t>(remainingNanos, 50 * NSEC_PER_MSEC));
            waitResult = dispatch_semaphore_wait(
                callbackSemaphore,
                dispatch_time(DISPATCH_TIME_NOW, sliceNanos)
            );
        }

        @synchronized(MDKActiveSCKTraceLock) {
            if (MDKActiveSCRemoteQueueWrapperState != nil) {
                probeState = [MDKActiveSCRemoteQueueWrapperState mutableCopy];
            }
        }
    }
    NSDictionary<NSString *, NSNumber *> *callbackDeltaHistogram =
        [probeState[@"callbackDeltaHistogram"] isKindOfClass:[NSDictionary class]] ? probeState[@"callbackDeltaHistogram"] : nil;
    const NSUInteger callbackDeltaCount = [probeState[@"callbackDeltaCount"] unsignedIntegerValue];
    NSNumber *callback120HzEquivalentCount = @(MDKHistogramCountInRange(callbackDeltaHistogram, 0.0, 10.0));
    NSString *callbackCadenceClassification = MDKClassifyCadenceHistogram(callbackDeltaHistogram, callbackDeltaCount);

    MDKRecordSCKTraceEvent(
        @"sc-remote-queue-wrapper-probe",
        @{
            @"capturedRemoteQueueCount": @(MDKCapturedSCKRemoteQueueCount()),
            @"createStatus": @(createStatus),
            @"wrapperCreated": @(receiverQueue != nullptr),
            @"callbackCount": probeState[@"callbackCount"] ?: @0,
            @"callbackObserved": @([probeState[@"callbackCount"] unsignedIntegerValue] > 0),
            @"callbackStatus": probeState[@"callbackStatus"] ?: [NSNull null],
            @"callbackTimestampNanos": probeState[@"callbackTimestampNanos"] ?: [NSNull null],
            @"callbackDeltaCount": @(callbackDeltaCount),
            @"callbackDeltaHistogram": callbackDeltaHistogram ?: @{},
            @"callback120HzEquivalentCount": callback120HzEquivalentCount,
            @"callbackCadenceClassification": callbackCadenceClassification ?: [NSNull null],
            @"callbackMessageType": probeState[@"callbackMessageType"] ?: [NSNull null],
            @"callbackSurface": probeState[@"callbackSurface"] ?: [NSNull null],
            @"waitTimedOut": @(waitResult != 0),
            @"updateSymbolPresent": @(updateSymbol != nullptr),
            @"updateStatus": @(updateStatus),
            @"destroySymbolPresent": @(destroySymbol != nullptr),
            @"remoteQueue": probeState[@"remoteQueue"] ?: [NSNull null],
            @"usedPreferredSampleHandlerQueue": probeState[@"usedPreferredSampleHandlerQueue"] ?: @NO,
            @"preferredSampleHandlerQueueLabel": probeState[@"preferredSampleHandlerQueueLabel"] ?: [NSNull null],
            @"notes": @[
                @"Primes SCRemoteQueue_CreateReceiverQueue on the first captured ScreenCaptureKit remote queue before SCStream consumes the queue.",
                @"Uses the private ScreenCaptureKit wrapper instead of a raw FigRemoteQueueReceiver."
            ],
        }
    );

    if (destroySymbol != nullptr && receiverQueue != nullptr) {
        destroySymbol(&receiverQueue);
    }

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCRemoteQueueWrapper = nullptr;
        MDKActiveSCRemoteQueueWrapperQueue = nil;
        MDKActiveSCRemoteQueueWrapperSemaphore = nil;
    }
}

static void MDKRunCurrentRunLoopForDuration(NSTimeInterval duration) {
    if (duration <= 0) {
        return;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    while ([deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            NSDate *sliceDeadline = [NSDate dateWithTimeIntervalSinceNow:0.01];
            BOOL handledDefault = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:sliceDeadline];
            BOOL handledCommon = [[NSRunLoop currentRunLoop] runMode:NSRunLoopCommonModes beforeDate:sliceDeadline];
            if (!handledDefault && !handledCommon) {
                usleep(1'000);
            }
        }
    }
}

static NSDictionary<NSString *, id> * _Nullable MDKCreateSCKProxyHandshakeTrace(
    NSUInteger displayID,
    NSTimeInterval timeout,
    BOOL includePrivateQueueProbes,
    NSError * _Nullable * _Nullable error
) {
    if (!CGPreflightScreenCaptureAccess()) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:7
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Screen capture access is not authorized for the public ScreenCaptureKit handshake trace."
                                     }];
        }
        return nil;
    }

    if (timeout <= 0) {
        timeout = 2.0;
    }

    MDKInstallSCKProxyTraceHooks();
    if (MDKOriginalProxyCoreGraphics == nullptr ||
        MDKOriginalStartRemoteQueue == nullptr ||
        MDKOriginalStartCaptureProxy == nullptr) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:8
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to install RPDaemonProxy trace hooks."
                                     }];
        }
        return nil;
    }

    Class shareableContentClass = NSClassFromString(@"SCShareableContent");
    Class filterClass = NSClassFromString(@"SCContentFilter");
    Class configClass = NSClassFromString(@"SCStreamConfiguration");
    Class streamClass = NSClassFromString(@"SCStream");
    if (shareableContentClass == Nil || filterClass == Nil || configClass == Nil || streamClass == Nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:9
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Required ScreenCaptureKit classes are unavailable."
                                     }];
        }
        return nil;
    }

    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(static_cast<CGDirectDisplayID>(displayID));
    if (mode == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:10
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to resolve the current display mode for the ScreenCaptureKit handshake trace."
                                     }];
        }
        return nil;
    }

    const NSUInteger width = std::max(static_cast<NSUInteger>(CGDisplayModeGetPixelWidth(mode)), static_cast<NSUInteger>(1));
    const NSUInteger height = std::max(static_cast<NSUInteger>(CGDisplayModeGetPixelHeight(mode)), static_cast<NSUInteger>(1));
    CFRelease(mode);

    MDKResetSCKTraceState(displayID, timeout);
    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKAllowPrivateQueueProbes = includePrivateQueueProbes;
    }
    MDKAppendSCKTraceNote([NSString stringWithFormat:@"class.BWRemoteQueueSinkNode.present=%@", NSClassFromString(@"BWRemoteQueueSinkNode") != Nil ? @"true" : @"false"]);
    MDKAppendSCKTraceNote([NSString stringWithFormat:@"class.BWRemoteQueueSinkNode.renderSampleBuffer:forInput:=%@", class_getInstanceMethod(NSClassFromString(@"BWRemoteQueueSinkNode"), sel_registerName("renderSampleBuffer:forInput:")) != nullptr ? @"true" : @"false"]);
    MDKAppendSCKTraceNote([NSString stringWithFormat:@"class.BWRemoteQueueSinkNode.handleDroppedSample:forInput:=%@", class_getInstanceMethod(NSClassFromString(@"BWRemoteQueueSinkNode"), sel_registerName("handleDroppedSample:forInput:")) != nullptr ? @"true" : @"false"]);
    MDKAppendSCKTraceNote([NSString stringWithFormat:@"class.FigCaptureRemoteQueueSinkPipeline.present=%@", NSClassFromString(@"FigCaptureRemoteQueueSinkPipeline") != Nil ? @"true" : @"false"]);
    MDKAppendSCKTraceNote([NSString stringWithFormat:@"class.FigCaptureRemoteQueueSinkPipeline.setSinkNode:=%@", class_getInstanceMethod(NSClassFromString(@"FigCaptureRemoteQueueSinkPipeline"), sel_registerName("setSinkNode:")) != nullptr ? @"true" : @"false"]);
    MDKAppendSCKTraceNote([NSString stringWithFormat:@"class.SCRemoteQueueXPCObject.present=%@", NSClassFromString(@"SCRemoteQueueXPCObject") != Nil ? @"true" : @"false"]);

    __block id display = nil;
    __block NSError *shareableContentError = nil;
    if ([shareableContentClass respondsToSelector:sel_registerName("getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:")]) {
        dispatch_semaphore_t shareableContentCompletion = dispatch_semaphore_create(0);
        ((void (*)(id, SEL, BOOL, BOOL, id)) objc_msgSend)(
            shareableContentClass,
            sel_registerName("getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:"),
            NO,
            YES,
            ^(id _Nullable shareableContent, NSError * _Nullable completionError) {
                shareableContentError = completionError;
                if (shareableContent != nil && [shareableContent respondsToSelector:sel_registerName("displays")]) {
                    NSArray *displays = ((id (*)(id, SEL)) objc_msgSend)(shareableContent, sel_registerName("displays"));
                    for (id candidate in displays) {
                        if (![candidate respondsToSelector:sel_registerName("displayID")]) {
                            continue;
                        }

                        unsigned int candidateDisplayID = ((unsigned int (*)(id, SEL)) objc_msgSend)(
                            candidate,
                            sel_registerName("displayID")
                        );
                        if (candidateDisplayID == static_cast<unsigned int>(displayID)) {
                            display = candidate;
                            break;
                        }
                    }
                }
                dispatch_semaphore_signal(shareableContentCompletion);
            }
        );

        dispatch_semaphore_wait(
            shareableContentCompletion,
            dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeout * NSEC_PER_SEC))
        );
    }

    if (display == nil && [shareableContentClass respondsToSelector:sel_registerName("getDisplayForDisplayId:")]) {
        display = ((id (*)(id, SEL, unsigned int)) objc_msgSend)(
            shareableContentClass,
            sel_registerName("getDisplayForDisplayId:"),
            static_cast<unsigned int>(displayID)
        );
    }

    if (display == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:11
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: shareableContentError.localizedDescription ?: @"Unable to resolve an SCDisplay for the handshake trace."
                                     }];
        }
        return nil;
    }

    id filter = ((id (*)(id, SEL, id, id, id)) objc_msgSend)(
        ((id (*)(id, SEL)) objc_msgSend)(filterClass, sel_registerName("alloc")),
        sel_registerName("initWithDisplay:excludingApplications:exceptingWindows:"),
        display,
        @[],
        @[]
    );
    if (filter == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:12
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to create an SCContentFilter for the handshake trace."
                                     }];
        }
        return nil;
    }

    id configuration = ((id (*)(id, SEL)) objc_msgSend)(
        ((id (*)(id, SEL)) objc_msgSend)(configClass, sel_registerName("alloc")),
        sel_registerName("init")
    );
    ((void (*)(id, SEL, NSUInteger)) objc_msgSend)(configuration, sel_registerName("setWidth:"), width);
    ((void (*)(id, SEL, NSUInteger)) objc_msgSend)(configuration, sel_registerName("setHeight:"), height);
    ((void (*)(id, SEL, NSInteger)) objc_msgSend)(configuration, sel_registerName("setQueueDepth:"), 3);
    ((void (*)(id, SEL, BOOL)) objc_msgSend)(configuration, sel_registerName("setShowsCursor:"), NO);
    ((void (*)(id, SEL, unsigned int)) objc_msgSend)(configuration, sel_registerName("setPixelFormat:"), kCVPixelFormatType_32BGRA);
    const CMTime frameInterval = CMTimeMake(1, 60);
    ((void (*)(id, SEL, CMTime)) objc_msgSend)(configuration, sel_registerName("setMinimumFrameInterval:"), frameInterval);

    id stream = ((id (*)(id, SEL, id, id, id)) objc_msgSend)(
        ((id (*)(id, SEL)) objc_msgSend)(streamClass, sel_registerName("alloc")),
        sel_registerName("initWithFilter:configuration:delegate:"),
        filter,
        configuration,
        nil
    );
    if (stream == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:13
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to create an SCStream for the handshake trace."
                                     }];
        }
        return nil;
    }

    MDKRecordSCKTraceEvent(
        @"initial-state",
        @{
            @"contentFilter": MDKSummarizeObject(filter),
            @"display": MDKSummarizeObject(display),
            @"configuration": MDKSummarizeObject(configuration),
            @"stream": MDKSummarizeObject(stream),
            @"streamState": MDKCopySCStreamInternalState(stream),
        }
    );

    dispatch_queue_t sampleQueue = dispatch_queue_create("com.skyline23.MacDisplayKit.sck-proxy-trace", DISPATCH_QUEUE_SERIAL);
    id outputCollector = [[MDKShimStreamOutputCollector alloc] init];
    NSError *outputError = nil;
    const BOOL addedOutput = ((BOOL (*)(id, SEL, id, NSInteger, id, NSError **)) objc_msgSend)(
        stream,
        sel_registerName("addStreamOutput:type:sampleHandlerQueue:error:"),
        outputCollector,
        0,
        sampleQueue,
        &outputError
    );
    MDKRecordSCKTraceEvent(
        @"add-stream-output",
        @{
            @"outputAdded": @(addedOutput),
            @"errorDomain": outputError.domain ?: [NSNull null],
            @"errorCode": @(outputError.code),
            @"streamState": MDKCopySCStreamInternalState(stream),
        }
    );
    if (!addedOutput) {
        if (error != nullptr) {
            *error = outputError ?: [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                                        code:14
                                                    userInfo:@{
                                                        NSLocalizedDescriptionKey: @"Unable to add a screen stream output before tracing RPDaemonProxy."
                                                    }];
        }
        return nil;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKScreenSampleHandlerQueue =
            reinterpret_cast<dispatch_queue_t>(MDKCopyObjectIvar(stream, "_screenSampleHandlerQueue"));
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"screenSampleHandlerQueueCaptured"] = @(MDKActiveSCKScreenSampleHandlerQueue != nil);
            if (MDKActiveSCKScreenSampleHandlerQueue != nil) {
                MDKActiveSCKTraceState[@"screenSampleHandlerQueueLabel"] =
                    [NSString stringWithUTF8String:dispatch_queue_get_label(MDKActiveSCKScreenSampleHandlerQueue)] ?: @"";
            }
        }
    }

    dispatch_semaphore_t startCompletion = dispatch_semaphore_create(0);
    __block NSError *startError = nil;
    ((void (*)(id, SEL, id)) objc_msgSend)(
        stream,
        sel_registerName("startCaptureWithCompletionHandler:"),
        ^(NSError * _Nullable completionError) {
            @synchronized(MDKActiveSCKTraceLock) {
                if (MDKActiveSCKTraceState != nil) {
                    MDKActiveSCKTraceState[@"startCaptureCompletionObserved"] = @YES;
                    MDKActiveSCKTraceState[@"startCaptureCompletionSucceeded"] = @(completionError == nil);
                    if (completionError != nil) {
                        MDKActiveSCKTraceState[@"startCaptureCompletionErrorDomain"] = completionError.domain ?: @"";
                        MDKActiveSCKTraceState[@"startCaptureCompletionErrorCode"] = @(completionError.code);
                        MDKActiveSCKTraceState[@"startCaptureCompletionErrorDescription"] =
                            completionError.localizedDescription ?: @"";
                    }
                }
            }
            startError = completionError;
            dispatch_semaphore_signal(startCompletion);
        }
    );

    dispatch_semaphore_wait(
        startCompletion,
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeout * NSEC_PER_SEC))
    );
    if (includePrivateQueueProbes) {
        usleep(250 * 1000);
        MDKRunCurrentRunLoopForDuration(std::min(timeout, 0.5));
        MDKAttemptSCRemoteQueueWrapperProbeForCapturedVideoQueue(timeout);
        MDKAttemptFigRemoteQueueReceiverProbeForCapturedVideoQueue(timeout);
    } else {
        MDKRunCurrentRunLoopForDuration(timeout);
    }

    MDKRecordSCKTraceEvent(
        @"post-start-stream-state",
        @{
            @"streamState": MDKCopySCStreamInternalState(stream),
            @"startErrorDomain": startError.domain ?: [NSNull null],
            @"startErrorCode": @(startError.code),
        }
    );

    NSDictionary<NSString *, id> *snapshot = MDKCopySCKTraceStateSnapshot();
    if (snapshot == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:15
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to snapshot the ScreenCaptureKit handshake trace."
                                     }];
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *steps = [NSMutableArray array];
    NSMutableSet<NSString *> *selectors = [NSMutableSet set];
    NSMutableSet<NSString *> *symbols = [NSMutableSet set];

    NSArray *events = snapshot[@"events"] ?: @[];
    for (NSDictionary *event in events) {
        NSString *kind = event[@"kind"] ?: @"unknown";
        if ([kind isEqualToString:@"initial-state"]) {
            [selectors addObject:@"getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:"];
            [selectors addObject:@"initWithDisplay:excludingApplications:exceptingWindows:"];
            [selectors addObject:@"initWithFilter:configuration:delegate:"];
            NSDictionary *displaySummary = event[@"display"];
            NSDictionary *streamSummary = event[@"stream"];
            NSDictionary *filterSummary = event[@"contentFilter"];
            NSDictionary *configSummary = event[@"configuration"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"display=%@", MDKDescribeTraceValue(displaySummary)],
                [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(streamSummary)],
                [NSString stringWithFormat:@"filter=%@", MDKDescribeTraceValue(filterSummary)],
                [NSString stringWithFormat:@"configuration=%@", MDKDescribeTraceValue(configSummary)],
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"initial-state",
                @"initWithFilter:configuration:delegate:",
                @"ScreenCaptureKit",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"add-stream-output"]) {
            [selectors addObject:@"addStreamOutput:type:sampleHandlerQueue:error:"];
            NSNumber *succeeded = event[@"outputAdded"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"errorDomain=%@", MDKDescribeTraceValue(event[@"errorDomain"])],
                [NSString stringWithFormat:@"errorCode=%@", MDKDescribeTraceValue(event[@"errorCode"])],
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"add-stream-output",
                @"addStreamOutput:type:sampleHandlerQueue:error:",
                @"ScreenCaptureKit",
                nil,
                succeeded,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"start-capture-proxy"]) {
            [selectors addObject:@"startCapture:withContentFilter:preservedFilter:transactionID:properties:extensionToken:completionHandler:"];
            [symbols addObject:@"RPDaemonProxy"];
            [steps addObject:MDKMakeTraceStep(
                @"start-capture-proxy",
                @"startCapture:withContentFilter:preservedFilter:transactionID:properties:extensionToken:completionHandler:",
                @"RPDaemonProxy",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(event[@"stream"])],
                    [NSString stringWithFormat:@"contentFilter=%@", MDKDescribeTraceValue(event[@"contentFilter"])],
                    [NSString stringWithFormat:@"preservedFilter=%@", MDKDescribeTraceValue(event[@"preservedFilter"])],
                    [NSString stringWithFormat:@"transactionID=%@", MDKDescribeTraceValue(event[@"transactionID"])],
                    [NSString stringWithFormat:@"properties=%@", MDKDescribeTraceValue(event[@"properties"])],
                    [NSString stringWithFormat:@"extensionToken=%@", MDKDescribeTraceValue(event[@"extensionToken"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"start-remote-queue"]) {
            [selectors addObject:@"startRemoteQueue:streamID:"];
            [symbols addObject:@"RPDaemonProxy"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
                [NSString stringWithFormat:@"streamID=%@", MDKDescribeTraceValue(event[@"streamID"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"start-remote-queue",
                @"startRemoteQueue:streamID:",
                @"RPDaemonProxy",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"proxy-core-graphics"]) {
            [selectors addObject:@"proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:"];
            [symbols addObject:@"RPDaemonProxy"];
            [steps addObject:MDKMakeTraceStep(
                @"proxy-core-graphics",
                @"proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:",
                @"RPDaemonProxy",
                event[@"methodType"],
                @YES,
                @[
                    [NSString stringWithFormat:@"config=%@", MDKDescribeTraceValue(event[@"config"])],
                    [NSString stringWithFormat:@"machPort=%@", MDKDescribeTraceValue(event[@"machPort"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"fetch-display"]) {
            [selectors addObject:@"fetchDisplay:withCompletionHandler:"];
            [symbols addObject:@"RPDaemonProxy"];
            [steps addObject:MDKMakeTraceStep(
                @"fetch-display",
                @"fetchDisplay:withCompletionHandler:",
                @"RPDaemonProxy",
                event[@"displayID"],
                @YES,
                @[
                    [NSString stringWithFormat:@"completionHandler=%@", MDKDescribeTraceValue(event[@"completionHandler"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"update-stream-configuration"]) {
            [selectors addObject:@"updateStream:withStreamConfiguration:transactionID:streamData:completionHandler:"];
            [symbols addObject:@"RPDaemonProxy"];
            [steps addObject:MDKMakeTraceStep(
                @"update-stream-configuration",
                @"updateStream:withStreamConfiguration:transactionID:streamData:completionHandler:",
                @"RPDaemonProxy",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(event[@"stream"])],
                    [NSString stringWithFormat:@"configuration=%@", MDKDescribeTraceValue(event[@"configuration"])],
                    [NSString stringWithFormat:@"transactionID=%@", MDKDescribeTraceValue(event[@"transactionID"])],
                    [NSString stringWithFormat:@"streamData=%@", MDKDescribeTraceValue(event[@"streamData"])],
                    [NSString stringWithFormat:@"completionHandler=%@", MDKDescribeTraceValue(event[@"completionHandler"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"update-stream-content-filter"]) {
            [selectors addObject:@"updateStream:withContentFilter:preservedContentFilter:transactionID:streamData:completionHandler:"];
            [symbols addObject:@"RPDaemonProxy"];
            [steps addObject:MDKMakeTraceStep(
                @"update-stream-content-filter",
                @"updateStream:withContentFilter:preservedContentFilter:transactionID:streamData:completionHandler:",
                @"RPDaemonProxy",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(event[@"stream"])],
                    [NSString stringWithFormat:@"contentFilter=%@", MDKDescribeTraceValue(event[@"contentFilter"])],
                    [NSString stringWithFormat:@"preservedContentFilter=%@", MDKDescribeTraceValue(event[@"preservedContentFilter"])],
                    [NSString stringWithFormat:@"transactionID=%@", MDKDescribeTraceValue(event[@"transactionID"])],
                    [NSString stringWithFormat:@"streamData=%@", MDKDescribeTraceValue(event[@"streamData"])],
                    [NSString stringWithFormat:@"completionHandler=%@", MDKDescribeTraceValue(event[@"completionHandler"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-did-start"]) {
            [selectors addObject:@"streamDidStartWithConfiguration:contentFilter:"];
            [symbols addObject:@"RPDaemonProxy"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"configuration=%@", MDKDescribeTraceValue(event[@"configuration"])],
                [NSString stringWithFormat:@"contentFilter=%@", MDKDescribeTraceValue(event[@"contentFilter"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"stream-did-start",
                @"streamDidStartWithConfiguration:contentFilter:",
                @"RPDaemonProxy",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-output-effect-did-start"]) {
            [selectors addObject:@"streamOutputEffectDidStart:withStreamID:"];
            [symbols addObject:@"RPDaemonProxy"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"started=%@", MDKDescribeTraceValue(event[@"started"])],
                [NSString stringWithFormat:@"streamID=%@", MDKDescribeTraceValue(event[@"streamID"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"stream-output-effect-did-start",
                @"streamOutputEffectDidStart:withStreamID:",
                @"RPDaemonProxy",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"manager-start-remote-queue"]) {
            [selectors addObject:@"startRemoteQueue:streamID:"];
            [symbols addObject:@"SCStreamManager"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
                [NSString stringWithFormat:@"streamID=%@", MDKDescribeTraceValue(event[@"streamID"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"manager-start-remote-queue",
                @"startRemoteQueue:streamID:",
                @"SCStreamManager",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"manager-update-stream-client-output-type"]) {
            [selectors addObject:@"updateStream:withClientOutputType:"];
            [symbols addObject:@"SCStreamManager"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(event[@"stream"])],
                [NSString stringWithFormat:@"clientOutputType=%@", MDKDescribeTraceValue(event[@"clientOutputType"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"manager-update-stream-client-output-type",
                @"updateStream:withClientOutputType:",
                @"SCStreamManager",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"manager-stream-update-filter"]) {
            [selectors addObject:@"stream:updateWithFilter:"];
            [symbols addObject:@"SCStreamManager"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(event[@"stream"])],
                [NSString stringWithFormat:@"filter=%@", MDKDescribeTraceValue(event[@"filter"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"manager-stream-update-filter",
                @"stream:updateWithFilter:",
                @"SCStreamManager",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"manager-stream-did-request-update-filter"]) {
            [selectors addObject:@"stream:didRequestUpdateFilter:"];
            [symbols addObject:@"SCStreamManager"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(event[@"stream"])],
                [NSString stringWithFormat:@"filter=%@", MDKDescribeTraceValue(event[@"filter"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"manager-stream-did-request-update-filter",
                @"stream:didRequestUpdateFilter:",
                @"SCStreamManager",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"manager-stream-output-effect-did-start"]) {
            [selectors addObject:@"streamOutputEffectDidStart:withStreamID:"];
            [symbols addObject:@"SCStreamManager"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"started=%@", MDKDescribeTraceValue(event[@"started"])],
                [NSString stringWithFormat:@"streamID=%@", MDKDescribeTraceValue(event[@"streamID"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"manager-stream-output-effect-did-start",
                @"streamOutputEffectDidStart:withStreamID:",
                @"SCStreamManager",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-start-remote-receive-queue"]) {
            [selectors addObject:@"startRemoteReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-receive-queue",
                @"startRemoteReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-start-remote-video-receive-queue"]) {
            [selectors addObject:@"startRemoteVideoReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-video-receive-queue",
                @"startRemoteVideoReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-start-remote-audio-receive-queue"]) {
            [selectors addObject:@"startRemoteAudioReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-audio-receive-queue",
                @"startRemoteAudioReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-start-remote-microphone-receive-queue"]) {
            [selectors addObject:@"startRemoteMicrophoneReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-microphone-receive-queue",
                @"startRemoteMicrophoneReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"collect-stream-data"]) {
            [selectors addObject:@"collectStreamData"];
            [symbols addObject:@"SCStream"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"collect-stream-data",
                @"collectStreamData",
                @"SCStream",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-output-sample-buffer"]) {
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"type=%@", MDKDescribeTraceValue(event[@"type"])],
                [NSString stringWithFormat:@"sampleBuffer=%@", MDKDescribeTraceValue(event[@"sampleBuffer"])],
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"stream-output-sample-buffer",
                @"stream:didOutputSampleBuffer:ofType:",
                @"SCStreamOutput",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"daemon-capture-handler-sample"] ||
            [kind isEqualToString:@"screen-recorder-capture-handler-sample"]) {
            NSString *selector = @"captureHandlerWithSample:timingData:";
            NSString *symbol = [kind isEqualToString:@"daemon-capture-handler-sample"] ? @"RPDaemonProxy" : @"RPScreenRecorder";
            [selectors addObject:selector];
            [symbols addObject:symbol];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"sample=%@", MDKDescribeTraceValue(event[@"sample"])],
                [NSString stringWithFormat:@"timingData=%@", MDKDescribeTraceValue(event[@"timingData"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
                selector,
                symbol,
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"ca-content-stream-produce-surface"] ||
            [kind isEqualToString:@"ca-content-stream-release-surface"] ||
            [kind isEqualToString:@"ca-content-stream-release-surface-id"]) {
            NSString *selector = nil;
            if ([kind isEqualToString:@"ca-content-stream-produce-surface"]) {
                selector = @"produceSurface:withFrameInfo:";
            } else if ([kind isEqualToString:@"ca-content-stream-release-surface"]) {
                selector = @"releaseSurface:error:";
            } else {
                selector = @"releaseSurfaceWithId:error:";
            }
            [selectors addObject:selector];
            [symbols addObject:@"CAContentStream"];
            NSMutableArray<NSString *> *notes = [NSMutableArray array];
            if (event[@"surfaceID"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"surfaceID=%@", MDKDescribeTraceValue(event[@"surfaceID"])]];
            }
            if (event[@"frameInfo"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"frameInfo=%@", MDKDescribeTraceValue(event[@"frameInfo"])]];
            }
            if (event[@"surface"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"surface=%@", MDKDescribeTraceValue(event[@"surface"])]];
            }
            if (event[@"released"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"released=%@", MDKDescribeTraceValue(event[@"released"])]];
            }
            if (event[@"errorDomain"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"errorDomain=%@", MDKDescribeTraceValue(event[@"errorDomain"])]];
            }
            if (event[@"errorCode"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"errorCode=%@", MDKDescribeTraceValue(event[@"errorCode"])]];
            }
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
                selector,
                @"CAContentStream",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"iosurface-remote-add-surface"] ||
            [kind isEqualToString:@"iosurface-remote-set-surface-states"] ||
            [kind isEqualToString:@"iosurface-remote-remove-surface"]) {
            NSString *selector = nil;
            if ([kind isEqualToString:@"iosurface-remote-add-surface"]) {
                selector = @"_addSurface:mappedAddress:mappedSize:extraData:";
            } else if ([kind isEqualToString:@"iosurface-remote-set-surface-states"]) {
                selector = @"setSurfaceStates:";
            } else {
                selector = @"_removeSurface:";
            }
            [selectors addObject:selector];
            [symbols addObject:@"IOSurfaceRemoteRemoteClient"];
            NSMutableArray<NSString *> *notes = [NSMutableArray array];
            if (event[@"surfaceClient"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"surfaceClient=%@", MDKDescribeTraceValue(event[@"surfaceClient"])]];
            }
            if (event[@"mappedAddress"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"mappedAddress=%@", MDKDescribeTraceValue(event[@"mappedAddress"])]];
            }
            if (event[@"mappedSize"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"mappedSize=%@", MDKDescribeTraceValue(event[@"mappedSize"])]];
            }
            if (event[@"extraData"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"extraData=%@", MDKDescribeTraceValue(event[@"extraData"])]];
            }
            if (event[@"surfaceStates"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"surfaceStates=%@", MDKDescribeTraceValue(event[@"surfaceStates"])]];
            }
            if (event[@"surfaceID"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"surfaceID=%@", MDKDescribeTraceValue(event[@"surfaceID"])]];
            }
            if (event[@"removed"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"removed=%@", MDKDescribeTraceValue(event[@"removed"])]];
            }
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
                selector,
                @"IOSurfaceRemoteRemoteClient",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"frame-receiver-init"]) {
            [selectors addObject:@"initWithFrameSenderServerEndpoint:frameReceiverHandler:"];
            [symbols addObject:@"CMCaptureFrameReceiver"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"endpoint=%@", MDKDescribeTraceValue(event[@"endpoint"])],
                [NSString stringWithFormat:@"handler=%@", MDKDescribeTraceValue(event[@"handler"])],
                [NSString stringWithFormat:@"handlerBlockSignature=%@", MDKDescribeTraceValue(event[@"handlerBlockSignature"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"frame-receiver-init",
                @"initWithFrameSenderServerEndpoint:frameReceiverHandler:",
                @"CMCaptureFrameReceiver",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"bw-remote-queue-render"] || [kind isEqualToString:@"bw-remote-queue-drop"]) {
            NSString *selector = [kind isEqualToString:@"bw-remote-queue-render"] ? @"renderSampleBuffer:forInput:" : @"handleDroppedSample:forInput:";
            [selectors addObject:selector];
            [symbols addObject:@"BWRemoteQueueSinkNode"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"sinkNode=%@", MDKDescribeTraceValue(event[@"sinkNode"])],
                [NSString stringWithFormat:@"input=%@", MDKDescribeTraceValue(event[@"input"])],
            ] mutableCopy];
            if ([kind isEqualToString:@"bw-remote-queue-render"]) {
                [notes addObject:[NSString stringWithFormat:@"sampleBuffer=%@", MDKDescribeTraceValue(event[@"sampleBuffer"])]];
            } else {
                [notes addObject:[NSString stringWithFormat:@"sample=%@", MDKDescribeTraceValue(event[@"sample"])]];
            }
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
                selector,
                @"BWRemoteQueueSinkNode",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"fig-remote-queue-set-sink"]) {
            [selectors addObject:@"setSinkNode:"];
            [symbols addObject:@"FigCaptureRemoteQueueSinkPipeline"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"pipeline=%@", MDKDescribeTraceValue(event[@"pipeline"])],
                [NSString stringWithFormat:@"sinkNode=%@", MDKDescribeTraceValue(event[@"sinkNode"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"fig-remote-queue-set-sink",
                @"setSinkNode:",
                @"FigCaptureRemoteQueueSinkPipeline",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"sc-remote-queue-set-remote-queue"] ||
            [kind isEqualToString:@"sc-remote-queue-set-queue-type"]) {
            NSString *selector = [kind isEqualToString:@"sc-remote-queue-set-remote-queue"] ? @"setRemoteQueue:" : @"setQueueType:";
            [selectors addObject:selector];
            [symbols addObject:@"SCRemoteQueueXPCObject"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"queueObject=%@", MDKDescribeTraceValue(event[@"queueObject"])],
            ] mutableCopy];
            if ([kind isEqualToString:@"sc-remote-queue-set-remote-queue"]) {
                [notes addObject:[NSString stringWithFormat:@"remoteQueue=%@", MDKDescribeTraceValue(event[@"remoteQueue"])]];
            } else {
                [notes addObject:[NSString stringWithFormat:@"queueType=%@", MDKDescribeTraceValue(event[@"queueType"])]];
            }
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
                selector,
                @"SCRemoteQueueXPCObject",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"fig-remote-queue-receiver-probe"]) {
            [symbols addObject:@"FigRemoteQueueReceiverCreateFromXPCObject"];
            [symbols addObject:@"FigRemoteQueueReceiverSetHandler"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"capturedRemoteQueueCount=%@", MDKDescribeTraceValue(event[@"capturedRemoteQueueCount"])],
                [NSString stringWithFormat:@"createStatus=%@", MDKDescribeTraceValue(event[@"createStatus"])],
                [NSString stringWithFormat:@"handlerStatus=%@", MDKDescribeTraceValue(event[@"handlerStatus"])],
                [NSString stringWithFormat:@"receiverCreated=%@", MDKDescribeTraceValue(event[@"receiverCreated"])],
                [NSString stringWithFormat:@"callbackObserved=%@", MDKDescribeTraceValue(event[@"callbackObserved"])],
                [NSString stringWithFormat:@"callbackCount=%@", MDKDescribeTraceValue(event[@"callbackCount"])],
                [NSString stringWithFormat:@"callbackTimestampNanos=%@", MDKDescribeTraceValue(event[@"callbackTimestampNanos"])],
                [NSString stringWithFormat:@"callbackStatus=%@", MDKDescribeTraceValue(event[@"callbackStatus"])],
                [NSString stringWithFormat:@"callbackMessageType=%@", MDKDescribeTraceValue(event[@"callbackMessageType"])],
                [NSString stringWithFormat:@"callbackSurface=%@", MDKDescribeTraceValue(event[@"callbackSurface"])],
                [NSString stringWithFormat:@"callbackDeltaCount=%@", MDKDescribeTraceValue(event[@"callbackDeltaCount"])],
                [NSString stringWithFormat:@"callbackDeltaHistogram=%@", MDKDescribeTraceValue(event[@"callbackDeltaHistogram"])],
                [NSString stringWithFormat:@"callback120HzEquivalentCount=%@", MDKDescribeTraceValue(event[@"callback120HzEquivalentCount"])],
                [NSString stringWithFormat:@"callbackCadenceClassification=%@", MDKDescribeTraceValue(event[@"callbackCadenceClassification"])],
                [NSString stringWithFormat:@"waitTimedOut=%@", MDKDescribeTraceValue(event[@"waitTimedOut"])],
                [NSString stringWithFormat:@"dequeueStatus=%@", MDKDescribeTraceValue(event[@"dequeueStatus"])],
                [NSString stringWithFormat:@"dequeuedSample=%@", MDKDescribeTraceValue(event[@"dequeuedSample"])],
                [NSString stringWithFormat:@"remoteQueue=%@", MDKDescribeTraceValue(event[@"remoteQueue"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"fig-remote-queue-receiver-probe",
                nil,
                @"FigRemoteQueueReceiver",
                (event[@"createStatus"] ?: @0),
                event[@"callbackObserved"] ?: @NO,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"sc-remote-queue-wrapper-probe"]) {
            [symbols addObject:@"SCRemoteQueue_CreateReceiverQueue"];
            [symbols addObject:@"SCRemoteQueue_Destroy"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"capturedRemoteQueueCount=%@", MDKDescribeTraceValue(event[@"capturedRemoteQueueCount"])],
                [NSString stringWithFormat:@"createStatus=%@", MDKDescribeTraceValue(event[@"createStatus"])],
                [NSString stringWithFormat:@"wrapperCreated=%@", MDKDescribeTraceValue(event[@"wrapperCreated"])],
                [NSString stringWithFormat:@"callbackObserved=%@", MDKDescribeTraceValue(event[@"callbackObserved"])],
                [NSString stringWithFormat:@"callbackCount=%@", MDKDescribeTraceValue(event[@"callbackCount"])],
                [NSString stringWithFormat:@"callbackStatus=%@", MDKDescribeTraceValue(event[@"callbackStatus"])],
                [NSString stringWithFormat:@"callbackTimestampNanos=%@", MDKDescribeTraceValue(event[@"callbackTimestampNanos"])],
                [NSString stringWithFormat:@"callbackMessageType=%@", MDKDescribeTraceValue(event[@"callbackMessageType"])],
                [NSString stringWithFormat:@"callbackSurface=%@", MDKDescribeTraceValue(event[@"callbackSurface"])],
                [NSString stringWithFormat:@"callbackDeltaCount=%@", MDKDescribeTraceValue(event[@"callbackDeltaCount"])],
                [NSString stringWithFormat:@"callbackDeltaHistogram=%@", MDKDescribeTraceValue(event[@"callbackDeltaHistogram"])],
                [NSString stringWithFormat:@"callback120HzEquivalentCount=%@", MDKDescribeTraceValue(event[@"callback120HzEquivalentCount"])],
                [NSString stringWithFormat:@"callbackCadenceClassification=%@", MDKDescribeTraceValue(event[@"callbackCadenceClassification"])],
                [NSString stringWithFormat:@"waitTimedOut=%@", MDKDescribeTraceValue(event[@"waitTimedOut"])],
                [NSString stringWithFormat:@"updateSymbolPresent=%@", MDKDescribeTraceValue(event[@"updateSymbolPresent"])],
                [NSString stringWithFormat:@"updateStatus=%@", MDKDescribeTraceValue(event[@"updateStatus"])],
                [NSString stringWithFormat:@"destroySymbolPresent=%@", MDKDescribeTraceValue(event[@"destroySymbolPresent"])],
                [NSString stringWithFormat:@"remoteQueue=%@", MDKDescribeTraceValue(event[@"remoteQueue"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"sc-remote-queue-wrapper-probe",
                nil,
                @"SCRemoteQueue",
                [event[@"createStatus"] boolValue] ? @0 : @(-1),
                event[@"callbackObserved"] ?: @NO,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"rp-iosurface-set"] || [kind isEqualToString:@"rp-iosurface-get"]) {
            [selectors addObject:[kind isEqualToString:@"rp-iosurface-set"] ? @"setIOSurface:" : @"ioSurface"];
            [symbols addObject:@"RPIOSurfaceObject"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"surface=%@", MDKDescribeTraceValue(event[@"surface"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
                [kind isEqualToString:@"rp-iosurface-set"] ? @"setIOSurface:" : @"ioSurface",
                @"RPIOSurfaceObject",
                nil,
                @YES,
                notes
            )];
            continue;
        }

        if ([kind isEqualToString:@"post-start-stream-state"]) {
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
                [NSString stringWithFormat:@"startErrorDomain=%@", MDKDescribeTraceValue(event[@"startErrorDomain"])],
                [NSString stringWithFormat:@"startErrorCode=%@", MDKDescribeTraceValue(event[@"startErrorCode"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                @"post-start-stream-state",
                nil,
                @"SCStream",
                nil,
                @YES,
                notes
            )];
            continue;
        }
    }

    NSArray<NSDictionary<NSString *, id> *> *traceEvents = snapshot[@"events"] ?: @[];
    NSDictionary<NSString *, id> *firstPublicSampleEvent = nil;
    NSDictionary<NSString *, id> *firstPublicSamplePrecedingEvent = nil;
    NSUInteger firstPublicSampleEventIndex = NSNotFound;
    for (NSUInteger idx = 0; idx < traceEvents.count; ++idx) {
        NSDictionary<NSString *, id> *event = traceEvents[idx];
        if ([event[@"kind"] isEqualToString:@"stream-output-sample-buffer"]) {
            firstPublicSampleEvent = event;
            firstPublicSampleEventIndex = idx;
            if (idx > 0 && [traceEvents[idx - 1] isKindOfClass:[NSDictionary class]]) {
                firstPublicSamplePrecedingEvent = traceEvents[idx - 1];
            }
            break;
        }
    }

    NSNumber *firstPrivateQueueTimestampNanos = nil;
    NSString *firstPrivateQueueSource = nil;
    NSDictionary<NSString *, id> *firstPrivateQueueSurface = nil;
    NSArray<NSString *> *privateQueueEventKinds = @[
        @"sc-remote-queue-wrapper-probe",
        @"fig-remote-queue-receiver-probe",
    ];
    for (NSDictionary<NSString *, id> *event in traceEvents) {
        NSString *kind = event[@"kind"];
        if (![privateQueueEventKinds containsObject:kind]) {
            continue;
        }

        NSNumber *callbackTimestampNanos = event[@"callbackTimestampNanos"];
        if (![callbackTimestampNanos isKindOfClass:[NSNumber class]]) {
            continue;
        }

        if (firstPrivateQueueTimestampNanos == nil ||
            callbackTimestampNanos.unsignedLongLongValue < firstPrivateQueueTimestampNanos.unsignedLongLongValue) {
            firstPrivateQueueTimestampNanos = callbackTimestampNanos;
            firstPrivateQueueSource = kind;
            if ([event[@"callbackSurface"] isKindOfClass:[NSDictionary class]]) {
                firstPrivateQueueSurface = event[@"callbackSurface"];
            }
        }
    }

    NSNumber *firstPublicSampleTimestampNanos = firstPublicSampleEvent[@"timestampNanos"];
    NSDictionary<NSString *, id> *firstPublicSampleBuffer = firstPublicSampleEvent[@"sampleBuffer"];
    NSDictionary<NSString *, id> *firstPublicSampleSurface =
        [firstPublicSampleBuffer[@"surface"] isKindOfClass:[NSDictionary class]] ? firstPublicSampleBuffer[@"surface"] : nil;
    NSString *firstPublicSampleSurfacePointer =
        [firstPublicSampleSurface[@"pointer"] isKindOfClass:[NSString class]] ? firstPublicSampleSurface[@"pointer"] : nil;
    NSNumber *firstPublicSamplePrecedingEventIndexNumber =
        (firstPublicSampleEventIndex != NSNotFound && firstPublicSampleEventIndex > 0) ? @(firstPublicSampleEventIndex - 1) : nil;
    NSString *firstPublicSamplePrecedingEventKind =
        [firstPublicSamplePrecedingEvent[@"kind"] isKindOfClass:[NSString class]] ? firstPublicSamplePrecedingEvent[@"kind"] : nil;
    NSString *firstPublicSamplePrecedingEventSelector =
        [firstPublicSamplePrecedingEvent[@"selector"] isKindOfClass:[NSString class]] ? firstPublicSamplePrecedingEvent[@"selector"] : nil;
    NSString *firstPublicSamplePrecedingEventSymbol =
        [firstPublicSamplePrecedingEvent[@"symbol"] isKindOfClass:[NSString class]] ? firstPublicSamplePrecedingEvent[@"symbol"] : nil;
    NSNumber *firstPublicSamplePrecedingEventTimestampNanos =
        [firstPublicSamplePrecedingEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? firstPublicSamplePrecedingEvent[@"timestampNanos"] : nil;
    NSDictionary<NSString *, id> *firstPublicSamplePrecedingEventStreamState =
        [firstPublicSamplePrecedingEvent[@"streamState"] isKindOfClass:[NSDictionary class]] ? firstPublicSamplePrecedingEvent[@"streamState"] : nil;
    NSNumber *firstPublicSamplePrecedingEventLeadMilliseconds = nil;
    if ([firstPublicSamplePrecedingEventTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstPublicSampleTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstPublicSampleTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstPublicSamplePrecedingEventTimestampNanos.unsignedLongLongValue);
        firstPublicSamplePrecedingEventLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }

    NSDictionary<NSString *, id> *firstPublicSamplePrecedingState = firstPublicSamplePrecedingEventStreamState;
    NSString *firstPublicSamplePrecedingStateSourceKind = firstPublicSamplePrecedingEventKind;
    NSNumber *firstPublicSamplePrecedingStateTimestampNanos = firstPublicSamplePrecedingEventTimestampNanos;
    if (firstPublicSamplePrecedingState == nil && firstPublicSampleEventIndex != NSNotFound) {
        for (NSInteger idx = static_cast<NSInteger>(firstPublicSampleEventIndex) - 1; idx >= 0; --idx) {
            NSDictionary<NSString *, id> *event = traceEvents[static_cast<NSUInteger>(idx)];
            if (![event[@"streamState"] isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            firstPublicSamplePrecedingState = event[@"streamState"];
            firstPublicSamplePrecedingStateSourceKind =
                [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
            firstPublicSamplePrecedingStateTimestampNanos =
                [event[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? event[@"timestampNanos"] : nil;
            break;
        }
    }
    NSNumber *firstPublicSamplePrecedingStateLeadMilliseconds = nil;
    if ([firstPublicSamplePrecedingStateTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstPublicSampleTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstPublicSampleTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstPublicSamplePrecedingStateTimestampNanos.unsignedLongLongValue);
        firstPublicSamplePrecedingStateLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }

    auto isVideoRelatedTraceEvent = ^BOOL(NSDictionary<NSString *, id> *event) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
        if (kind == nil) {
            return NO;
        }

        if ([kind isEqualToString:@"stream-start-remote-video-receive-queue"] ||
            [kind isEqualToString:@"stream-post-start-remote-video-state"] ||
            [kind isEqualToString:@"post-start-stream-state"]) {
            return YES;
        }

        if ([kind isEqualToString:@"stream-start-remote-receive-queue"]) {
            NSDictionary<NSString *, id> *queue = [event[@"queue"] isKindOfClass:[NSDictionary class]] ? event[@"queue"] : nil;
            NSNumber *queueType = [queue[@"queueType"] isKindOfClass:[NSNumber class]] ? queue[@"queueType"] : nil;
            return queueType != nil && queueType.unsignedCharValue == 1;
        }

        if ([kind isEqualToString:@"sc-remote-queue-set-queue-type"]) {
            NSNumber *queueType = [event[@"queueType"] isKindOfClass:[NSNumber class]] ? event[@"queueType"] : nil;
            return queueType != nil && queueType.unsignedCharValue == 1;
        }

        if ([kind isEqualToString:@"sc-remote-queue-set-remote-queue"]) {
            NSDictionary<NSString *, id> *queueObject =
                [event[@"queueObject"] isKindOfClass:[NSDictionary class]] ? event[@"queueObject"] : nil;
            NSNumber *queueType = [queueObject[@"queueType"] isKindOfClass:[NSNumber class]] ? queueObject[@"queueType"] : nil;
            return queueType != nil && queueType.unsignedCharValue == 1;
        }

        return NO;
    };

    NSDictionary<NSString *, id> *firstPublicSampleLastVideoEvent = nil;
    NSNumber *firstPublicSampleLastVideoEventIndexNumber = nil;
    if (firstPublicSampleEventIndex != NSNotFound) {
        for (NSInteger idx = static_cast<NSInteger>(firstPublicSampleEventIndex) - 1; idx >= 0; --idx) {
            NSDictionary<NSString *, id> *event = traceEvents[static_cast<NSUInteger>(idx)];
            if (!isVideoRelatedTraceEvent(event)) {
                continue;
            }

            firstPublicSampleLastVideoEvent = event;
            firstPublicSampleLastVideoEventIndexNumber = @(idx);
            break;
        }
    }
    NSString *firstPublicSampleLastVideoEventKind =
        [firstPublicSampleLastVideoEvent[@"kind"] isKindOfClass:[NSString class]] ? firstPublicSampleLastVideoEvent[@"kind"] : nil;
    NSString *firstPublicSampleLastVideoEventSelector =
        [firstPublicSampleLastVideoEvent[@"selector"] isKindOfClass:[NSString class]] ? firstPublicSampleLastVideoEvent[@"selector"] : nil;
    NSString *firstPublicSampleLastVideoEventSymbol =
        [firstPublicSampleLastVideoEvent[@"symbol"] isKindOfClass:[NSString class]] ? firstPublicSampleLastVideoEvent[@"symbol"] : nil;
    NSNumber *firstPublicSampleLastVideoEventTimestampNanos =
        [firstPublicSampleLastVideoEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? firstPublicSampleLastVideoEvent[@"timestampNanos"] : nil;
    NSNumber *firstPublicSampleLastVideoEventLeadMilliseconds = nil;
    if ([firstPublicSampleLastVideoEventTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstPublicSampleTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstPublicSampleTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstPublicSampleLastVideoEventTimestampNanos.unsignedLongLongValue);
        firstPublicSampleLastVideoEventLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }
    NSMutableArray<NSString *> *firstPublicSampleInterveningEventKinds = [NSMutableArray array];
    if ([firstPublicSampleLastVideoEventIndexNumber isKindOfClass:[NSNumber class]] && firstPublicSampleEventIndex != NSNotFound) {
        NSUInteger lastVideoEventIndex = firstPublicSampleLastVideoEventIndexNumber.unsignedIntegerValue;
        for (NSUInteger idx = lastVideoEventIndex + 1; idx < firstPublicSampleEventIndex; ++idx) {
            NSDictionary<NSString *, id> *event = traceEvents[idx];
            NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
            if (kind != nil) {
                [firstPublicSampleInterveningEventKinds addObject:kind];
            }
        }
    }
    NSString *firstPrivateQueueSurfacePointer =
        [firstPrivateQueueSurface[@"pointer"] isKindOfClass:[NSString class]] ? firstPrivateQueueSurface[@"pointer"] : nil;
    NSNumber *privateQueueLeadMilliseconds = nil;
    if ([firstPrivateQueueTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstPublicSampleTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstPublicSampleTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstPrivateQueueTimestampNanos.unsignedLongLongValue);
        privateQueueLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }

    NSDictionary<NSString *, id> *postStartStreamState = nil;
    for (NSDictionary<NSString *, id> *event in traceEvents) {
        if ([event[@"kind"] isEqualToString:@"post-start-stream-state"] &&
            [event[@"streamState"] isKindOfClass:[NSDictionary class]]) {
            postStartStreamState = event[@"streamState"];
            break;
        }
    }
    NSDictionary<NSString *, id> *postStartVideoQueueEntry =
        [postStartStreamState[@"videoQueueEntry"] isKindOfClass:[NSDictionary class]] ? postStartStreamState[@"videoQueueEntry"] : nil;
    NSDictionary<NSString *, id> *postStartVideoRemoteQueue =
        [postStartVideoQueueEntry[@"remoteQueue"] isKindOfClass:[NSDictionary class]] ? postStartVideoQueueEntry[@"remoteQueue"] : nil;
    NSDictionary<NSString *, id> *postStartVideoRemoteQueueValues =
        [postStartVideoRemoteQueue[@"xpcSelectedValues"] isKindOfClass:[NSDictionary class]] ? postStartVideoRemoteQueue[@"xpcSelectedValues"] : nil;
    NSDictionary<NSString *, id> *postStartVideoIOSurfaceReceiver =
        [postStartVideoRemoteQueueValues[@"IOSurfaceReceiver"] isKindOfClass:[NSDictionary class]] ? postStartVideoRemoteQueueValues[@"IOSurfaceReceiver"] : nil;
    NSString *postStartVideoIOSurfaceReceiverDescription =
        [postStartVideoIOSurfaceReceiver[@"description"] isKindOfClass:[NSString class]] ? postStartVideoIOSurfaceReceiver[@"description"] : nil;
    const BOOL postStartVideoIOSurfaceReceiverConsumed =
        postStartVideoIOSurfaceReceiverDescription != nil &&
        [postStartVideoIOSurfaceReceiverDescription containsString:@"(consumed)"];
    NSDictionary<NSString *, id> *wrapperProbeEvent = nil;
    NSDictionary<NSString *, id> *figProbeEvent = nil;
    for (NSDictionary<NSString *, id> *event in traceEvents) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
        if (wrapperProbeEvent == nil && [kind isEqualToString:@"sc-remote-queue-wrapper-probe"]) {
            wrapperProbeEvent = event;
        } else if (figProbeEvent == nil && [kind isEqualToString:@"fig-remote-queue-receiver-probe"]) {
            figProbeEvent = event;
        }
    }

    NSString *streamID = MDKPerformObjectGetter(stream, sel_registerName("streamID")) ?: @"";
    NSDictionary *serializedStreamProperties = MDKSummarizeObject(
        MDKPerformObjectGetter(stream, sel_registerName("serializeStreamProperties"))
    );
    NSDictionary *serializedFilter = MDKSummarizeObject(
        MDKPerformObjectGetter(filter, sel_registerName("serialize"))
    );

    NSMutableArray<NSString *> *notes = [snapshot[@"notes"] mutableCopy] ?: [NSMutableArray array];
    [notes addObject:[NSString stringWithFormat:@"serializedStreamProperties=%@", MDKDescribeTraceValue(serializedStreamProperties)]];
    [notes addObject:[NSString stringWithFormat:@"serializedFilter=%@", MDKDescribeTraceValue(serializedFilter)]];
    [notes addObject:[NSString stringWithFormat:@"collectStreamDataCallCount=%@", MDKDescribeTraceValue(snapshot[@"collectStreamDataCallCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferEventCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferArrivalDeltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaMinMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferArrivalDeltaMinMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaMaxMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferArrivalDeltaMaxMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaHistogram=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferArrivalDeltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferPresentationDeltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaMinMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferPresentationDeltaMinMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaMaxMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferPresentationDeltaMaxMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaHistogram=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferPresentationDeltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferUniqueSurfaceCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferUniqueSurfaceCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferConsecutiveSurfaceReuseCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferConsecutiveSurfaceReuseCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferSurfaceUseCountMax=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferSurfaceUseCountMax"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferSurfaceUseCountHistogram=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferSurfaceUseCountHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"rpIOSurfaceEventCount=%@", MDKDescribeTraceValue(snapshot[@"rpIOSurfaceEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"captureHandlerSampleEventCount=%@", MDKDescribeTraceValue(snapshot[@"captureHandlerSampleEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamEventCount=%@", MDKDescribeTraceValue(snapshot[@"contentStreamEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportEventCount=%@", MDKDescribeTraceValue(snapshot[@"surfaceTransportEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"frameReceiverEventCount=%@", MDKDescribeTraceValue(snapshot[@"frameReceiverEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkEventCount=%@", MDKDescribeTraceValue(snapshot[@"remoteQueueSinkEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueObjectEventCount=%@", MDKDescribeTraceValue(snapshot[@"remoteQueueObjectEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"capturedRemoteQueueCount=%lu", (unsigned long) MDKCapturedSCKRemoteQueueCount()]];
    [notes addObject:[NSString stringWithFormat:@"privateQueueProbesEnabled=%@", includePrivateQueueProbes ? @"true" : @"false"]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSampleTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventIndex=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventIndexNumber)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventKind=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventKind)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventSelector=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventSelector)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventSymbol=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventStreamState=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventStreamState)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingStateSourceKind=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingStateSourceKind)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingStateTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingStateTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingStateLeadMilliseconds=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingStateLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingState=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingState)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventIndex=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventIndexNumber)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventKind=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventKind)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventSelector=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventSelector)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventSymbol=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstPublicSampleInterveningEventKinds=%@", MDKDescribeTraceValue(firstPublicSampleInterveningEventKinds)]];
    [notes addObject:[NSString stringWithFormat:@"firstPrivateQueueTimestampNanos=%@", MDKDescribeTraceValue(firstPrivateQueueTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstPrivateQueueSource=%@", MDKDescribeTraceValue(firstPrivateQueueSource)]];
    [notes addObject:[NSString stringWithFormat:@"privateQueueLeadMilliseconds=%@", MDKDescribeTraceValue(privateQueueLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"wrapperProbeCallbackCount=%@", MDKDescribeTraceValue(wrapperProbeEvent[@"callbackCount"])]];
    [notes addObject:[NSString stringWithFormat:@"wrapperProbeCallbackDeltaCount=%@", MDKDescribeTraceValue(wrapperProbeEvent[@"callbackDeltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"wrapperProbeCallback120HzEquivalentCount=%@", MDKDescribeTraceValue(wrapperProbeEvent[@"callback120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"wrapperProbeCallbackCadenceClassification=%@", MDKDescribeTraceValue(wrapperProbeEvent[@"callbackCadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"figProbeCallbackCount=%@", MDKDescribeTraceValue(figProbeEvent[@"callbackCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figProbeCallbackDeltaCount=%@", MDKDescribeTraceValue(figProbeEvent[@"callbackDeltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figProbeCallback120HzEquivalentCount=%@", MDKDescribeTraceValue(figProbeEvent[@"callback120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figProbeCallbackCadenceClassification=%@", MDKDescribeTraceValue(figProbeEvent[@"callbackCadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"publicSampleSurfacePointer=%@", MDKDescribeTraceValue(firstPublicSampleSurfacePointer)]];
    [notes addObject:[NSString stringWithFormat:@"privateQueueSurfacePointer=%@", MDKDescribeTraceValue(firstPrivateQueueSurfacePointer)]];
    if (firstPublicSampleSurfacePointer != nil && firstPrivateQueueSurfacePointer != nil) {
        [notes addObject:[NSString stringWithFormat:@"surfacePointerMatched=%@", [firstPublicSampleSurfacePointer isEqualToString:firstPrivateQueueSurfacePointer] ? @"true" : @"false"]];
    } else {
        [notes addObject:@"surfacePointerMatched=<null>"];
    }
    [notes addObject:[NSString stringWithFormat:@"postStartVideoIOSurfaceReceiver=%@", MDKDescribeTraceValue(postStartVideoIOSurfaceReceiverDescription)]];
    if (includePrivateQueueProbes &&
        [snapshot[@"sampleBufferEventCount"] unsignedIntegerValue] == 0 &&
        postStartVideoIOSurfaceReceiverConsumed) {
        [notes addObject:@"Current private queue probe path is consuming the video IOSurfaceReceiver right before public SCStream sample delivery begins."];
    }
    [notes addObject:@"stopCaptureWithCompletionHandler was intentionally skipped in the host-only trace to avoid an RPDaemonProxy stop-path NSXPCEncoder exception."];
    const BOOL succeeded = [snapshot[@"sawProxyCoreGraphics"] boolValue] && startError == nil;
    const std::int32_t status = startError != nil ? static_cast<std::int32_t>(startError.code) : (succeeded ? 0 : 1);
    if (startError != nil) {
        [notes addObject:[NSString stringWithFormat:@"Public SCStream start failed: %@", startError.localizedDescription ?: @"<unknown>"]];
    } else if (succeeded) {
        [notes addObject:@"Public SCStream start completed and reached RPDaemonProxy proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:."];
    } else {
        [notes addObject:@"Public SCStream start completed but the trace did not observe RPDaemonProxy proxyCoreGraphicsWithMethodType:config:machPort:completionHandler: before timeout."];
    }

    NSMutableArray<NSString *> *deliveryComparisonNotes = [NSMutableArray array];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSampleTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventIndex=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventIndexNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventKind=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventKind)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventSelector=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventSelector)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventSymbol=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingEventStreamState=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingEventStreamState)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingStateSourceKind=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingStateSourceKind)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingStateTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingStateTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingStateLeadMilliseconds=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingStateLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSamplePrecedingState=%@", MDKDescribeTraceValue(firstPublicSamplePrecedingState)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventIndex=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventIndexNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventKind=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventKind)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventSelector=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventSelector)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventSymbol=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventTimestampNanos=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleLastVideoEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstPublicSampleLastVideoEventLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPublicSampleInterveningEventKinds=%@", MDKDescribeTraceValue(firstPublicSampleInterveningEventKinds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPrivateQueueTimestampNanos=%@", MDKDescribeTraceValue(firstPrivateQueueTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstPrivateQueueSource=%@", MDKDescribeTraceValue(firstPrivateQueueSource)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"privateQueueLeadMilliseconds=%@", MDKDescribeTraceValue(privateQueueLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"publicSampleSurfacePointer=%@", MDKDescribeTraceValue(firstPublicSampleSurfacePointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"privateQueueSurfacePointer=%@", MDKDescribeTraceValue(firstPrivateQueueSurfacePointer)]];
    if (firstPublicSampleSurfacePointer != nil && firstPrivateQueueSurfacePointer != nil) {
        [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"surfacePointerMatched=%@", [firstPublicSampleSurfacePointer isEqualToString:firstPrivateQueueSurfacePointer] ? @"true" : @"false"]];
    } else {
        [deliveryComparisonNotes addObject:@"surfacePointerMatched=<null>"];
    }
    [steps addObject:MDKMakeTraceStep(
        @"first-public-sample-predecessor",
        firstPublicSamplePrecedingEventSelector,
        firstPublicSamplePrecedingEventSymbol,
        nil,
        @(firstPublicSamplePrecedingEventKind != nil),
        deliveryComparisonNotes
    )];
    [steps addObject:MDKMakeTraceStep(
        @"delivery-comparison",
        @"stream:didOutputSampleBuffer:ofType:",
        @"ScreenCaptureKit",
        nil,
        @([firstPublicSampleTimestampNanos isKindOfClass:[NSNumber class]]),
        deliveryComparisonNotes
    )];

    NSMutableDictionary<NSString *, id> *result = [@{
        @"displayID": @(displayID),
        @"sampleDuration": @(timeout),
        @"status": @(status),
        @"succeeded": @(succeeded),
        @"streamID": streamID,
        @"filterID": MDKPerformObjectGetter(filter, sel_registerName("filterID")) ?: @"",
        @"selectors": [[selectors allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"symbols": [[symbols allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"steps": steps,
        @"notes": notes,
    } mutableCopy];

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKTraceState = nil;
    }

    return result;
}

static NSDictionary<NSString *, id> * _Nullable MDKCreateSCKPublicTimingTrace(
    NSUInteger displayID,
    NSTimeInterval timeout,
    NSError * _Nullable * _Nullable error
) {
    if (!CGPreflightScreenCaptureAccess()) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:7
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Screen capture access is not authorized for the public ScreenCaptureKit timing trace."
                                     }];
        }
        return nil;
    }

    if (timeout <= 0) {
        timeout = 2.0;
    }

    NSBundle *screenCaptureKitBundle = [NSBundle bundleWithPath:@"/System/Library/Frameworks/ScreenCaptureKit.framework"];
    if (screenCaptureKitBundle != nil && !screenCaptureKitBundle.loaded) {
        [screenCaptureKitBundle load];
    }

    Class shareableContentClass = NSClassFromString(@"SCShareableContent");
    Class filterClass = NSClassFromString(@"SCContentFilter");
    Class configClass = NSClassFromString(@"SCStreamConfiguration");
    Class streamClass = NSClassFromString(@"SCStream");
    if (shareableContentClass == Nil || filterClass == Nil || configClass == Nil || streamClass == Nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:9
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Required ScreenCaptureKit classes are unavailable."
                                     }];
        }
        return nil;
    }

    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(static_cast<CGDirectDisplayID>(displayID));
    if (mode == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:10
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to resolve the current display mode for the ScreenCaptureKit timing trace."
                                     }];
        }
        return nil;
    }

    const NSUInteger width = std::max(static_cast<NSUInteger>(CGDisplayModeGetPixelWidth(mode)), static_cast<NSUInteger>(1));
    const NSUInteger height = std::max(static_cast<NSUInteger>(CGDisplayModeGetPixelHeight(mode)), static_cast<NSUInteger>(1));
    CFRelease(mode);

    MDKResetSCKTraceState(displayID, timeout);
    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKAllowPrivateQueueProbes = NO;
    }

    __block id display = nil;
    __block NSError *shareableContentError = nil;
    if ([shareableContentClass respondsToSelector:sel_registerName("getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:")]) {
        dispatch_semaphore_t shareableContentCompletion = dispatch_semaphore_create(0);
        ((void (*)(id, SEL, BOOL, BOOL, id)) objc_msgSend)(
            shareableContentClass,
            sel_registerName("getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:"),
            NO,
            YES,
            ^(id _Nullable shareableContent, NSError * _Nullable completionError) {
                shareableContentError = completionError;
                if (shareableContent != nil && [shareableContent respondsToSelector:sel_registerName("displays")]) {
                    NSArray *displays = ((id (*)(id, SEL)) objc_msgSend)(shareableContent, sel_registerName("displays"));
                    for (id candidate in displays) {
                        if (![candidate respondsToSelector:sel_registerName("displayID")]) {
                            continue;
                        }

                        unsigned int candidateDisplayID = ((unsigned int (*)(id, SEL)) objc_msgSend)(
                            candidate,
                            sel_registerName("displayID")
                        );
                        if (candidateDisplayID == static_cast<unsigned int>(displayID)) {
                            display = candidate;
                            break;
                        }
                    }
                }
                dispatch_semaphore_signal(shareableContentCompletion);
            }
        );

        const NSDate *shareableDeadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        while (display == nil && shareableContentError == nil && [shareableDeadline timeIntervalSinceNow] > 0) {
            if (dispatch_semaphore_wait(shareableContentCompletion, dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(10 * NSEC_PER_MSEC))) == 0) {
                break;
            }
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
            }
        }
    }

    if (display == nil && [shareableContentClass respondsToSelector:sel_registerName("getDisplayForDisplayId:")]) {
        display = ((id (*)(id, SEL, unsigned int)) objc_msgSend)(
            shareableContentClass,
            sel_registerName("getDisplayForDisplayId:"),
            static_cast<unsigned int>(displayID)
        );
    }

    if (display == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:11
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: shareableContentError.localizedDescription ?: @"Unable to resolve an SCDisplay for the timing trace."
                                     }];
        }
        return nil;
    }

    id filter = ((id (*)(id, SEL, id, id, id)) objc_msgSend)(
        ((id (*)(id, SEL)) objc_msgSend)(filterClass, sel_registerName("alloc")),
        sel_registerName("initWithDisplay:excludingApplications:exceptingWindows:"),
        display,
        @[],
        @[]
    );
    if (filter == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:12
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to create an SCContentFilter for the timing trace."
                                     }];
        }
        return nil;
    }

    id configuration = ((id (*)(id, SEL)) objc_msgSend)(
        ((id (*)(id, SEL)) objc_msgSend)(configClass, sel_registerName("alloc")),
        sel_registerName("init")
    );
    ((void (*)(id, SEL, NSUInteger)) objc_msgSend)(configuration, sel_registerName("setWidth:"), width);
    ((void (*)(id, SEL, NSUInteger)) objc_msgSend)(configuration, sel_registerName("setHeight:"), height);
    ((void (*)(id, SEL, NSInteger)) objc_msgSend)(configuration, sel_registerName("setQueueDepth:"), 3);
    ((void (*)(id, SEL, BOOL)) objc_msgSend)(configuration, sel_registerName("setShowsCursor:"), NO);
    ((void (*)(id, SEL, unsigned int)) objc_msgSend)(configuration, sel_registerName("setPixelFormat:"), kCVPixelFormatType_32BGRA);
    const CMTime frameInterval = CMTimeMake(1, 120);
    ((void (*)(id, SEL, CMTime)) objc_msgSend)(configuration, sel_registerName("setMinimumFrameInterval:"), frameInterval);

    id stream = ((id (*)(id, SEL, id, id, id)) objc_msgSend)(
        ((id (*)(id, SEL)) objc_msgSend)(streamClass, sel_registerName("alloc")),
        sel_registerName("initWithFilter:configuration:delegate:"),
        filter,
        configuration,
        nil
    );
    if (stream == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:13
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to create an SCStream for the timing trace."
                                     }];
        }
        return nil;
    }

    MDKRecordSCKTraceEvent(
        @"initial-state",
        @{
            @"contentFilter": MDKSummarizeObject(filter),
            @"display": MDKSummarizeObject(display),
            @"configuration": MDKSummarizeObject(configuration),
            @"stream": MDKSummarizeObject(stream),
            @"streamState": MDKCopySCStreamInternalState(stream),
        }
    );

    dispatch_queue_t sampleQueue = dispatch_queue_create("com.skyline23.MacDisplayKit.sck-public-timing", DISPATCH_QUEUE_SERIAL);
    id outputCollector = [[MDKShimStreamOutputCollector alloc] init];
    NSError *outputError = nil;
    const BOOL addedOutput = ((BOOL (*)(id, SEL, id, NSInteger, id, NSError **)) objc_msgSend)(
        stream,
        sel_registerName("addStreamOutput:type:sampleHandlerQueue:error:"),
        outputCollector,
        0,
        sampleQueue,
        &outputError
    );
    MDKRecordSCKTraceEvent(
        @"add-stream-output",
        @{
            @"outputAdded": @(addedOutput),
            @"errorDomain": outputError.domain ?: [NSNull null],
            @"errorCode": @(outputError.code),
            @"streamState": MDKCopySCStreamInternalState(stream),
        }
    );
    if (!addedOutput) {
        if (error != nullptr) {
            *error = outputError ?: [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                                        code:14
                                                    userInfo:@{
                                                        NSLocalizedDescriptionKey: @"Unable to add a screen stream output before timing collection."
                                                    }];
        }
        return nil;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKScreenSampleHandlerQueue =
            reinterpret_cast<dispatch_queue_t>(MDKCopyObjectIvar(stream, "_screenSampleHandlerQueue"));
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"screenSampleHandlerQueueCaptured"] = @(MDKActiveSCKScreenSampleHandlerQueue != nil);
            if (MDKActiveSCKScreenSampleHandlerQueue != nil) {
                MDKActiveSCKTraceState[@"screenSampleHandlerQueueLabel"] =
                    [NSString stringWithUTF8String:dispatch_queue_get_label(MDKActiveSCKScreenSampleHandlerQueue)] ?: @"";
            }
        }
    }

    __block NSError *startError = nil;
    __block BOOL startCompletionObserved = NO;
    ((void (*)(id, SEL, id)) objc_msgSend)(
        stream,
        sel_registerName("startCaptureWithCompletionHandler:"),
        ^(NSError * _Nullable completionError) {
            @synchronized(MDKActiveSCKTraceLock) {
                if (MDKActiveSCKTraceState != nil) {
                    MDKActiveSCKTraceState[@"startCaptureCompletionObserved"] = @YES;
                    MDKActiveSCKTraceState[@"startCaptureCompletionSucceeded"] = @(completionError == nil);
                    if (completionError != nil) {
                        MDKActiveSCKTraceState[@"startCaptureCompletionErrorDomain"] = completionError.domain ?: @"";
                        MDKActiveSCKTraceState[@"startCaptureCompletionErrorCode"] = @(completionError.code);
                        MDKActiveSCKTraceState[@"startCaptureCompletionErrorDescription"] =
                            completionError.localizedDescription ?: @"";
                    }
                }
            }
            startError = completionError;
            startCompletionObserved = YES;
        }
    );

    const NSDate *startDeadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!startCompletionObserved && [startDeadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        }
    }

    const NSDate *captureDeadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([captureDeadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        }
    }

    MDKRecordSCKTraceEvent(
        @"post-start-stream-state",
        @{
            @"streamState": MDKCopySCStreamInternalState(stream),
            @"startErrorDomain": startError.domain ?: [NSNull null],
            @"startErrorCode": @(startError.code),
            @"startCompletionObserved": @(startCompletionObserved),
        }
    );

    NSDictionary<NSString *, id> *snapshot = MDKCopySCKTraceStateSnapshot();
    if (snapshot == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:15
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to snapshot the ScreenCaptureKit timing trace."
                                     }];
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *steps = [NSMutableArray array];
    NSMutableSet<NSString *> *selectors = [NSMutableSet set];
    NSMutableSet<NSString *> *symbols = [NSMutableSet setWithObject:@"ScreenCaptureKit"];

    NSArray *events = snapshot[@"events"] ?: @[];
    for (NSDictionary *event in events) {
        NSString *kind = event[@"kind"] ?: @"unknown";
        if ([kind isEqualToString:@"initial-state"]) {
            [selectors addObject:@"getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:"];
            [selectors addObject:@"initWithDisplay:excludingApplications:exceptingWindows:"];
            [selectors addObject:@"initWithFilter:configuration:delegate:"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"display=%@", MDKDescribeTraceValue(event[@"display"])],
                [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(event[@"stream"])],
                [NSString stringWithFormat:@"filter=%@", MDKDescribeTraceValue(event[@"contentFilter"])],
                [NSString stringWithFormat:@"configuration=%@", MDKDescribeTraceValue(event[@"configuration"])],
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(@"initial-state", @"initWithFilter:configuration:delegate:", @"ScreenCaptureKit", nil, @YES, notes)];
            continue;
        }

        if ([kind isEqualToString:@"add-stream-output"]) {
            [selectors addObject:@"addStreamOutput:type:sampleHandlerQueue:error:"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"errorDomain=%@", MDKDescribeTraceValue(event[@"errorDomain"])],
                [NSString stringWithFormat:@"errorCode=%@", MDKDescribeTraceValue(event[@"errorCode"])],
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(@"add-stream-output", @"addStreamOutput:type:sampleHandlerQueue:error:", @"ScreenCaptureKit", nil, event[@"outputAdded"], notes)];
            continue;
        }

        if ([kind isEqualToString:@"stream-output-sample-buffer"]) {
            [selectors addObject:@"stream:didOutputSampleBuffer:ofType:"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"type=%@", MDKDescribeTraceValue(event[@"type"])],
                [NSString stringWithFormat:@"sampleBuffer=%@", MDKDescribeTraceValue(event[@"sampleBuffer"])],
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(@"stream-output-sample-buffer", @"stream:didOutputSampleBuffer:ofType:", @"ScreenCaptureKit", nil, @YES, notes)];
            continue;
        }

        if ([kind isEqualToString:@"post-start-stream-state"]) {
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
                [NSString stringWithFormat:@"startErrorDomain=%@", MDKDescribeTraceValue(event[@"startErrorDomain"])],
                [NSString stringWithFormat:@"startErrorCode=%@", MDKDescribeTraceValue(event[@"startErrorCode"])],
                [NSString stringWithFormat:@"startCompletionObserved=%@", MDKDescribeTraceValue(event[@"startCompletionObserved"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(@"post-start-stream-state", @"startCaptureWithCompletionHandler:", @"ScreenCaptureKit", nil, @YES, notes)];
            continue;
        }
    }

    NSString *streamID = MDKPerformObjectGetter(stream, sel_registerName("streamID")) ?: @"";
    NSDictionary *serializedStreamProperties = MDKSummarizeObject(
        MDKPerformObjectGetter(stream, sel_registerName("serializeStreamProperties"))
    );
    NSDictionary *serializedFilter = MDKSummarizeObject(
        MDKPerformObjectGetter(filter, sel_registerName("serialize"))
    );
    NSArray<NSDictionary<NSString *, id> *> *traceEvents =
        [snapshot[@"events"] isKindOfClass:[NSArray class]] ? snapshot[@"events"] : @[];
    NSDictionary<NSString *, NSNumber *> *sampleBufferArrivalDeltaHistogram =
        [snapshot[@"sampleBufferArrivalDeltaHistogram"] isKindOfClass:[NSDictionary class]] ? snapshot[@"sampleBufferArrivalDeltaHistogram"] : nil;
    NSDictionary<NSString *, NSNumber *> *sampleBufferPresentationDeltaHistogram =
        [snapshot[@"sampleBufferPresentationDeltaHistogram"] isKindOfClass:[NSDictionary class]] ? snapshot[@"sampleBufferPresentationDeltaHistogram"] : nil;
    NSDictionary<NSString *, id> *captureHandlerCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"daemon-capture-handler-sample",
            @"screen-recorder-capture-handler-sample",
        ]]
    );
    NSDictionary<NSString *, id> *contentStreamCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"ca-content-stream-produce-surface",
        ]]
    );
    NSDictionary<NSString *, id> *remoteQueueSinkCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"bw-remote-queue-render",
            @"bw-remote-queue-drop",
        ]]
    );
    const NSUInteger sampleBufferArrivalDeltaCount = [snapshot[@"sampleBufferArrivalDeltaCount"] unsignedIntegerValue];
    const NSUInteger sampleBufferPresentationDeltaCount = [snapshot[@"sampleBufferPresentationDeltaCount"] unsignedIntegerValue];
    NSUInteger sampleBufferArrival120HzEquivalentCount = MDKHistogramCountInRange(sampleBufferArrivalDeltaHistogram, 0.0, 10.0);
    NSUInteger sampleBufferArrivalFastCount = MDKHistogramCountInRange(sampleBufferArrivalDeltaHistogram, 0.0, 12.5);
    NSUInteger sampleBufferArrivalSixtyLikeCount = MDKHistogramCountInRange(sampleBufferArrivalDeltaHistogram, 12.5, 20.0);
    NSUInteger sampleBufferArrivalLongGapCount = MDKHistogramCountInRange(sampleBufferArrivalDeltaHistogram, 20.0, DBL_MAX);
    NSString *sampleBufferArrivalCadenceClassification = MDKClassifyCadenceHistogram(sampleBufferArrivalDeltaHistogram, sampleBufferArrivalDeltaCount);
    NSUInteger sampleBufferPresentation120HzEquivalentCount = MDKHistogramCountInRange(sampleBufferPresentationDeltaHistogram, 0.0, 10.0);
    NSUInteger sampleBufferPresentationFastCount = MDKHistogramCountInRange(sampleBufferPresentationDeltaHistogram, 0.0, 12.5);
    NSUInteger sampleBufferPresentationSixtyLikeCount = MDKHistogramCountInRange(sampleBufferPresentationDeltaHistogram, 12.5, 20.0);
    NSUInteger sampleBufferPresentationLongGapCount = MDKHistogramCountInRange(sampleBufferPresentationDeltaHistogram, 20.0, DBL_MAX);
    NSString *sampleBufferPresentationCadenceClassification = MDKClassifyCadenceHistogram(sampleBufferPresentationDeltaHistogram, sampleBufferPresentationDeltaCount);

    NSMutableArray<NSString *> *notes = [snapshot[@"notes"] mutableCopy] ?: [NSMutableArray array];
    [notes addObject:[NSString stringWithFormat:@"serializedStreamProperties=%@", MDKDescribeTraceValue(serializedStreamProperties)]];
    [notes addObject:[NSString stringWithFormat:@"serializedFilter=%@", MDKDescribeTraceValue(serializedFilter)]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferEventCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaCount=%@", MDKDescribeTraceValue(@(sampleBufferArrivalDeltaCount))]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaMinMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferArrivalDeltaMinMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaMaxMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferArrivalDeltaMaxMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDeltaHistogram=%@", MDKDescribeTraceValue(sampleBufferArrivalDeltaHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalDelta120HzEquivalentCount=%lu", (unsigned long) sampleBufferArrival120HzEquivalentCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalFastCount=%lu", (unsigned long) sampleBufferArrivalFastCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalSixtyLikeCount=%lu", (unsigned long) sampleBufferArrivalSixtyLikeCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalLongGapCount=%lu", (unsigned long) sampleBufferArrivalLongGapCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferArrivalCadenceClassification=%@", MDKDescribeTraceValue(sampleBufferArrivalCadenceClassification)]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaCount=%@", MDKDescribeTraceValue(@(sampleBufferPresentationDeltaCount))]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaMinMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferPresentationDeltaMinMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaMaxMilliseconds=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferPresentationDeltaMaxMilliseconds"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDeltaHistogram=%@", MDKDescribeTraceValue(sampleBufferPresentationDeltaHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationDelta120HzEquivalentCount=%lu", (unsigned long) sampleBufferPresentation120HzEquivalentCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationFastCount=%lu", (unsigned long) sampleBufferPresentationFastCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationSixtyLikeCount=%lu", (unsigned long) sampleBufferPresentationSixtyLikeCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationLongGapCount=%lu", (unsigned long) sampleBufferPresentationLongGapCount]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferPresentationCadenceClassification=%@", MDKDescribeTraceValue(sampleBufferPresentationCadenceClassification)]];
    [notes addObject:[NSString stringWithFormat:@"captureHandlerEventCount=%@", MDKDescribeTraceValue(captureHandlerCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"captureHandlerDeltaCount=%@", MDKDescribeTraceValue(captureHandlerCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"captureHandlerDeltaHistogram=%@", MDKDescribeTraceValue(captureHandlerCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"captureHandlerDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(captureHandlerCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"captureHandlerCadenceClassification=%@", MDKDescribeTraceValue(captureHandlerCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamEventCount=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamDeltaCount=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamDeltaHistogram=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamCadenceClassification=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkEventCount=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkDeltaCount=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkDeltaHistogram=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkCadenceClassification=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferUniqueSurfaceCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferUniqueSurfaceCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferConsecutiveSurfaceReuseCount=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferConsecutiveSurfaceReuseCount"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferSurfaceUseCountMax=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferSurfaceUseCountMax"])]];
    [notes addObject:[NSString stringWithFormat:@"sampleBufferSurfaceUseCountHistogram=%@", MDKDescribeTraceValue(snapshot[@"sampleBufferSurfaceUseCountHistogram"])]];
    [notes addObject:@"privateQueueProbesEnabled=false"];

    const NSUInteger sampleBufferEventCount = [snapshot[@"sampleBufferEventCount"] unsignedIntegerValue];
    const BOOL succeeded = startCompletionObserved && startError == nil && sampleBufferEventCount > 0;
    const std::int32_t status = startError != nil ? static_cast<std::int32_t>(startError.code) : (succeeded ? 0 : 1);
    if (startError != nil) {
        [notes addObject:[NSString stringWithFormat:@"Public SCStream timing trace start failed: %@", startError.localizedDescription ?: @"<unknown>"]];
    } else if (!startCompletionObserved) {
        [notes addObject:@"Public SCStream timing trace timed out waiting for startCaptureWithCompletionHandler: completion on the main run loop."];
    } else if (sampleBufferEventCount == 0) {
        [notes addObject:@"Public SCStream timing trace started successfully but did not deliver any sample buffers during the capture window."];
    } else {
        [notes addObject:@"Public SCStream timing trace collected sample buffers successfully."];
    }

    NSMutableDictionary<NSString *, id> *result = [@{
        @"displayID": @(displayID),
        @"sampleDuration": @(timeout),
        @"status": @(status),
        @"succeeded": @(succeeded),
        @"streamID": streamID,
        @"filterID": MDKPerformObjectGetter(filter, sel_registerName("filterID")) ?: @"",
        @"selectors": [[selectors allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"symbols": [[symbols allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"steps": steps,
        @"notes": notes,
    } mutableCopy];

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKTraceState = nil;
    }

    return result;
}

static NSDictionary<NSString *, id> * _Nullable MDKCreatePrivateCaptureSurfacePayload(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSError * _Nullable * _Nullable error,
    BOOL benchmarkMode,
    NSTimeInterval sampleDuration,
    BOOL useDirectProxy
) {
    using MDKPrivateCaptureDisplayIntoIOSurfaceWithOptionsFn =
        int (*)(std::uint32_t, std::uint32_t, std::uint32_t, IOSurfaceRef, std::uint32_t *);
    using MDKPrivateCaptureDisplayIntoIOSurfaceProxyFn =
        int (*)(std::uint32_t, std::uint32_t, std::uint32_t, mach_port_t, std::uint32_t *, BOOL *);
    static constexpr std::uint32_t MDKPrivateCaptureExtendedRangeBit = 0x00200000;

    auto symbol = reinterpret_cast<MDKPrivateCaptureDisplayIntoIOSurfaceWithOptionsFn>(
        MDKLookupCaptureSymbol("CGSHWCaptureDisplayIntoIOSurfaceWithOptions")
    );
    auto proxySymbol = reinterpret_cast<MDKPrivateCaptureDisplayIntoIOSurfaceProxyFn>(
        MDKLookupScreenCaptureKitSymbol("SLSHWCaptureDisplayIntoIOSurfaceProxying")
    );
    if ((!useDirectProxy && symbol == nullptr) || (useDirectProxy && proxySymbol == nullptr)) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: useDirectProxy
                                             ? @"SLSHWCaptureDisplayIntoIOSurfaceProxying is unavailable."
                                             : @"CGSHWCaptureDisplayIntoIOSurfaceWithOptions is unavailable."
                                     }];
        }
        return nil;
    }

    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(static_cast<CGDirectDisplayID>(displayID));
    if (mode == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:2
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to resolve the current display mode for the requested display."
                                     }];
        }
        return nil;
    }

    const std::uint32_t width = static_cast<std::uint32_t>(std::max<std::size_t>(CGDisplayModeGetPixelWidth(mode), 1));
    const std::uint32_t height = static_cast<std::uint32_t>(std::max<std::size_t>(CGDisplayModeGetPixelHeight(mode), 1));
    CFRelease(mode);

    NSDictionary *surfaceProperties = @{
        (NSString *) kIOSurfaceWidth: @(width),
        (NSString *) kIOSurfaceHeight: @(height),
        (NSString *) kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
        (NSString *) kIOSurfaceBytesPerElement: @4,
    };
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef) surfaceProperties);
    if (surface == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:3
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Failed to allocate the probe IOSurface."
                                     }];
        }
        return nil;
    }

    const std::uint32_t optionsBits = requestExtendedRange ? MDKPrivateCaptureExtendedRangeBit : 0;
    const std::uint32_t connectionID = MDKMainConnectionID();
    std::uint32_t captureValue = 0;
    std::uint32_t sampleWord = 0;
    std::uint64_t iterationCount = 0;
    std::uint64_t populatedFrameCount = 0;
    int status = 0;
    BOOL proxiedFrameAvailable = NO;
    const mach_port_t surfacePort = useDirectProxy ? IOSurfaceCreateMachPort(surface) : MACH_PORT_NULL;
    if (useDirectProxy && surfacePort == MACH_PORT_NULL) {
        CFRelease(surface);
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:4
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Failed to create a mach port for the probe IOSurface."
                                     }];
        }
        return nil;
    }

    const CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    const CFAbsoluteTime targetDuration = benchmarkMode ? std::max(sampleDuration, 0.001) : 0.0;

    do {
        captureValue = 0;
        proxiedFrameAvailable = NO;
        if (useDirectProxy) {
            status = proxySymbol(
                connectionID,
                static_cast<std::uint32_t>(displayID),
                optionsBits,
                surfacePort,
                &captureValue,
                &proxiedFrameAvailable
            );
        } else {
            status = symbol(
                connectionID,
                static_cast<std::uint32_t>(displayID),
                optionsBits,
                surface,
                &captureValue
            );
        }
        iterationCount += 1;

        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
        const auto *baseAddress = static_cast<const std::uint32_t *>(IOSurfaceGetBaseAddress(surface));
        sampleWord = baseAddress != nullptr ? baseAddress[0] : 0;
        if (sampleWord != 0 && (!useDirectProxy || proxiedFrameAvailable)) {
            populatedFrameCount += 1;
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);

        if (!benchmarkMode || status != 0) {
            break;
        }
    } while ((CFAbsoluteTimeGetCurrent() - startedAt) < targetDuration);

    const CFAbsoluteTime elapsed = std::max(CFAbsoluteTimeGetCurrent() - startedAt, 0.0);
    const BOOL surfacePopulated = sampleWord != 0 && (!useDirectProxy || proxiedFrameAvailable);
    const std::size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    const OSType pixelFormat = IOSurfaceGetPixelFormat(surface);
    const std::size_t surfaceWidth = IOSurfaceGetWidth(surface);
    const std::size_t surfaceHeight = IOSurfaceGetHeight(surface);
    if (surfacePort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), surfacePort);
    }
    CFRelease(surface);

    if (status != 0 && error != nullptr) {
        *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                     code:status
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: benchmarkMode
                                         ? @"The private IOSurface capture benchmark returned a non-zero status."
                                         : @"The private IOSurface capture probe returned a non-zero status."
                                 }];
    }

    NSMutableArray<NSString *> *notes = [NSMutableArray arrayWithObject:
        useDirectProxy
            ? @"Uses SLSHWCaptureDisplayIntoIOSurfaceProxying with a reused IOSurface mach port."
            : @"Uses CGSHWCaptureDisplayIntoIOSurfaceWithOptions with option bits and a direct IOSurface target."
    ];
    if (requestExtendedRange) {
        [notes addObject:@"Extended-range capture was requested with the 0x00200000 private option bit."];
    } else {
        [notes addObject:@"The probe is running in the SDR-safe private capture mode."];
    }
    if (benchmarkMode) {
        [notes addObject:@"The benchmark reuses a single IOSurface to avoid per-frame allocation noise."];
    }
    if (useDirectProxy) {
        [notes addObject:@"The benchmark reuses one IOSurface mach port for the full sample window to avoid wrapper-side port churn."];
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"entryPoint": useDirectProxy
            ? @"sls-display-iosurface-proxying"
            : @"cgshw-display-iosurface-with-options",
        @"connectionID": @(connectionID),
        @"displayID": @(displayID),
        @"surfaceWidth": @(surfaceWidth),
        @"surfaceHeight": @(surfaceHeight),
        @"bytesPerRow": @(bytesPerRow),
        @"pixelFormat": @(pixelFormat),
        @"sampleWord": @(sampleWord),
        @"captureValue": @(captureValue),
        @"status": @(status),
        @"surfacePopulated": @(surfacePopulated),
        @"requestedExtendedRange": @(requestExtendedRange),
        @"extendedRangeApplied": @(requestExtendedRange && status == 0),
        @"proxiedFrameAvailable": @(proxiedFrameAvailable),
        @"notes": notes
    } mutableCopy];

    if (benchmarkMode) {
        const double observedFrameRate = elapsed > 0 ? static_cast<double>(iterationCount) / elapsed : 0;
        const double populatedFrameRate = elapsed > 0 ? static_cast<double>(populatedFrameCount) / elapsed : 0;
        payload[@"sampleDuration"] = @(elapsed);
        payload[@"iterationCount"] = @(iterationCount);
        payload[@"populatedFrameCount"] = @(populatedFrameCount);
        payload[@"observedFrameRate"] = @(observedFrameRate);
        payload[@"populatedFrameRate"] = @(populatedFrameRate);
    }

    return payload;
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateCaptureSingleFrame(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSError * _Nullable * _Nullable error
) {
    return MDKCreatePrivateCaptureSurfacePayload(displayID, requestExtendedRange, error, NO, 0, NO);
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateCaptureBenchmark(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSTimeInterval sampleDuration,
    NSError * _Nullable * _Nullable error
) {
    return MDKCreatePrivateCaptureSurfacePayload(
        displayID,
        requestExtendedRange,
        error,
        YES,
        sampleDuration,
        NO
    );
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateProxyCaptureSingleFrame(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSError * _Nullable * _Nullable error
) {
    return MDKCreatePrivateCaptureSurfacePayload(displayID, requestExtendedRange, error, NO, 0, YES);
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateProxyCaptureBenchmark(
    NSUInteger displayID,
    BOOL requestExtendedRange,
    NSTimeInterval sampleDuration,
    NSError * _Nullable * _Nullable error
) {
    return MDKCreatePrivateCaptureSurfacePayload(
        displayID,
        requestExtendedRange,
        error,
        YES,
        sampleDuration,
        YES
    );
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateDisplayStreamProbe(
    NSUInteger displayID,
    NSError * _Nullable * _Nullable error
) {
    return MDKShimVideoPrivateDisplayStreamProbeWithParameters(displayID, 0, 0, 0, error);
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoPrivateDisplayStreamProbeWithParameters(
    NSUInteger displayID,
    NSInteger streamPropertiesProfile,
    NSInteger portMode,
    NSInteger selectiveSharingMode,
    NSError * _Nullable * _Nullable error
) {
    using MDKPrivateDisplayStreamCreateProxyFn =
        int (*)(std::int32_t, std::int32_t, std::int32_t, std::int32_t, CFDictionaryRef, mach_port_t, std::uint64_t, std::uint64_t);
    auto symbol = reinterpret_cast<MDKPrivateDisplayStreamCreateProxyFn>(
        MDKLookupScreenCaptureKitSymbol("SLSDisplayStreamCreateProxying")
    );
    if (symbol == nullptr) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:5
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"SLSDisplayStreamCreateProxying is unavailable."
                                     }];
        }
        return nil;
    }

    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(static_cast<CGDirectDisplayID>(displayID));
    if (mode == nil) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:6
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to resolve the current display mode for the private display stream probe."
                                     }];
        }
        return nil;
    }

    const std::int32_t width = static_cast<std::int32_t>(std::max<std::size_t>(CGDisplayModeGetPixelWidth(mode), 1));
    const std::int32_t height = static_cast<std::int32_t>(std::max<std::size_t>(CGDisplayModeGetPixelHeight(mode), 1));
    const CGFloat logicalWidth = static_cast<CGFloat>(std::max<std::size_t>(CGDisplayModeGetWidth(mode), 1));
    const CGFloat logicalHeight = static_cast<CGFloat>(std::max<std::size_t>(CGDisplayModeGetHeight(mode), 1));
    CFRelease(mode);

    NSError *portError = nil;
    const mach_port_t port = MDKCreateProbePortWithMode(portMode, &portError);
    if (port == MACH_PORT_NULL) {
        if (error != nullptr) {
            *error = portError;
        }
        return nil;
    }

    const std::int32_t pixelFormat = static_cast<std::int32_t>(kCVPixelFormatType_32BGRA);
    NSDictionary *minimalProperties = @{
        (__bridge NSString *) kCGDisplayStreamShowCursor: @NO,
        (__bridge NSString *) kCGDisplayStreamMinimumFrameTime: @0,
        (__bridge NSString *) kCGDisplayStreamSourceRect: (__bridge_transfer NSDictionary *) CGRectCreateDictionaryRepresentation(
            CGRectMake(0, 0, logicalWidth, logicalHeight)
        ),
        (__bridge NSString *) kCGDisplayStreamDestinationRect: (__bridge_transfer NSDictionary *) CGRectCreateDictionaryRepresentation(
            CGRectMake(0, 0, width, height)
        ),
        (__bridge NSString *) kCGDisplayStreamPreserveAspectRatio: @NO,
        (__bridge NSString *) kCGDisplayStreamQueueDepth: @3,
    };
    NSDictionary *rectlessMinimalProperties = @{
        (__bridge NSString *) kCGDisplayStreamShowCursor: @NO,
        (__bridge NSString *) kCGDisplayStreamMinimumFrameTime: @0,
        (__bridge NSString *) kCGDisplayStreamPreserveAspectRatio: @NO,
        (__bridge NSString *) kCGDisplayStreamQueueDepth: @3,
    };
    NSDictionary *timedMinimalProperties = @{
        (__bridge NSString *) kCGDisplayStreamShowCursor: @NO,
        (__bridge NSString *) kCGDisplayStreamMinimumFrameTime: @((1.0 / 120.0)),
        (__bridge NSString *) kCGDisplayStreamSourceRect: (__bridge_transfer NSDictionary *) CGRectCreateDictionaryRepresentation(
            CGRectMake(0, 0, logicalWidth, logicalHeight)
        ),
        (__bridge NSString *) kCGDisplayStreamDestinationRect: (__bridge_transfer NSDictionary *) CGRectCreateDictionaryRepresentation(
            CGRectMake(0, 0, width, height)
        ),
        (__bridge NSString *) kCGDisplayStreamPreserveAspectRatio: @NO,
        (__bridge NSString *) kCGDisplayStreamQueueDepth: @2,
    };
    NSMutableDictionary *fullProperties = [minimalProperties mutableCopy];
    fullProperties[@"IOSurfaceProperties"] = @{};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace != nil) {
        fullProperties[(__bridge NSString *) kCGDisplayStreamColorSpace] = (__bridge id) colorSpace;
    }
    NSDictionary *streamProperties = nil;
    switch (streamPropertiesProfile) {
        case 1:
            streamProperties = rectlessMinimalProperties;
            break;
        case 2:
            streamProperties = timedMinimalProperties;
            break;
        case 3:
            streamProperties = nil;
            break;
        case 4:
            streamProperties = fullProperties;
            break;
        case 0:
        default:
            streamProperties = minimalProperties;
            break;
    }
    if (colorSpace != nil) {
        CFRelease(colorSpace);
    }
    std::uint64_t selectiveSharingHi = 0;
    std::uint64_t selectiveSharingLo = 0;
    switch (selectiveSharingMode) {
        case 1:
            selectiveSharingHi = static_cast<std::uint64_t>(displayID);
            selectiveSharingLo = static_cast<std::uint64_t>(displayID);
            break;
        case 2:
            selectiveSharingHi = 0xA5A5A5A5A5A5A5A5ULL;
            selectiveSharingLo = 0x5A5A5A5A5A5A5A5AULL;
            break;
        case 0:
        default:
            break;
    }
    const int status = symbol(
        static_cast<std::int32_t>(displayID),
        width,
        height,
        pixelFormat,
        (__bridge CFDictionaryRef) streamProperties,
        port,
        selectiveSharingHi,
        selectiveSharingLo
    );
    usleep(100 * 1000);

    NSDictionary<NSString *, id> *portSnapshot = MDKCreateMachPortSnapshot(port);
    MDKDisposeProbePort(port);

    NSString *profileLabel = @"minimal";
    switch (streamPropertiesProfile) {
        case 1:
            profileLabel = @"rectless-minimal";
            break;
        case 2:
            profileLabel = @"timed-minimal";
            break;
        case 3:
            profileLabel = @"nil";
            break;
        case 4:
            profileLabel = @"full-public";
            break;
        default:
            break;
    }

    NSString *portModeLabel = @"receive-send";
    switch (portMode) {
        case 1:
            portModeLabel = @"receive-only";
            break;
        default:
            break;
    }

    NSString *selectiveSharingLabel = @"zero";
    switch (selectiveSharingMode) {
        case 1:
            selectiveSharingLabel = @"display-id";
            break;
        case 2:
            selectiveSharingLabel = @"fixed-nonzero";
            break;
        default:
            break;
    }

    if (status != 0 && error != nullptr) {
        *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                     code:status
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: @"SLSDisplayStreamCreateProxying returned a non-zero status."
                                 }];
    }

    return @{
        @"entryPoint": @"sls-display-stream-proxying",
        @"displayID": @(displayID),
        @"surfaceWidth": @(width),
        @"surfaceHeight": @(height),
        @"bytesPerRow": @0,
        @"pixelFormat": @(static_cast<std::uint32_t>(pixelFormat)),
        @"sampleWord": @0,
        @"status": @(status),
        @"surfacePopulated": @NO,
        @"requestedExtendedRange": @NO,
        @"extendedRangeApplied": @NO,
        @"streamPropertiesProfile": profileLabel,
        @"portMode": portModeLabel,
        @"selectiveSharingMode": selectiveSharingLabel,
        @"selectiveSharingHigh": @(selectiveSharingHi),
        @"selectiveSharingLow": @(selectiveSharingLo),
        @"notes": @[
            @"Uses SLSDisplayStreamCreateProxying with the current pixel size and a configurable CGDisplayStream-style properties dictionary.",
            @"The probe only verifies stream creation status and whether the supplied port shows activity after the create call."
        ],
        @"portStatus": portSnapshot[@"portStatus"] ?: @0,
        @"portTypeStatus": portSnapshot[@"portTypeStatus"] ?: @0,
        @"portType": portSnapshot[@"portType"] ?: @0,
        @"portMessageCount": portSnapshot[@"portMessageCount"] ?: @0,
        @"portQueueLimit": portSnapshot[@"portQueueLimit"] ?: @0,
        @"portSequenceNumber": portSnapshot[@"portSequenceNumber"] ?: @0,
        @"portMessagesWaiting": portSnapshot[@"portMessagesWaiting"] ?: @NO,
    };
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoTraceScreenCaptureKitProxyHandshake(
    NSUInteger displayID,
    NSTimeInterval timeout,
    NSError * _Nullable * _Nullable error
) {
    return MDKCreateSCKProxyHandshakeTrace(displayID, timeout, YES, error);
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoTraceScreenCaptureKitPassiveHandshake(
    NSUInteger displayID,
    NSTimeInterval timeout,
    NSError * _Nullable * _Nullable error
) {
    return MDKCreateSCKProxyHandshakeTrace(displayID, timeout, NO, error);
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoTraceScreenCaptureKitTiming(
    NSUInteger displayID,
    NSTimeInterval timeout,
    NSError * _Nullable * _Nullable error
) {
    return MDKCreateSCKPublicTimingTrace(displayID, timeout, error);
}

NSDictionary<NSString *, id> * _Nullable MDKShimVideoInspectScreenCaptureKitRuntime(
    NSError * _Nullable * _Nullable error
) {
    MDKEnsureCaptureImageLoaded("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit");
    MDKEnsureCaptureImageLoaded("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture");

    NSArray<NSString *> *classNames = @[
        @"SCStream",
        @"SCStreamManager",
        @"SCRemoteQueueXPCObject",
        @"RPDaemonProxy",
        @"BWRemoteQueueSinkNode",
        @"FigCaptureRemoteQueueSinkPipeline",
    ];
    NSArray<NSString *> *screenCaptureKitSymbolNames = @[
        @"SCRemoteQueue_CreateReceiverQueue",
        @"SCRemoteQueue_UpdateReceiverQueue",
        @"SCRemoteQueue_Destroy",
        @"SCRemoteQueue_Dequeue",
        @"SCRemoteQueue_CopyLatestItem",
        @"SCRemoteQueue_CopyCurrentItem",
        @"SCRemoteQueue_ProcessPendingItems",
        @"SCRemoteQueue_Drain",
        @"SCRemoteQueue_Resume",
        @"SCRemoteQueue_Start",
        @"SCRemoteQueue_StartReceiving",
    ];
    NSArray<NSString *> *cmCaptureSymbolNames = @[
        @"FigRemoteQueueReceiverCreateFromXPCObject",
        @"FigRemoteQueueReceiverSetHandler",
        @"FigRemoteQueueReceiverUnsetHandler",
        @"FigRemoteQueueReceiverDequeue",
        @"FigRemoteQueueReceiverDrain",
        @"FigRemoteQueueReceiverResume",
        @"FigRemoteQueueReceiverStart",
        @"FigRemoteQueueReceiverCopyCurrentItem",
        @"FigRemoteQueueReceiverCopyLatestItem",
    ];

    NSMutableArray<NSDictionary<NSString *, id> *> *classes = [NSMutableArray arrayWithCapacity:classNames.count];
    for (NSString *className in classNames) {
        NSArray<NSString *> *methods = MDKFilteredMethodNamesForRuntimeClass(className);
        [classes addObject:@{
            @"className": className,
            @"loaded": @(NSClassFromString(className) != Nil),
            @"filteredMethods": methods,
            @"filteredMethodCount": @(methods.count),
        }];
    }

    NSDictionary<NSString *, NSNumber *> *screenCaptureKitSymbols =
        MDKRuntimeSymbolAvailabilityForNames(screenCaptureKitSymbolNames, NO);
    NSDictionary<NSString *, NSNumber *> *cmCaptureSymbols =
        MDKRuntimeSymbolAvailabilityForNames(cmCaptureSymbolNames, YES);

    NSDictionary<NSString *, id> *payload = @{
        @"classes": classes,
        @"screenCaptureKitSymbols": screenCaptureKitSymbols,
        @"cmCaptureSymbols": cmCaptureSymbols,
        @"notes": @[
            @"Lists keyword-filtered Objective-C methods for the loaded ScreenCaptureKit runtime classes.",
            @"Lists the presence of guessed private queue symbols so host-only experiments can pick likely next entry points."
        ],
    };

    if (classes.count == 0 && screenCaptureKitSymbols.count == 0 && cmCaptureSymbols.count == 0) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"MacDisplayKit.PrivateCapture"
                                         code:16
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: @"Unable to inspect the ScreenCaptureKit runtime."
                                     }];
        }
        return nil;
    }

    return payload;
}

NSArray<NSString *> *MDKShimMicrophoneNames(void) {
    return [AVAudio microphoneNames];
}

NSString * _Nullable MDKShimCreateVirtualDisplay(
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
) {
    const std::string displayID = VDISPLAY::createVirtualDisplay(
        clientIdentifier.UTF8String,
        clientName.UTF8String,
        static_cast<std::uint32_t>(logicalWidth),
        static_cast<std::uint32_t>(logicalHeight),
        static_cast<std::uint32_t>(refreshRateMilliHz),
        static_cast<int>(scaleFactor),
        hiDPI,
        hdrEnabled,
        static_cast<int>(displayGamut),
        static_cast<int>(displayTransfer)
    );

    if (displayID.empty()) {
        return nil;
    }

    return [NSString stringWithUTF8String:displayID.c_str()];
}

BOOL MDKShimUpdateVirtualDisplay(
    NSString *clientIdentifier,
    NSUInteger logicalWidth,
    NSUInteger logicalHeight,
    NSUInteger refreshRateMilliHz,
    NSInteger displayTransfer
) {
    return VDISPLAY::updateVirtualDisplayMode(
        std::string(clientIdentifier.UTF8String ?: ""),
        static_cast<std::uint32_t>(logicalWidth),
        static_cast<std::uint32_t>(logicalHeight),
        static_cast<std::uint32_t>(refreshRateMilliHz),
        static_cast<int>(displayTransfer)
    );
}

BOOL MDKShimRemoveVirtualDisplay(NSString *clientIdentifier) {
    return VDISPLAY::removeVirtualDisplay(std::string(clientIdentifier.UTF8String ?: ""));
}
