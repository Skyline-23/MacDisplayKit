#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "MDKObjCShim.h"

#include <algorithm>

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
