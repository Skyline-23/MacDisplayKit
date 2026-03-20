#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>

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
