#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <xpc/xpc.h>

#import "MDKObjCShim.h"

#include <algorithm>
#include <cstdint>

#import "../LegacyRuntime/Capture/av_audio.h"
#import "../LegacyRuntime/Capture/av_video.h"
#include "../LegacyRuntime/VirtualDisplay/virtual_display.h"

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

@implementation MDKShimStreamOutputCollector

- (void)stream:(__unused id)stream
didOutputSampleBuffer:(__unused id)sampleBuffer
        ofType:(__unused NSInteger)type {
}

@end

static NSMutableDictionary<NSString *, id> *MDKActiveSCKTraceState = nil;
static NSObject *MDKActiveSCKTraceLock = nil;

using MDKProxyCoreGraphicsFn = void (*)(id, SEL, unsigned char, id, id, id);
using MDKStartRemoteQueueFn = void (*)(id, SEL, id, id);
using MDKStartCaptureProxyFn = void (*)(id, SEL, id, id, id, id, id, id, id);
using MDKFetchDisplayFn = void (*)(id, SEL, unsigned int, id);
using MDKUpdateStreamConfigurationFn = void (*)(id, SEL, id, id, id, id, id);
using MDKUpdateStreamContentFilterFn = void (*)(id, SEL, id, id, id, id, id, id);
using MDKStartRemoteReceiveQueueConsumerFn = void (*)(id, SEL, id);

static MDKProxyCoreGraphicsFn MDKOriginalProxyCoreGraphics = nullptr;
static MDKStartRemoteQueueFn MDKOriginalStartRemoteQueue = nullptr;
static MDKStartCaptureProxyFn MDKOriginalStartCaptureProxy = nullptr;
static MDKFetchDisplayFn MDKOriginalFetchDisplay = nullptr;
static MDKUpdateStreamConfigurationFn MDKOriginalUpdateStreamConfiguration = nullptr;
static MDKUpdateStreamContentFilterFn MDKOriginalUpdateStreamContentFilter = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteReceiveQueue = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteVideoReceiveQueue = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteAudioReceiveQueue = nullptr;
static MDKStartRemoteReceiveQueueConsumerFn MDKOriginalStartRemoteMicrophoneReceiveQueue = nullptr;

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

    if ([object isKindOfClass:[NSDictionary class]]) {
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
        } mutableCopy];
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
        @"selector": selector,
        @"notes": notes,
    } mutableCopy];
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

static void MDKRecordRemoteQueueConsumerEvent(NSString *kind, id queue) {
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
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-video-receive-queue", queue);
    MDKOriginalStartRemoteVideoReceiveQueue(self, _cmd, queue);
}

static void MDKSwizzledStartRemoteAudioReceiveQueue(id self, SEL _cmd, id queue) {
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-audio-receive-queue", queue);
    MDKOriginalStartRemoteAudioReceiveQueue(self, _cmd, queue);
}

static void MDKSwizzledStartRemoteMicrophoneReceiveQueue(id self, SEL _cmd, id queue) {
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-microphone-receive-queue", queue);
    MDKOriginalStartRemoteMicrophoneReceiveQueue(self, _cmd, queue);
}

static void MDKInstallSCKProxyTraceHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_NOW | RTLD_GLOBAL);
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
    });
}

static NSDictionary<NSString *, id> * _Nullable MDKCreateSCKProxyHandshakeTrace(
    NSUInteger displayID,
    NSTimeInterval timeout,
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
    usleep(250 * 1000);

    if ([stream respondsToSelector:sel_registerName("stopCaptureWithCompletionHandler:")]) {
        ((void (*)(id, SEL, id)) objc_msgSend)(
            stream,
            sel_registerName("stopCaptureWithCompletionHandler:"),
            ^(__unused NSError * _Nullable stopError) {
            }
        );
    }

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
            [steps addObject:MDKMakeTraceStep(
                @"initial-state",
                @"initWithFilter:configuration:delegate:",
                @"ScreenCaptureKit",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"display=%@", MDKDescribeTraceValue(displaySummary)],
                    [NSString stringWithFormat:@"stream=%@", MDKDescribeTraceValue(streamSummary)],
                    [NSString stringWithFormat:@"filter=%@", MDKDescribeTraceValue(filterSummary)],
                    [NSString stringWithFormat:@"configuration=%@", MDKDescribeTraceValue(configSummary)],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"add-stream-output"]) {
            [selectors addObject:@"addStreamOutput:type:sampleHandlerQueue:error:"];
            NSNumber *succeeded = event[@"outputAdded"];
            [steps addObject:MDKMakeTraceStep(
                @"add-stream-output",
                @"addStreamOutput:type:sampleHandlerQueue:error:",
                @"ScreenCaptureKit",
                nil,
                succeeded,
                @[
                    [NSString stringWithFormat:@"errorDomain=%@", MDKDescribeTraceValue(event[@"errorDomain"])],
                    [NSString stringWithFormat:@"errorCode=%@", MDKDescribeTraceValue(event[@"errorCode"])],
                ]
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
            [steps addObject:MDKMakeTraceStep(
                @"start-remote-queue",
                @"startRemoteQueue:streamID:",
                @"RPDaemonProxy",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
                    [NSString stringWithFormat:@"streamID=%@", MDKDescribeTraceValue(event[@"streamID"])],
                ]
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

        if ([kind isEqualToString:@"stream-start-remote-receive-queue"]) {
            [selectors addObject:@"startRemoteReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-receive-queue",
                @"startRemoteReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-start-remote-video-receive-queue"]) {
            [selectors addObject:@"startRemoteVideoReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-video-receive-queue",
                @"startRemoteVideoReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-start-remote-audio-receive-queue"]) {
            [selectors addObject:@"startRemoteAudioReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-audio-receive-queue",
                @"startRemoteAudioReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
                ]
            )];
            continue;
        }

        if ([kind isEqualToString:@"stream-start-remote-microphone-receive-queue"]) {
            [selectors addObject:@"startRemoteMicrophoneReceiveQueue:"];
            [symbols addObject:@"SCStream"];
            [steps addObject:MDKMakeTraceStep(
                @"stream-start-remote-microphone-receive-queue",
                @"startRemoteMicrophoneReceiveQueue:",
                @"SCStream",
                nil,
                @YES,
                @[
                    [NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])],
                ]
            )];
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

    NSMutableArray<NSString *> *notes = [snapshot[@"notes"] mutableCopy] ?: [NSMutableArray array];
    [notes addObject:[NSString stringWithFormat:@"serializedStreamProperties=%@", MDKDescribeTraceValue(serializedStreamProperties)]];
    [notes addObject:[NSString stringWithFormat:@"serializedFilter=%@", MDKDescribeTraceValue(serializedFilter)]];
    const BOOL succeeded = [snapshot[@"sawProxyCoreGraphics"] boolValue] && startError == nil;
    const std::int32_t status = startError != nil ? static_cast<std::int32_t>(startError.code) : (succeeded ? 0 : 1);
    if (startError != nil) {
        [notes addObject:[NSString stringWithFormat:@"Public SCStream start failed: %@", startError.localizedDescription ?: @"<unknown>"]];
    } else if (succeeded) {
        [notes addObject:@"Public SCStream start completed and reached RPDaemonProxy proxyCoreGraphicsWithMethodType:config:machPort:completionHandler:."];
    } else {
        [notes addObject:@"Public SCStream start completed but the trace did not observe RPDaemonProxy proxyCoreGraphicsWithMethodType:config:machPort:completionHandler: before timeout."];
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
    return MDKCreateSCKProxyHandshakeTrace(displayID, timeout, error);
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
