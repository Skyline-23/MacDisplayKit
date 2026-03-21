#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <malloc/malloc.h>
#import <poll.h>
#import <pthread.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/ioctl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <xpc/xpc.h>
#import <mach-o/loader.h>
#import <dispatch/dispatch.h>

#import "MDKObjCShim.h"

#include <algorithm>
#include <atomic>
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

struct MDKDyldInterposeTuple {
    const void *replacement;
    const void *replacee;
};

static const mach_header *MDKFindLoadedImageHeader(const char *needle) {
    if (needle == nullptr) {
        return nullptr;
    }

    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index += 1) {
        const char *imageName = _dyld_get_image_name(index);
        if (imageName == nullptr || strstr(imageName, needle) == nullptr) {
            continue;
        }

        return _dyld_get_image_header(index);
    }

    return nullptr;
}

static void MDKInstallRuntimeFigRemoteQueueReceiverInterposes(void);
static NSString *MDKCopyBlockSignatureString(id block);
static NSDictionary<NSString *, id> *MDKDescribeBlockLiteralObject(id block);
static NSArray<NSDictionary<NSString *, id> *> *MDKDescribePointerWords(const void *pointer, size_t allocationSize, size_t maxWordCount);
static NSDictionary<NSString *, id> *MDKSummarizeObject(id object);
static void MDKRescanNestedVideoQueueBlockIfPossible(id stream, NSString *reason);

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
            @"drain",
            @"dequeue",
            @"handler",
            @"process",
            @"item",
            @"message",
            @"sink",
            @"render",
            @"receiver",
            @"pipeline",
            @"source",
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

static NSDictionary<NSString *, id> *MDKDescribeCodePointer(const void *pointer) {
    if (pointer == nullptr) {
        return @{
            @"present": @NO,
        };
    }

    NSMutableDictionary<NSString *, id> *summary = [@{
        @"present": @YES,
        @"pointer": [NSString stringWithFormat:@"%p", pointer],
    } mutableCopy];

    Dl_info info = {};
    if (dladdr(pointer, &info) != 0) {
        if (info.dli_fname != nullptr) {
            summary[@"imagePath"] = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
        }
        if (info.dli_fbase != nullptr) {
            summary[@"imageBase"] = [NSString stringWithFormat:@"%p", info.dli_fbase];
            summary[@"imageOffset"] = @(
                reinterpret_cast<uintptr_t>(pointer) - reinterpret_cast<uintptr_t>(info.dli_fbase)
            );
        }
        if (info.dli_sname != nullptr) {
            summary[@"symbolName"] = [NSString stringWithUTF8String:info.dli_sname] ?: @"";
        }
        if (info.dli_saddr != nullptr) {
            summary[@"symbolAddress"] = [NSString stringWithFormat:@"%p", info.dli_saddr];
            summary[@"symbolOffset"] = @(
                reinterpret_cast<uintptr_t>(pointer) - reinterpret_cast<uintptr_t>(info.dli_saddr)
            );
        }
    }

    return summary;
}

static NSDictionary<NSString *, id> *MDKDescribeShallowPointerPointee(const void *pointer) {
    if (pointer == nullptr) {
        return nil;
    }

    const size_t allocationSize = malloc_size(const_cast<void *>(pointer));
    if (allocationSize == 0) {
        return nil;
    }

    NSMutableDictionary<NSString *, id> *summary = [@{
        @"mallocSize": @(allocationSize),
    } mutableCopy];

    uintptr_t firstWordRawValue = 0;
    memcpy(&firstWordRawValue, pointer, sizeof(firstWordRawValue));
    if (firstWordRawValue != 0) {
        const void *firstWordPointer = reinterpret_cast<const void *>(firstWordRawValue);
        NSDictionary<NSString *, id> *firstWordCodePointer = MDKDescribeCodePointer(firstWordPointer);
        if ([firstWordCodePointer[@"present"] boolValue]) {
            summary[@"word0CodePointer"] = firstWordCodePointer;
        }

        NSString *word0Symbol =
            [firstWordCodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? firstWordCodePointer[@"symbolName"] : nil;
        if (word0Symbol != nil) {
            if ([word0Symbol hasPrefix:@"OBJC_CLASS_$"] || [word0Symbol hasPrefix:@"OBJC_METACLASS_$"]) {
                @try {
                    NSMutableDictionary<NSString *, id> *objectSummary =
                        [[MDKSummarizeObject((__bridge id) pointer) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
                    NSString *className =
                        [objectSummary[@"className"] isKindOfClass:[NSString class]] ? objectSummary[@"className"] : nil;
                    if (className != nil &&
                        ([className hasPrefix:@"OS_dispatch_"] || [className isEqualToString:@"__NSCFType"])) {
                        NSString *description = [(__bridge id) pointer description];
                        if ([description isKindOfClass:[NSString class]] && description.length > 0) {
                            objectSummary[@"description"] = description;
                        }
                        if ([className isEqualToString:@"OS_dispatch_source"]) {
                            dispatch_source_t source = (__bridge dispatch_source_t) const_cast<void *>(pointer);
                            uintptr_t sourceHandle = dispatch_source_get_handle(source);
                            objectSummary[@"dispatchSourceHandle"] = @(sourceHandle);
                            objectSummary[@"dispatchSourceMask"] = @(dispatch_source_get_mask(source));
                            objectSummary[@"dispatchSourceData"] = @(dispatch_source_get_data(source));
                            objectSummary[@"dispatchSourceCancelled"] = @(dispatch_source_testcancel(source));
                            objectSummary[@"dispatchSourceWords"] = MDKDescribePointerWords(pointer, allocationSize, 12);
                            const void *sourceContext = dispatch_get_context((dispatch_object_t) source);
                            if (sourceContext != nullptr) {
                                objectSummary[@"dispatchSourceContextPointer"] =
                                    [NSString stringWithFormat:@"%p", sourceContext];
                                if (sourceContext != pointer) {
                                    NSDictionary<NSString *, id> *sourceContextPointee =
                                        MDKDescribeShallowPointerPointee(sourceContext);
                                    if (sourceContextPointee != nil) {
                                        objectSummary[@"dispatchSourceContextPointee"] = sourceContextPointee;
                                    }
                                }
                            }
                            if (sourceHandle <= INT_MAX) {
                                const int fd = static_cast<int>(sourceHandle);
                                struct stat fdStat = {};
                                if (fstat(fd, &fdStat) == 0) {
                                    NSString *fileType = @"unknown";
                                    if (S_ISREG(fdStat.st_mode)) {
                                        fileType = @"regular";
                                    } else if (S_ISDIR(fdStat.st_mode)) {
                                        fileType = @"directory";
                                    } else if (S_ISCHR(fdStat.st_mode)) {
                                        fileType = @"character-device";
                                    } else if (S_ISBLK(fdStat.st_mode)) {
                                        fileType = @"block-device";
                                    } else if (S_ISFIFO(fdStat.st_mode)) {
                                        fileType = @"fifo";
                                    } else if (S_ISLNK(fdStat.st_mode)) {
                                        fileType = @"symlink";
                                    } else if (S_ISSOCK(fdStat.st_mode)) {
                                        fileType = @"socket";
                                    }
                                    objectSummary[@"dispatchSourceHandleFileType"] = fileType;
                                    objectSummary[@"dispatchSourceHandleMode"] = @(fdStat.st_mode);
                                }
#ifdef F_GETPATH
                                char pathBuffer[PATH_MAX] = {};
                                if (fcntl(fd, F_GETPATH, pathBuffer) != -1 && pathBuffer[0] != '\0') {
                                    objectSummary[@"dispatchSourceHandlePath"] =
                                        [NSString stringWithUTF8String:pathBuffer] ?: @"";
                                }
#endif
                            }
                        }
                    }
                    summary[@"object"] = objectSummary;
                } @catch (__unused NSException *exception) {
                }
            } else if ([word0Symbol containsString:@"Block"]) {
                @try {
                    summary[@"block"] = MDKDescribeBlockLiteralObject((__bridge id) pointer);
                } @catch (__unused NSException *exception) {
                }
            }
        }
    }

    return summary;
}

static NSArray<NSDictionary<NSString *, id> *> *MDKDescribePointerWords(
    const void *pointer,
    size_t allocationSize,
    size_t maxWordCount
) {
    if (pointer == nullptr || allocationSize < sizeof(uintptr_t) || maxWordCount == 0) {
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *words = [NSMutableArray array];
    const uint8_t *base = reinterpret_cast<const uint8_t *>(pointer);
    const size_t availableWordCount = std::min(maxWordCount, allocationSize / sizeof(uintptr_t));
    for (size_t index = 0; index < availableWordCount; index += 1) {
        uintptr_t rawValue = 0;
        memcpy(&rawValue, base + (index * sizeof(uintptr_t)), sizeof(rawValue));

        NSMutableDictionary<NSString *, id> *word = [@{
            @"index": @(index),
            @"offset": @(index * sizeof(uintptr_t)),
            @"rawValueHex": [NSString stringWithFormat:@"0x%0*llx", static_cast<int>(sizeof(uintptr_t) * 2), static_cast<unsigned long long>(rawValue)],
        } mutableCopy];
        if (rawValue != 0) {
            const void *wordPointer = reinterpret_cast<const void *>(rawValue);
            word[@"pointer"] = [NSString stringWithFormat:@"%p", wordPointer];
            NSDictionary<NSString *, id> *codePointer = MDKDescribeCodePointer(wordPointer);
            if ([codePointer[@"present"] boolValue]) {
                word[@"codePointer"] = codePointer;
            }
            NSDictionary<NSString *, id> *shallowPointee = MDKDescribeShallowPointerPointee(wordPointer);
            if (shallowPointee != nil) {
                word[@"pointee"] = shallowPointee;
            }
        } else {
            word[@"pointer"] = @"";
        }

        [words addObject:word];
    }

    return words;
}

static NSArray<NSDictionary<NSString *, id> *> *MDKDescribeBlockCaptureSlots(
    const MDKBlockLiteral *literal,
    size_t allocationSize,
    size_t logicalSize
) {
    if (literal == nullptr || logicalSize <= sizeof(MDKBlockLiteral) || allocationSize < sizeof(MDKBlockLiteral)) {
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *slots = [NSMutableArray array];
    const uint8_t *base = reinterpret_cast<const uint8_t *>(literal);
    const size_t endOffset = std::min(logicalSize, allocationSize);
    for (size_t offset = sizeof(MDKBlockLiteral); offset + sizeof(uintptr_t) <= endOffset; offset += sizeof(uintptr_t)) {
        uintptr_t rawValue = 0;
        memcpy(&rawValue, base + offset, sizeof(rawValue));
        NSMutableDictionary<NSString *, id> *slot = [@{
            @"offset": @(offset),
            @"rawValueHex": [NSString stringWithFormat:@"0x%0*llx", static_cast<int>(sizeof(uintptr_t) * 2), static_cast<unsigned long long>(rawValue)],
        } mutableCopy];
        if (rawValue != 0) {
            const void *slotPointer = reinterpret_cast<const void *>(rawValue);
            slot[@"pointer"] = [NSString stringWithFormat:@"%p", slotPointer];
            NSDictionary<NSString *, id> *codePointer = MDKDescribeCodePointer(slotPointer);
            if ([codePointer[@"present"] boolValue]) {
                slot[@"codePointer"] = codePointer;
            }
            size_t pointeeAllocationSize = malloc_size(const_cast<void *>(slotPointer));
            if (pointeeAllocationSize > 0) {
                slot[@"pointeeMallocSize"] = @(pointeeAllocationSize);
                NSArray<NSDictionary<NSString *, id> *> *pointeeWords =
                    MDKDescribePointerWords(slotPointer, pointeeAllocationSize, 4);
                if (pointeeWords.count > 0) {
                    slot[@"pointeeWords"] = pointeeWords;
                    NSDictionary<NSString *, id> *word0 =
                        [pointeeWords[0] isKindOfClass:[NSDictionary class]] ? pointeeWords[0] : nil;
                    NSDictionary<NSString *, id> *word0CodePointer =
                        [word0[@"codePointer"] isKindOfClass:[NSDictionary class]] ? word0[@"codePointer"] : nil;
                    NSString *word0Symbol =
                        [word0CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? word0CodePointer[@"symbolName"] : nil;
                    if (word0Symbol != nil && [word0Symbol containsString:@"Block"]) {
                        slot[@"pointeeBlock"] = MDKDescribeBlockLiteralObject((__bridge id) slotPointer);
                    }
                }
            }
        } else {
            slot[@"pointer"] = @"";
        }
        [slots addObject:slot];
    }
    return slots;
}

static NSDictionary<NSString *, id> *MDKDescribeBlockLiteralObject(id block) {
    if (block == nil) {
        return @{
            @"present": @NO,
        };
    }

    const auto *literal = (__bridge const MDKBlockLiteral *) block;
    if (literal == nullptr) {
        return @{
            @"present": @NO,
        };
    }

    size_t allocationSize = malloc_size((__bridge const void *) block);
    size_t logicalSize = allocationSize;
    NSMutableDictionary<NSString *, id> *summary = [@{
        @"present": @YES,
        @"pointer": [NSString stringWithFormat:@"%p", (__bridge const void *) block],
        @"flags": @(literal->flags),
    } mutableCopy];

    if (allocationSize > 0) {
        summary[@"mallocSize"] = @(allocationSize);
    }

    NSString *signature = MDKCopyBlockSignatureString(block);
    if (signature != nil) {
        summary[@"signature"] = signature;
    }

    summary[@"invoke"] = MDKDescribeCodePointer(reinterpret_cast<const void *>(literal->invoke));
    summary[@"hasCopyDispose"] = @((literal->flags & MDKBlockHasCopyDispose) != 0);
    summary[@"hasSignature"] = @((literal->flags & MDKBlockHasSignature) != 0);

    if (literal->descriptor != nullptr) {
        summary[@"descriptorPointer"] = [NSString stringWithFormat:@"%p", literal->descriptor];
        if (literal->descriptor->size > 0) {
            logicalSize = literal->descriptor->size;
            summary[@"logicalSize"] = @(logicalSize);
        }
    }

    NSArray<NSDictionary<NSString *, id> *> *captureSlots =
        MDKDescribeBlockCaptureSlots(literal, allocationSize, logicalSize);
    if (captureSlots.count > 0) {
        summary[@"captureSlots"] = captureSlots;
    }

    return summary;
}

static NSArray<NSString *> *MDKDynamicRuntimeClassNamesMatchingKeywords(void) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"queue",
            @"receiver",
            @"sink",
            @"drain",
            @"dequeue",
            @"sample",
            @"surface",
            @"stream",
            @"capture",
            @"frame",
            @"remote",
            @"handler",
            @"consumer",
            @"pipeline",
        ];
    });

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (classes == nullptr || classCount == 0) {
        return @[];
    }

    NSMutableSet<NSString *> *matches = [NSMutableSet set];
    for (unsigned int index = 0; index < classCount; index += 1) {
        Class cls = classes[index];
        if (cls == Nil) {
            continue;
        }

        NSString *className = NSStringFromClass(cls);
        if (className.length == 0) {
            continue;
        }

        NSString *lowercaseClassName = className.lowercaseString;
        BOOL matched = NO;
        for (NSString *keyword in keywords) {
            if ([lowercaseClassName containsString:keyword]) {
                matched = YES;
                break;
            }
        }
        if (!matched) {
            continue;
        }

        if (![className hasPrefix:@"SC"] &&
            ![className hasPrefix:@"RP"] &&
            ![className hasPrefix:@"BW"] &&
            ![className hasPrefix:@"Fig"] &&
            ![className hasPrefix:@"CM"] &&
            ![className hasPrefix:@"IOSurface"]) {
            continue;
        }

        [matches addObject:className];
    }

    free(classes);
    return [matches.allObjects sortedArrayUsingSelector:@selector(compare:)];
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
static BOOL MDKActiveSCKAllowVideoQueueWrapperProbe = NO;
static std::atomic<uint64_t> MDKVideoQueueWrapperSequenceCounter{0};
static void *MDKResolvedRQReceiverSetSourceBlockInvokeAddress = nullptr;
static void *MDKResolvedRQReceiverSetSourceBlockInvokeImageHeader = nullptr;
static void *MDKResolvedDispatchSourceInvokeAddress = nullptr;
static void *MDKResolvedDispatchSourceInvokeImageHeader = nullptr;
static void *MDKResolvedDispatchSourceLatchAndCallAddress = nullptr;
static void *MDKResolvedDispatchSourceLatchAndCallImageHeader = nullptr;
static void *MDKResolvedDispatchClientCalloutAddress = nullptr;
static void *MDKResolvedDispatchClientCalloutImageHeader = nullptr;

namespace {
constexpr size_t MDKVideoQueueWrapperTLSStackCapacity = 16;
thread_local uint64_t MDKVideoQueueWrapperSequenceTLSStack[MDKVideoQueueWrapperTLSStackCapacity] = {};
thread_local size_t MDKVideoQueueWrapperSequenceTLSDepth = 0;
}  // namespace

struct MDKFigRemoteQueueMessage {
    const void *payloadBlock;
    IOSurfaceRef surface;
    int messageType;
};

using MDKFigRemoteQueueReceiverHandlerBlock = void (^)(int, MDKFigRemoteQueueMessage *, void *);
using MDKRQReceiverSetSourceBlockInvokeFn = void (*)(void *);
using MDKDispatchSourceInvokeInternalFn = void (*)(dispatch_source_t, void *, uint32_t);
using MDKDispatchSourceLatchAndCallInternalFn = void (*)(dispatch_source_t, dispatch_queue_t, uint32_t);
using MDKDispatchClientCalloutFn = void (*)(void *, dispatch_function_t);
using MDKDispatchSourceCreateFn = dispatch_source_t (*)(dispatch_source_type_t, uintptr_t, unsigned long, dispatch_queue_t);
using MDKDispatchSourceSetEventHandlerFn = void (*)(dispatch_source_t, dispatch_block_t);
using MDKDispatchSourceSetEventHandlerFFn = void (*)(dispatch_source_t, dispatch_function_t);
using MDKReadFn = ssize_t (*)(int, void *, size_t);
using MDKWriteFn = ssize_t (*)(int, const void *, size_t);
using MDKPipeFn = int (*)(int [2]);
using MDKIOSurfaceLookupFromMachPortFn = IOSurfaceRef (*)(mach_port_t);
using MDKIOSurfaceCreateMachPortFn = mach_port_t (*)(IOSurfaceRef);
using MDKXPCPipeCreateFn = xpc_object_t (*)(const char *, std::uint64_t);
using MDKXPCPipeSimpleRoutineFn = int (*)(xpc_object_t, xpc_object_t, xpc_object_t *);
using MDKXPCFDDupFn = int (*)(xpc_object_t);
using MDKXPCDictionaryDupFDFn = int (*)(xpc_object_t, const char *);
using MDKDispatchSourceHandlerBlockInvokeFn = void (*)(void *);
static MDKRQReceiverSetSourceBlockInvokeFn MDKOriginalRQReceiverSetSourceBlockInvoke = nullptr;
static MDKDispatchSourceInvokeInternalFn MDKOriginalDispatchSourceInvokeInternal = nullptr;
static MDKDispatchSourceLatchAndCallInternalFn MDKOriginalDispatchSourceLatchAndCallInternal = nullptr;
static MDKDispatchClientCalloutFn MDKOriginalDispatchClientCallout = nullptr;
static MDKDispatchSourceCreateFn MDKOriginalDispatchSourceCreate = nullptr;
static MDKDispatchSourceSetEventHandlerFn MDKOriginalDispatchSourceSetEventHandler = nullptr;
static MDKDispatchSourceSetEventHandlerFFn MDKOriginalDispatchSourceSetEventHandlerF = nullptr;
static MDKReadFn MDKOriginalRead = nullptr;
static MDKReadFn MDKOriginalReadNoCancel = nullptr;
static MDKWriteFn MDKOriginalWrite = nullptr;
static MDKWriteFn MDKOriginalWriteNoCancel = nullptr;
static MDKPipeFn MDKOriginalPipe = nullptr;
static MDKIOSurfaceLookupFromMachPortFn MDKOriginalIOSurfaceLookupFromMachPort = nullptr;
static MDKIOSurfaceCreateMachPortFn MDKOriginalIOSurfaceCreateMachPort = nullptr;
static MDKXPCPipeCreateFn MDKOriginalXPCPipeCreate = nullptr;
static MDKXPCPipeSimpleRoutineFn MDKOriginalXPCPipeSimpleRoutine = nullptr;
static MDKXPCFDDupFn MDKOriginalXPCFDDup = nullptr;
static MDKXPCDictionaryDupFDFn MDKOriginalXPCDictionaryDupFD = nullptr;
thread_local NSUInteger MDKInterposedFIFOReadDepth = 0;
thread_local NSUInteger MDKInterposedFIFOWriteDepth = 0;
thread_local NSUInteger MDKInterposedXPCPipeDepth = 0;
thread_local NSUInteger MDKInterposedXPCFDDepth = 0;

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
static int MDKDuplicateVideoRemoteQueueFD(const char *name);
static void MDKObserveVideoRemoteQueueReceiveFD(int receiveFD);
static void MDKObserveVideoRemoteQueueSharedRegion(void);
static void MDKUpdateSCKSampleBufferDiagnostics(CMSampleBufferRef sampleBuffer);
static BOOL MDKPrimeSCRemoteQueueWrapperIfPossible(id remoteQueue);
static BOOL MDKWrapVideoReceiveQueueCallbackIfPossible(id stream);
static NSDictionary<NSString *, id> * _Nullable MDKCopyDispatchReadSourceMetadata(dispatch_source_t source);
static NSString *MDKBucketMilliseconds(double milliseconds);
static void MDKIncrementMutableHistogram(NSMutableDictionary<NSString *, NSNumber *> *histogram, NSString *bucket);
static NSString *MDKClassifyCadenceHistogram(NSDictionary<NSString *, NSNumber *> *histogram, NSUInteger deltaCount);
static NSArray<NSDictionary<NSString *, id> *> *MDKCopyBacktraceFrames(NSUInteger maxFrames, NSUInteger skipFrames);

static uint64_t MDKPushVideoQueueWrapperSequence(void) {
    const uint64_t sequenceID = MDKVideoQueueWrapperSequenceCounter.fetch_add(1, std::memory_order_relaxed) + 1;
    if (MDKVideoQueueWrapperSequenceTLSDepth < MDKVideoQueueWrapperTLSStackCapacity) {
        MDKVideoQueueWrapperSequenceTLSStack[MDKVideoQueueWrapperSequenceTLSDepth] = sequenceID;
    } else {
        MDKVideoQueueWrapperSequenceTLSStack[MDKVideoQueueWrapperTLSStackCapacity - 1] = sequenceID;
    }
    MDKVideoQueueWrapperSequenceTLSDepth += 1;
    return sequenceID;
}

static uint64_t MDKCurrentVideoQueueWrapperSequence(void) {
    if (MDKVideoQueueWrapperSequenceTLSDepth == 0) {
        return 0;
    }

    const size_t index = std::min(MDKVideoQueueWrapperSequenceTLSDepth, MDKVideoQueueWrapperTLSStackCapacity) - 1;
    return MDKVideoQueueWrapperSequenceTLSStack[index];
}

static size_t MDKCurrentVideoQueueWrapperSequenceDepth(void) {
    return MDKVideoQueueWrapperSequenceTLSDepth;
}

static uint64_t MDKPopVideoQueueWrapperSequence(void) {
    if (MDKVideoQueueWrapperSequenceTLSDepth == 0) {
        return 0;
    }

    const size_t currentDepth = MDKVideoQueueWrapperSequenceTLSDepth;
    const size_t index = std::min(currentDepth, MDKVideoQueueWrapperTLSStackCapacity) - 1;
    const uint64_t sequenceID = MDKVideoQueueWrapperSequenceTLSStack[index];
    MDKVideoQueueWrapperSequenceTLSStack[index] = 0;
    MDKVideoQueueWrapperSequenceTLSDepth = currentDepth - 1;
    return sequenceID;
}

static NSArray<NSDictionary<NSString *, id> *> *MDKCopyBacktraceFrames(NSUInteger maxFrames, NSUInteger skipFrames) {
    if (maxFrames == 0) {
        return @[];
    }

    constexpr int maxStoredFrames = 64;
    void *addresses[maxStoredFrames] = {};
    const int capturedFrameCount = backtrace(addresses, maxStoredFrames);
    if (capturedFrameCount <= 0) {
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *frames = [NSMutableArray array];
    for (int idx = static_cast<int>(skipFrames); idx < capturedFrameCount && frames.count < maxFrames; ++idx) {
        void *address = addresses[idx];
        Dl_info info = {};
        const BOOL hasInfo = dladdr(address, &info) != 0;
        NSString *symbolName = hasInfo && info.dli_sname != nullptr ? [NSString stringWithUTF8String:info.dli_sname] : nil;
        NSString *imagePath = hasInfo && info.dli_fname != nullptr ? [NSString stringWithUTF8String:info.dli_fname] : nil;
        uintptr_t imageBase = hasInfo ? reinterpret_cast<uintptr_t>(info.dli_fbase) : 0;
        uintptr_t symbolAddress = hasInfo ? reinterpret_cast<uintptr_t>(info.dli_saddr) : 0;
        uintptr_t rawAddress = reinterpret_cast<uintptr_t>(address);
        NSMutableDictionary<NSString *, id> *frame = [@{
            @"frameIndex": @(idx - static_cast<int>(skipFrames)),
            @"address": [NSString stringWithFormat:@"0x%llx", static_cast<unsigned long long>(rawAddress)],
        } mutableCopy];
        if (symbolName != nil) {
            frame[@"symbolName"] = symbolName;
        }
        if (imagePath != nil) {
            frame[@"imagePath"] = imagePath;
        }
        if (imageBase != 0 && rawAddress >= imageBase) {
            frame[@"imageBase"] = [NSString stringWithFormat:@"0x%llx", static_cast<unsigned long long>(imageBase)];
            frame[@"imageOffset"] = @(rawAddress - imageBase);
        }
        if (symbolAddress != 0 && rawAddress >= symbolAddress) {
            frame[@"symbolAddress"] = [NSString stringWithFormat:@"0x%llx", static_cast<unsigned long long>(symbolAddress)];
            frame[@"symbolOffset"] = @(rawAddress - symbolAddress);
        }
        [frames addObject:frame];
    }

    return frames;
}

static void *MDKParsePointerString(NSString *value) {
    if (value.length == 0) {
        return nullptr;
    }

    unsigned long long rawValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if (![scanner scanHexLongLong:&rawValue]) {
        return nullptr;
    }
    return reinterpret_cast<void *>(static_cast<uintptr_t>(rawValue));
}

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
using MDKFigScreenCaptureControllerLifecycleFn = void (*)(id, SEL);
using MDKManagerStartRemoteQueueFn = void (*)(id, SEL, id, id);
using MDKManagerUpdateClientOutputTypeFn = void (*)(id, SEL, id, NSUInteger);
using MDKManagerStreamUpdateWithFilterFn = void (*)(id, SEL, id, id);
using MDKManagerStreamOutputEffectDidStartFn = void (*)(id, SEL, BOOL, id);
using MDKRPIOSurfaceSetFn = void (*)(id, SEL, IOSurfaceRef);
using MDKRPIOSurfaceGetFn = IOSurfaceRef (*)(id, SEL);
using MDKCaptureHandlerWithSampleFn = void (*)(id, SEL, id, id);
using MDKFrameSenderSendSampleFn = void (*)(id, SEL, id);
using MDKFrameSenderNewSampleBufferFn = id (*)(id, SEL, id);
using MDKCAContentStreamProduceSurfaceFn = void (*)(id, SEL, unsigned int, const void *);
using MDKCAContentStreamReleaseSurfaceFn = BOOL (*)(id, SEL, IOSurfaceRef, NSError **);
using MDKCAContentStreamReleaseSurfaceWithIDFn = BOOL (*)(id, SEL, unsigned int, NSError **);
using MDKIOSurfaceRemoteAddSurfaceFn = void (*)(id, SEL, void *, void *, std::uint64_t, id);
using MDKIOSurfaceRemoteSetSurfaceStatesFn = void (*)(id, SEL, id);
using MDKIOSurfaceRemoteRemoveSurfaceFn = BOOL (*)(id, SEL, unsigned int);
using MDKIOSurfaceRemoteHandleMessageFn = void (*)(id, SEL, id);
using MDKFrameReceiverInitFn = id (*)(id, SEL, id, id);
using MDKBWRemoteQueueSinkInitFn = id (*)(id, SEL, id, id, id, id);
using MDKBWRenderSampleBufferFn = void (*)(id, SEL, CMSampleBufferRef, id);
using MDKBWHandleDroppedSampleFn = void (*)(id, SEL, id, id);
using MDKBWRegisterSurfacesFromSourcePoolFn = void (*)(id, SEL, id);
using MDKBWSetBoolFn = void (*)(id, SEL, BOOL);
using MDKBWSetIntegerFn = void (*)(id, SEL, NSInteger);
using MDKBWNodeConnectionConsumeMessageFn = void (*)(id, SEL, id, id);
using MDKBWNodeHandleMessageFn = void (*)(id, SEL, id, id);
using MDKFigSetSinkNodeFn = void (*)(id, SEL, id);
using MDKSCRemoteQueueSetRemoteQueueFn = void (*)(id, SEL, id);
using MDKSCRemoteQueueSetQueueTypeFn = void (*)(id, SEL, unsigned char);
using MDKVideoReceiveQueueCallbackBlock = void (^)(int, MDKFigRemoteQueueMessage *, void *);
using MDKVideoReceiveQueueBlockInvokeFn = void (*)(void *, int, MDKFigRemoteQueueMessage *, void *);
using MDKVideoQueueNestedBlockInvokeFn = void (*)(void *, int, void *, void *);

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
static MDKFigScreenCaptureControllerLifecycleFn MDKOriginalFigScreenCaptureControllerStartCapture = nullptr;
static MDKFigScreenCaptureControllerLifecycleFn MDKOriginalFigScreenCaptureControllerResumeCapture = nullptr;
static MDKFigScreenCaptureControllerLifecycleFn MDKOriginalFigScreenCaptureControllerSuspendCapture = nullptr;
static MDKFigScreenCaptureControllerLifecycleFn MDKOriginalFigScreenCaptureControllerStopCapture = nullptr;
static MDKManagerStartRemoteQueueFn MDKOriginalManagerStartRemoteQueue = nullptr;
static MDKManagerUpdateClientOutputTypeFn MDKOriginalManagerUpdateClientOutputType = nullptr;
static MDKManagerStreamUpdateWithFilterFn MDKOriginalManagerStreamUpdateWithFilter = nullptr;
static MDKManagerStreamUpdateWithFilterFn MDKOriginalManagerStreamDidRequestUpdateFilter = nullptr;
static MDKManagerStreamOutputEffectDidStartFn MDKOriginalManagerStreamOutputEffectDidStart = nullptr;
static MDKRPIOSurfaceSetFn MDKOriginalRPIOSurfaceSet = nullptr;
static MDKRPIOSurfaceGetFn MDKOriginalRPIOSurfaceGet = nullptr;
static MDKCaptureHandlerWithSampleFn MDKOriginalDaemonCaptureHandlerWithSample = nullptr;
static MDKCaptureHandlerWithSampleFn MDKOriginalScreenRecorderCaptureHandlerWithSample = nullptr;
static MDKFrameSenderSendSampleFn MDKOriginalFrameSenderClientSendXCPSampleBuffer = nullptr;
static MDKFrameSenderSendSampleFn MDKOriginalFrameSenderServiceSendFrame = nullptr;
static MDKFrameSenderNewSampleBufferFn MDKOriginalFrameSenderServiceNewSampleBuffer = nullptr;
static MDKCAContentStreamProduceSurfaceFn MDKOriginalCAContentStreamProduceSurface = nullptr;
static MDKCAContentStreamReleaseSurfaceFn MDKOriginalCAContentStreamReleaseSurface = nullptr;
static MDKCAContentStreamReleaseSurfaceWithIDFn MDKOriginalCAContentStreamReleaseSurfaceWithID = nullptr;
static MDKIOSurfaceRemoteAddSurfaceFn MDKOriginalIOSurfaceRemoteAddSurface = nullptr;
static MDKIOSurfaceRemoteSetSurfaceStatesFn MDKOriginalIOSurfaceRemoteSetSurfaceStates = nullptr;
static MDKIOSurfaceRemoteRemoveSurfaceFn MDKOriginalIOSurfaceRemoteRemoveSurface = nullptr;
static MDKIOSurfaceRemoteHandleMessageFn MDKOriginalIOSurfaceRemoteHandleMessage = nullptr;
static MDKFrameReceiverInitFn MDKOriginalFrameReceiverInit = nullptr;
static MDKBWRemoteQueueSinkInitFn MDKOriginalBWRemoteQueueSinkInit = nullptr;
static MDKBWRenderSampleBufferFn MDKOriginalBWRenderSampleBuffer = nullptr;
static MDKBWHandleDroppedSampleFn MDKOriginalBWHandleDroppedSample = nullptr;
static MDKBWRegisterSurfacesFromSourcePoolFn MDKOriginalBWRegisterSurfacesFromSourcePool = nullptr;
static MDKBWSetBoolFn MDKOriginalBWSetDiscardsLateSampleBuffers = nullptr;
static MDKBWSetBoolFn MDKOriginalBWSetFrameSenderSupportEnabled = nullptr;
static MDKBWSetBoolFn MDKOriginalBWSetVideoHDRImageStatisticsEnabled = nullptr;
static MDKBWSetIntegerFn MDKOriginalBWSetClientVideoRetainedBufferCount = nullptr;
static MDKBWRenderSampleBufferFn MDKOriginalBWImageQueueSinkRenderSampleBuffer = nullptr;
static MDKBWRegisterSurfacesFromSourcePoolFn MDKOriginalBWImageQueueSinkRegisterSurfacesFromSourcePool = nullptr;
static MDKBWNodeConnectionConsumeMessageFn MDKOriginalBWNodeConnectionConsumeMessage = nullptr;
static MDKBWNodeHandleMessageFn MDKOriginalBWNodeHandleMessage = nullptr;
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

static id MDKCopyTraceFriendlyKVCDescription(id object, NSString *key) {
    if (object == nil || key.length == 0) {
        return [NSNull null];
    }

    @try {
        id value = [object valueForKey:key];
        if (value == nil) {
            return [NSNull null];
        }
        if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
            return value;
        }
        NSString *description = [value description];
        return description ?: [NSNull null];
    } @catch (__unused NSException *exception) {
        return [NSNull null];
    }
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

static NSDictionary<NSString *, id> *MDKCopyCompactXPCSummary(xpc_object_t object) {
    NSDictionary<NSString *, id> *fullSummary = MDKSummarizeXPCObject(object);
    NSDictionary<NSString *, id> *summarySource = fullSummary != nil ? fullSummary : @{};
    NSMutableDictionary<NSString *, id> *summary = [summarySource mutableCopy];
    [summary removeObjectForKey:@"description"];
    return summary;
}

static BOOL MDKCompactXPCSummaryContainsInterestingQueueArtifacts(NSDictionary<NSString *, id> *summary) {
    if (![summary isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSArray<NSString *> *keys = [summary[@"xpcKeys"] isKindOfClass:[NSArray class]] ? summary[@"xpcKeys"] : nil;
    NSSet<NSString *> *interestingKeys = [NSSet setWithArray:@[
        @"QueueData",
        @"SharedRegion",
        @"QueueOffset",
        @"RecvFd",
        @"SendFd",
        @"IOSurfaceReceiver",
    ]];
    for (NSString *key in keys) {
        if ([interestingKeys containsObject:key]) {
            return YES;
        }
    }

    NSDictionary<NSString *, id> *selectedValues =
        [summary[@"xpcSelectedValues"] isKindOfClass:[NSDictionary class]] ? summary[@"xpcSelectedValues"] : nil;
    return selectedValues.count > 0;
}

static std::uint64_t MDKFNV1a64(const std::uint8_t *bytes, size_t length) {
    if (bytes == nullptr || length == 0) {
        return 0;
    }

    std::uint64_t hash = 1469598103934665603ULL;
    for (size_t index = 0; index < length; ++index) {
        hash ^= static_cast<std::uint64_t>(bytes[index]);
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSDictionary<NSString *, id> * _Nullable MDKCopyVideoRemoteQueueSharedRegionSnapshot(void) {
    NSDictionary<NSString *, id> *videoQueueEntry = MDKCopySCKRemoteQueueEntryForType(1);
    id remoteQueue = videoQueueEntry[@"remoteQueue"];
    if (remoteQueue == nil || ![NSStringFromClass([remoteQueue class]) hasPrefix:@"OS_xpc_"]) {
        return nil;
    }

    xpc_object_t remoteQueueObject = (xpc_object_t) remoteQueue;
    xpc_object_t sharedRegion = xpc_dictionary_get_value(remoteQueueObject, "SharedRegion");
    if (sharedRegion == nullptr || xpc_get_type(sharedRegion) != XPC_TYPE_SHMEM) {
        return nil;
    }

    std::uint64_t queueOffset = 0;
    xpc_object_t queueOffsetValue = xpc_dictionary_get_value(remoteQueueObject, "QueueOffset");
    if (queueOffsetValue != nullptr && xpc_get_type(queueOffsetValue) == XPC_TYPE_UINT64) {
        queueOffset = xpc_uint64_get_value(queueOffsetValue);
    }

    void *mappedRegion = nullptr;
    const size_t mappedSize = xpc_shmem_map(sharedRegion, &mappedRegion);
    if (mappedRegion == nullptr || mappedSize <= queueOffset) {
        return nil;
    }

    const size_t inspectionSize = std::min<size_t>(4096, mappedSize - static_cast<size_t>(queueOffset));
    if (inspectionSize == 0) {
        return nil;
    }

    const std::uint8_t *bytes =
        reinterpret_cast<const std::uint8_t *>(mappedRegion) + static_cast<size_t>(queueOffset);
    NSData *snapshotData = [NSData dataWithBytes:bytes length:inspectionSize];
    const std::uint64_t fingerprint = MDKFNV1a64(bytes, inspectionSize);

    return @{
        @"remoteQueuePointer": [NSString stringWithFormat:@"%p", (__bridge const void *) remoteQueue],
        @"mappedSize": @(mappedSize),
        @"queueOffset": @(queueOffset),
        @"inspectionSize": @(inspectionSize),
        @"fingerprint": @(fingerprint),
        @"snapshotData": snapshotData,
    };
}

static int MDKDuplicateVideoRemoteQueueFD(const char *name) {
    if (name == nullptr) {
        return -1;
    }

    NSDictionary<NSString *, id> *videoQueueEntry = MDKCopySCKRemoteQueueEntryForType(1);
    id remoteQueue = videoQueueEntry[@"remoteQueue"];
    if (remoteQueue == nil || ![NSStringFromClass([remoteQueue class]) hasPrefix:@"OS_xpc_"]) {
        return -1;
    }

    xpc_object_t remoteQueueObject = (xpc_object_t) remoteQueue;
    xpc_object_t fdValue = xpc_dictionary_get_value(remoteQueueObject, name);
    if (fdValue == nullptr || xpc_get_type(fdValue) != XPC_TYPE_FD) {
        return -1;
    }

    return xpc_fd_dup(fdValue);
}

static NSArray<NSNumber *> *MDKCopyChangedWordOffsets(NSData *previousData, NSData *currentData) {
    if (previousData == nil || currentData == nil || previousData.length == 0 || currentData.length == 0) {
        return @[];
    }

    const size_t comparableLength = std::min(previousData.length, currentData.length);
    const std::uint8_t *previousBytes = reinterpret_cast<const std::uint8_t *>(previousData.bytes);
    const std::uint8_t *currentBytes = reinterpret_cast<const std::uint8_t *>(currentData.bytes);
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    for (size_t offset = 0; offset < comparableLength; offset += sizeof(std::uint64_t)) {
        const size_t remaining = comparableLength - offset;
        const size_t chunkLength = std::min(remaining, sizeof(std::uint64_t));
        if (memcmp(previousBytes + offset, currentBytes + offset, chunkLength) != 0) {
            [offsets addObject:@(offset)];
            if (offsets.count >= 12) {
                break;
            }
        }
    }
    return offsets;
}

static void MDKObserveVideoRemoteQueueSharedRegion(void) {
    NSDictionary<NSString *, id> *snapshot = MDKCopyVideoRemoteQueueSharedRegionSnapshot();
    if (snapshot == nil) {
        return;
    }

    NSData *snapshotData = snapshot[@"snapshotData"];
    NSNumber *fingerprint = snapshot[@"fingerprint"];
    NSArray<NSNumber *> *changedWordOffsets = @[];
    NSNumber *lastChangeTimestamp = nil;
    NSNumber *changeTimestamp = nil;
    BOOL shouldRecord = NO;

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return;
        }

        MDKActiveSCKTraceState[@"videoSharedRegionPollCount"] =
            @([MDKActiveSCKTraceState[@"videoSharedRegionPollCount"] unsignedIntegerValue] + 1);
        MDKActiveSCKTraceState[@"videoSharedRegionMappedSize"] = snapshot[@"mappedSize"];
        MDKActiveSCKTraceState[@"videoSharedRegionQueueOffset"] = snapshot[@"queueOffset"];
        MDKActiveSCKTraceState[@"videoSharedRegionInspectionSize"] = snapshot[@"inspectionSize"];
        MDKActiveSCKTraceState[@"videoSharedRegionLastRemoteQueuePointer"] = snapshot[@"remoteQueuePointer"];

        NSData *previousData = MDKActiveSCKTraceState[@"videoSharedRegionPreviousSnapshotData"];
        NSNumber *previousFingerprint = MDKActiveSCKTraceState[@"videoSharedRegionLastFingerprint"];
        if (previousData == nil || previousFingerprint == nil) {
            MDKActiveSCKTraceState[@"videoSharedRegionPreviousSnapshotData"] = snapshotData;
            MDKActiveSCKTraceState[@"videoSharedRegionLastFingerprint"] = fingerprint;
            return;
        }

        if ([previousFingerprint isEqualToNumber:fingerprint]) {
            return;
        }

        changedWordOffsets = MDKCopyChangedWordOffsets(previousData, snapshotData);
        MDKActiveSCKTraceState[@"videoSharedRegionChangeEventCount"] =
            @([MDKActiveSCKTraceState[@"videoSharedRegionChangeEventCount"] unsignedIntegerValue] + 1);
        shouldRecord = [MDKActiveSCKTraceState[@"videoSharedRegionChangeEventCount"] unsignedIntegerValue] <= 512;

        const std::uint64_t timestampNanos = MDKCurrentTraceTimestampNanos();
        changeTimestamp = @(timestampNanos);
        lastChangeTimestamp = MDKActiveSCKTraceState[@"videoSharedRegionLastChangeTimestampNanos"];
        if (lastChangeTimestamp != nil) {
            const double deltaMs =
                (static_cast<long double>(timestampNanos) - static_cast<long double>(lastChangeTimestamp.unsignedLongLongValue)) / 1.0e6L;
            MDKIncrementMutableHistogram(
                MDKActiveSCKTraceState[@"videoSharedRegionDeltaHistogram"],
                MDKBucketMilliseconds(deltaMs)
            );
            MDKActiveSCKTraceState[@"videoSharedRegionDeltaCount"] =
                @([MDKActiveSCKTraceState[@"videoSharedRegionDeltaCount"] unsignedIntegerValue] + 1);
        }
        MDKActiveSCKTraceState[@"videoSharedRegionLastChangeTimestampNanos"] = changeTimestamp;
        MDKActiveSCKTraceState[@"videoSharedRegionPreviousSnapshotData"] = snapshotData;
        MDKActiveSCKTraceState[@"videoSharedRegionLastFingerprint"] = fingerprint;

        NSMutableDictionary<NSString *, NSNumber *> *changedOffsetHistogram = MDKActiveSCKTraceState[@"videoSharedRegionChangedOffsetHistogram"];
        for (NSNumber *offset in changedWordOffsets) {
            NSString *key = offset.stringValue;
            changedOffsetHistogram[key] = @([changedOffsetHistogram[key] unsignedIntegerValue] + 1);
        }
    }

    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(
        @"video-shared-region-change",
        @{
            @"remoteQueuePointer": snapshot[@"remoteQueuePointer"],
            @"mappedSize": snapshot[@"mappedSize"],
            @"queueOffset": snapshot[@"queueOffset"],
            @"inspectionSize": snapshot[@"inspectionSize"],
            @"fingerprint": fingerprint,
            @"changedWordOffsets": changedWordOffsets,
            @"previousChangeTimestampNanos": lastChangeTimestamp ?: [NSNull null],
            @"changeTimestampNanos": changeTimestamp ?: [NSNull null],
        }
    );
}

static void MDKObserveVideoRemoteQueueReceiveFD(int receiveFD) {
    if (receiveFD < 0) {
        return;
    }

    struct pollfd descriptor = {};
    descriptor.fd = receiveFD;
    descriptor.events = POLLIN | POLLPRI | POLLHUP;
    const int pollStatus = poll(&descriptor, 1, 0);

    int availableBytes = 0;
    if (ioctl(receiveFD, FIONREAD, &availableBytes) != 0) {
        availableBytes = -1;
    }

    const BOOL readable =
        pollStatus > 0 &&
        (descriptor.revents & (POLLIN | POLLPRI | POLLHUP)) != 0;
    NSNumber *previousSignalTimestamp = nil;
    NSNumber *signalTimestamp = nil;
    BOOL shouldRecord = NO;

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return;
        }

        MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDPollCount"] =
            @([MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDPollCount"] unsignedIntegerValue] + 1);
        MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDLastRevents"] = @(descriptor.revents);

        if (availableBytes >= 0) {
            MDKIncrementMutableHistogram(
                MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDAvailableBytesHistogram"],
                [NSString stringWithFormat:@"%d", availableBytes]
            );
            if (availableBytes > [MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDAvailableBytesMax"] intValue]) {
                MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDAvailableBytesMax"] = @(availableBytes);
            }
        }

        const BOOL previousReadable = [MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDLastReadable"] boolValue];
        NSNumber *previousAvailableBytes = MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDLastAvailableBytes"];
        const BOOL availabilityChanged =
            previousAvailableBytes == nil || previousAvailableBytes.intValue != availableBytes;
        if (readable && (!previousReadable || availabilityChanged)) {
            MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDSignalEventCount"] =
                @([MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDSignalEventCount"] unsignedIntegerValue] + 1);
            shouldRecord = [MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDSignalEventCount"] unsignedIntegerValue] <= 512;

            const std::uint64_t timestampNanos = MDKCurrentTraceTimestampNanos();
            signalTimestamp = @(timestampNanos);
            previousSignalTimestamp = MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDLastSignalTimestampNanos"];
            if (previousSignalTimestamp != nil) {
                const double deltaMs =
                    (static_cast<long double>(timestampNanos) - static_cast<long double>(previousSignalTimestamp.unsignedLongLongValue)) / 1.0e6L;
                MDKIncrementMutableHistogram(
                    MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDDeltaHistogram"],
                    MDKBucketMilliseconds(deltaMs)
                );
                MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDDeltaCount"] =
                    @([MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDDeltaCount"] unsignedIntegerValue] + 1);
            }
            MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDLastSignalTimestampNanos"] = signalTimestamp;
        }

        MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDLastReadable"] = @(readable);
        MDKActiveSCKTraceState[@"videoRemoteQueueRecvFDLastAvailableBytes"] = @(availableBytes);
    }

    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(
        @"video-recv-fd-signal",
        @{
            @"revents": @(descriptor.revents),
            @"availableBytes": @(availableBytes),
            @"previousSignalTimestampNanos": previousSignalTimestamp ?: [NSNull null],
            @"signalTimestampNanos": signalTimestamp ?: [NSNull null],
        }
    );
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
        NSArray<NSDictionary<NSString *, id> *> *pointeeWords =
            MDKDescribePointerWords(slotValue, allocationSize, 8);
        if (pointeeWords.count > 0) {
            summary[@"pointeeWords"] = pointeeWords;
            NSDictionary<NSString *, id> *word0 =
                [pointeeWords[0] isKindOfClass:[NSDictionary class]] ? pointeeWords[0] : nil;
            NSDictionary<NSString *, id> *word0CodePointer =
                [word0[@"codePointer"] isKindOfClass:[NSDictionary class]] ? word0[@"codePointer"] : nil;
            NSString *word0Symbol =
                [word0CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? word0CodePointer[@"symbolName"] : nil;
            if (word0Symbol != nil &&
                ([word0Symbol hasPrefix:@"OBJC_CLASS_$"] || [word0Symbol hasPrefix:@"OBJC_METACLASS_$"])) {
                @try {
                    summary[@"pointeeObject"] = MDKSummarizeObject((__bridge id) slotValue);
                } @catch (__unused NSException *exception) {
                }
            }
        }
    }

    if (inspectForBlockSignature && allocationSize > 0) {
        NSString *signature = MDKCopyBlockSignatureString((__bridge id) slotValue);
        if (signature != nil) {
            summary[@"blockSignature"] = signature;
            summary[@"block"] = MDKDescribeBlockLiteralObject((__bridge id) slotValue);
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
    NSMutableArray<NSNumber *> *candidateBlockOffsets = [NSMutableArray array];
    const uint8_t *base = reinterpret_cast<const uint8_t *>(wrapperPointer);
    size_t wrapperAllocationSize = malloc_size(const_cast<void *>(wrapperPointer));
    if (wrapperAllocationSize == 0) {
        wrapperAllocationSize = 0x80;
    }
    const size_t maxInspectableBytes = std::min<size_t>(wrapperAllocationSize, 0x80);
    const size_t lastOffset = maxInspectableBytes >= sizeof(void *) ? maxInspectableBytes - sizeof(void *) : 0;
    for (size_t offset = 0; offset <= lastOffset; offset += sizeof(void *)) {
        void *slotValue = nullptr;
        memcpy(&slotValue, base + offset, sizeof(slotValue));
        NSDictionary<NSString *, id> *slotSummary = MDKDescribeRemoteQueueWrapperSlot(slotValue, offset, YES);
        if (slotSummary[@"blockSignature"] != nil) {
            [candidateBlockOffsets addObject:@(offset)];
        }
        [slots addObject:slotSummary];
    }

    return @{
        @"present": @YES,
        @"pointer": [NSString stringWithFormat:@"%p", wrapperPointer],
        @"mallocSize": @(wrapperAllocationSize),
        @"candidateBlockOffsets": candidateBlockOffsets,
        @"slots": slots,
    };
}

static NSDictionary<NSString *, id> *MDKCopyVideoReceiveQueueWrapperState(id object) {
    if (object == nil) {
        return @{
            @"present": @NO,
        };
    }

    NSValue *wrapperValue = MDKCopyRawPointerIvar(object, "_videoReceiveQueue");
    if (wrapperValue == nil || wrapperValue.pointerValue == nullptr) {
        return @{
            @"present": @NO,
        };
    }

    return MDKDescribeRemoteQueueWrapper(wrapperValue.pointerValue);
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

static BOOL MDKIsVideoQueueWrapperBlockSignature(NSString *signature) {
    return signature != nil && [signature containsString:@"FigRemoteQueueMessage"];
}

static BOOL MDKIsVideoQueueNestedBlockSignature(NSString *signature) {
    if (signature == nil) {
        return NO;
    }

    return [signature containsString:@"FigRemoteOperation"] ||
        [signature containsString:@"FigRemoteQueueMessage"];
}

static BOOL MDKIsDispatchSourceHandlerBlockSignature(NSString *signature) {
    return signature != nil && [signature hasPrefix:@"v8@?0"];
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
            @"frameSenderEventCount": @0,
            @"contentStreamEventCount": @0,
            @"surfaceTransportEventCount": @0,
            @"frameReceiverEventCount": @0,
            @"remoteQueueSinkEventCount": @0,
            @"remoteQueueObjectEventCount": @0,
            @"videoSharedRegionPollCount": @0,
            @"videoSharedRegionChangeEventCount": @0,
            @"videoSharedRegionDeltaCount": @0,
            @"videoSharedRegionDeltaHistogram": [NSMutableDictionary dictionary],
            @"videoSharedRegionChangedOffsetHistogram": [NSMutableDictionary dictionary],
            @"videoRemoteQueueRecvFDPollCount": @0,
            @"videoRemoteQueueRecvFDSignalEventCount": @0,
            @"videoRemoteQueueRecvFDDeltaCount": @0,
            @"videoRemoteQueueRecvFDDeltaHistogram": [NSMutableDictionary dictionary],
            @"videoRemoteQueueRecvFDAvailableBytesHistogram": [NSMutableDictionary dictionary],
            @"videoRemoteQueueRecvFDAvailableBytesMax": @0,
            @"fifoReadEventCount": @0,
            @"fifoReadNoCancelEventCount": @0,
            @"fifoReadInterposeEventCount": @0,
            @"fifoWriteEventCount": @0,
            @"fifoWriteNoCancelEventCount": @0,
            @"fifoWriteInterposeEventCount": @0,
            @"pipeCreateEventCount": @0,
            @"pipeInterposeEventCount": @0,
            @"ioSurfaceMachLookupEventCount": @0,
            @"ioSurfaceMachCreateEventCount": @0,
            @"ioSurfaceMachInterposeEventCount": @0,
            @"xpcPipeCreateEventCount": @0,
            @"xpcPipeSimpleRoutineEventCount": @0,
            @"xpcPipeInterposeEventCount": @0,
            @"xpcFDDupEventCount": @0,
            @"xpcDictionaryDupFDEventCount": @0,
            @"xpcFDInterposeEventCount": @0,
            @"dispatchSourceHandlerCallbackEventCount": @0,
            @"dispatchSourceHandlerBlocks": [NSMutableDictionary dictionary],
            @"dispatchSourceHandlerInvokes": [NSMutableDictionary dictionary],
            @"videoQueueWrapperCallbackEventCount": @0,
            @"videoQueueWrapperInvokeEntryEventCount": @0,
            @"videoQueueWrapperInvokeExitEventCount": @0,
            @"rqReceiverSetSourceInvokeEntryEventCount": @0,
            @"rqReceiverSetSourceInvokeExitEventCount": @0,
            @"dispatchSourceInvokeEntryEventCount": @0,
            @"dispatchSourceInvokeExitEventCount": @0,
            @"dispatchSourceLatchAndCallEntryEventCount": @0,
            @"dispatchSourceLatchAndCallExitEventCount": @0,
            @"dispatchClientCalloutRQReceiverEntryEventCount": @0,
            @"dispatchClientCalloutRQReceiverExitEventCount": @0,
            @"videoQueueWrapperBlocks": [NSMutableDictionary dictionary],
            @"videoQueueWrapperInvokes": [NSMutableDictionary dictionary],
            @"videoQueueNestedBlockCallbackEventCount": @0,
            @"videoQueueNestedBlockBlocks": [NSMutableDictionary dictionary],
            @"videoQueueNestedBlockInvokes": [NSMutableDictionary dictionary],
            @"figRemoteQueueReceiverWrappedHandlers": [NSMutableDictionary dictionary],
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
        MDKActiveSCKAllowVideoQueueWrapperProbe = NO;
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

static void MDKSetSCKTraceStateValue(NSString *key, id value) {
    if (key.length == 0 || value == nil) {
        return;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return;
        }

        MDKActiveSCKTraceState[key] = value;
    }
}

static dispatch_queue_t MDKNormalizeTraceQueue(dispatch_queue_t queue, NSString *fallbackLabel) {
    if (queue != nil) {
        return queue;
    }

    const char *label = fallbackLabel.UTF8String ?: "com.skyline23.MacDisplayKit.fig-remote-queue-handler";
    return dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
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

static id MDKDeepFreezeSCKTraceValue(id value) {
    if (value == nil) {
        return nil;
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary<id, id> *frozen = [NSMutableDictionary dictionary];
        for (id key in (NSDictionary *) value) {
            id frozenKey = MDKDeepFreezeSCKTraceValue(key);
            id frozenValue = MDKDeepFreezeSCKTraceValue(((NSDictionary *) value)[key]);
            if (frozenKey != nil && frozenValue != nil) {
                frozen[frozenKey] = frozenValue;
            }
        }
        return [frozen copy];
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *frozen = [NSMutableArray arrayWithCapacity:[(NSArray *) value count]];
        for (id element in (NSArray *) value) {
            id frozenElement = MDKDeepFreezeSCKTraceValue(element);
            [frozen addObject:frozenElement ?: [NSNull null]];
        }
        return [frozen copy];
    }

    if ([value isKindOfClass:[NSSet class]]) {
        NSMutableArray *frozen = [NSMutableArray arrayWithCapacity:[(NSSet *) value count]];
        for (id element in (NSSet *) value) {
            id frozenElement = MDKDeepFreezeSCKTraceValue(element);
            [frozen addObject:frozenElement ?: [NSNull null]];
        }
        return [frozen copy];
    }

    if ([value conformsToProtocol:@protocol(NSCopying)]) {
        return [(id<NSCopying>) value copyWithZone:nil];
    }

    return value;
}

static NSDictionary<NSString *, id> * _Nullable MDKCopySCKTraceStateSnapshot(void) {
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return nil;
        }

        return MDKDeepFreezeSCKTraceValue(MDKActiveSCKTraceState);
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

static void __attribute__((unused)) MDKPrimeFigRemoteQueueReceiverIfPossible(id remoteQueue) {
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

static NSDictionary<NSString *, NSNumber *> *MDKCopyTraceEventKindHistogram(
    NSArray<NSDictionary<NSString *, id> *> *events,
    NSSet<NSString *> *eventKinds
) {
    NSMutableDictionary<NSString *, NSNumber *> *histogram = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *event in events) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
        if (kind == nil || ![eventKinds containsObject:kind]) {
            continue;
        }
        histogram[kind] = @([histogram[kind] unsignedIntegerValue] + 1);
    }
    return [histogram copy];
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

    BOOL shouldWrapVideoQueueCallback = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        shouldWrapVideoQueueCallback = MDKActiveSCKAllowVideoQueueWrapperProbe;
    }
    id stream = nil;
    NSNumber *queueType = nil;
    if (shouldWrapVideoQueueCallback) {
        queueType = MDKPerformUnsignedCharGetter(queue, sel_registerName("queueType"));
        if (queueType != nil && queueType.unsignedCharValue == 1) {
            stream = ((id (*)(id, SEL, id)) objc_msgSend)(self, sel_registerName("getStreamForID:"), streamID);
            if (stream != nil) {
                MDKWrapVideoReceiveQueueCallbackIfPossible(stream);
            }
        }
    }

    MDKOriginalManagerStartRemoteQueue(self, _cmd, queue, streamID);
    if (shouldWrapVideoQueueCallback && queueType != nil && queueType.unsignedCharValue == 1 && stream != nil) {
        MDKRescanNestedVideoQueueBlockIfPossible(stream, @"post-manager-start-video");
    }
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

static void MDKRecordIOSurfaceMachPortEvent(NSString *kind, mach_port_t port, IOSurfaceRef surface) {
    BOOL shouldRecord = NO;
    NSUInteger overallEventCount = 0;
    NSString *counterKey = [kind isEqualToString:@"iosurface-create-mach-port"] ?
        @"ioSurfaceMachCreateEventCount" :
        @"ioSurfaceMachLookupEventCount";
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[counterKey] =
                @([MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1);
            overallEventCount = [MDKActiveSCKTraceState[@"ioSurfaceMachInterposeEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"ioSurfaceMachInterposeEventCount"] = @(overallEventCount);
            shouldRecord = overallEventCount <= 128;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"port": @(port),
        @"surface": MDKSummarizeIOSurface(surface),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    if (overallEventCount <= 8) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(10, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
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

static void MDKRecordFrameSenderEvent(NSString *kind, id sample) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"frameSenderEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"frameSenderEventCount"] = @(eventCount);
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

extern "C" void MDKInterposedRQReceiverSetSourceBlockInvoke(void *blockLiteral);
extern "C" void MDKInterposedDispatchSourceInvokeInternal(dispatch_source_t source, void *invokeContext, uint32_t flags);
extern "C" void MDKInterposedDispatchSourceLatchAndCallInternal(dispatch_source_t source, dispatch_queue_t queue, uint32_t flags);
extern "C" void MDKInterposedDispatchClientCallout(void *context, dispatch_function_t function);

static void MDKInstallRQReceiverSetSourceBlockInterposeIfPossible(
    NSDictionary<NSString *, id> *interestingFrame
) {
    NSString *symbolName = [interestingFrame[@"symbolName"] isKindOfClass:[NSString class]] ? interestingFrame[@"symbolName"] : nil;
    NSString *imagePath = [interestingFrame[@"imagePath"] isKindOfClass:[NSString class]] ? interestingFrame[@"imagePath"] : nil;
    NSString *symbolAddress = [interestingFrame[@"symbolAddress"] isKindOfClass:[NSString class]] ? interestingFrame[@"symbolAddress"] : nil;
    if (symbolName == nil || imagePath == nil || symbolAddress == nil) {
        return;
    }
    if (![symbolName isEqualToString:@"__rqReceiverSetSource_block_invoke"] ||
        ![imagePath containsString:@"/CMCapture.framework/"]) {
        return;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if ([MDKActiveSCKTraceState[@"rqReceiverSetSourceInterposeInstalled"] boolValue]) {
            return;
        }
        MDKActiveSCKTraceState[@"rqReceiverSetSourceInterposeAttempted"] = @YES;
    }

    using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);
    auto dynamicInterpose =
        reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
    if (dynamicInterpose == nullptr) {
        dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
    }
    if (dynamicInterpose == nullptr) {
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveSCKTraceState[@"rqReceiverSetSourceInterposeInstalled"] = @NO;
        }
        return;
    }

    MDKEnsureCaptureImageLoaded("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture");
    const mach_header *cmCaptureHeader =
        MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
    void *replacee = MDKParsePointerString(symbolAddress);
    if (cmCaptureHeader == nullptr || replacee == nullptr) {
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveSCKTraceState[@"rqReceiverSetSourceInterposeInstalled"] = @NO;
        }
        return;
    }

    MDKOriginalRQReceiverSetSourceBlockInvoke =
        reinterpret_cast<MDKRQReceiverSetSourceBlockInvokeFn>(replacee);
    MDKResolvedRQReceiverSetSourceBlockInvokeAddress = replacee;
    MDKResolvedRQReceiverSetSourceBlockInvokeImageHeader = const_cast<mach_header *>(cmCaptureHeader);
    const MDKDyldInterposeTuple interposes[] = {
        { reinterpret_cast<const void *>(&MDKInterposedRQReceiverSetSourceBlockInvoke), replacee },
    };
    dynamicInterpose(cmCaptureHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"rqReceiverSetSourceInterposeInstalled"] = @YES;
            MDKActiveSCKTraceState[@"rqReceiverSetSourceInterposeSymbolAddress"] = symbolAddress;
        }
    }
}

static void MDKInstallDispatchSourceInternalInterposeIfPossible(
    NSDictionary<NSString *, id> *interestingFrame
) {
    NSString *symbolName = [interestingFrame[@"symbolName"] isKindOfClass:[NSString class]] ? interestingFrame[@"symbolName"] : nil;
    NSString *imagePath = [interestingFrame[@"imagePath"] isKindOfClass:[NSString class]] ? interestingFrame[@"imagePath"] : nil;
    NSString *symbolAddress = [interestingFrame[@"symbolAddress"] isKindOfClass:[NSString class]] ? interestingFrame[@"symbolAddress"] : nil;
    if (symbolName == nil || imagePath == nil || symbolAddress == nil) {
        return;
    }

    const BOOL isDispatchSourceInvoke = [symbolName isEqualToString:@"_dispatch_source_invoke"];
    const BOOL isDispatchSourceLatchAndCall = [symbolName isEqualToString:@"_dispatch_source_latch_and_call"];
    if ((!isDispatchSourceInvoke && !isDispatchSourceLatchAndCall) ||
        ![imagePath containsString:@"/libdispatch.dylib"]) {
        return;
    }

    NSString *attemptedKey = isDispatchSourceInvoke ?
        @"dispatchSourceInvokeInterposeAttempted" :
        @"dispatchSourceLatchAndCallInterposeAttempted";
    NSString *installedKey = isDispatchSourceInvoke ?
        @"dispatchSourceInvokeInterposeInstalled" :
        @"dispatchSourceLatchAndCallInterposeInstalled";
    NSString *addressKey = isDispatchSourceInvoke ?
        @"dispatchSourceInvokeInterposeSymbolAddress" :
        @"dispatchSourceLatchAndCallInterposeSymbolAddress";

    @synchronized(MDKActiveSCKTraceLock) {
        if ([MDKActiveSCKTraceState[installedKey] boolValue]) {
            return;
        }
        MDKActiveSCKTraceState[attemptedKey] = @YES;
    }

    using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);
    auto dynamicInterpose =
        reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
    if (dynamicInterpose == nullptr) {
        dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
    }
    if (dynamicInterpose == nullptr) {
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveSCKTraceState[installedKey] = @NO;
        }
        return;
    }

    const mach_header *libdispatchHeader = MDKFindLoadedImageHeader("/usr/lib/system/libdispatch.dylib");
    void *replacee = MDKParsePointerString(symbolAddress);
    if (libdispatchHeader == nullptr || replacee == nullptr) {
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveSCKTraceState[installedKey] = @NO;
        }
        return;
    }

    if (isDispatchSourceInvoke) {
        MDKOriginalDispatchSourceInvokeInternal =
            reinterpret_cast<MDKDispatchSourceInvokeInternalFn>(replacee);
        MDKResolvedDispatchSourceInvokeAddress = replacee;
        MDKResolvedDispatchSourceInvokeImageHeader = const_cast<mach_header *>(libdispatchHeader);
        const MDKDyldInterposeTuple interposes[] = {
            { reinterpret_cast<const void *>(&MDKInterposedDispatchSourceInvokeInternal), replacee },
        };
        dynamicInterpose(libdispatchHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
    } else {
        MDKOriginalDispatchSourceLatchAndCallInternal =
            reinterpret_cast<MDKDispatchSourceLatchAndCallInternalFn>(replacee);
        MDKResolvedDispatchSourceLatchAndCallAddress = replacee;
        MDKResolvedDispatchSourceLatchAndCallImageHeader = const_cast<mach_header *>(libdispatchHeader);
        const MDKDyldInterposeTuple interposes[] = {
            { reinterpret_cast<const void *>(&MDKInterposedDispatchSourceLatchAndCallInternal), replacee },
        };
        dynamicInterpose(libdispatchHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[installedKey] = @YES;
            MDKActiveSCKTraceState[addressKey] = symbolAddress;
        }
    }
}

static void MDKInstallDispatchClientCalloutInterposeIfPossible(
    NSDictionary<NSString *, id> *interestingFrame
) {
    NSString *symbolName = [interestingFrame[@"symbolName"] isKindOfClass:[NSString class]] ? interestingFrame[@"symbolName"] : nil;
    NSString *imagePath = [interestingFrame[@"imagePath"] isKindOfClass:[NSString class]] ? interestingFrame[@"imagePath"] : nil;
    NSString *symbolAddress = [interestingFrame[@"symbolAddress"] isKindOfClass:[NSString class]] ? interestingFrame[@"symbolAddress"] : nil;
    if (symbolName == nil || imagePath == nil || symbolAddress == nil) {
        return;
    }
    if (![symbolName isEqualToString:@"_dispatch_client_callout"] ||
        ![imagePath containsString:@"/libdispatch.dylib"]) {
        return;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if ([MDKActiveSCKTraceState[@"dispatchClientCalloutInterposeInstalled"] boolValue]) {
            return;
        }
        MDKActiveSCKTraceState[@"dispatchClientCalloutInterposeAttempted"] = @YES;
    }

    using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);
    auto dynamicInterpose =
        reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
    if (dynamicInterpose == nullptr) {
        dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
    }
    if (dynamicInterpose == nullptr) {
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveSCKTraceState[@"dispatchClientCalloutInterposeInstalled"] = @NO;
        }
        return;
    }

    const mach_header *libdispatchHeader = MDKFindLoadedImageHeader("/usr/lib/system/libdispatch.dylib");
    void *replacee = MDKParsePointerString(symbolAddress);
    if (libdispatchHeader == nullptr || replacee == nullptr) {
        @synchronized(MDKActiveSCKTraceLock) {
            MDKActiveSCKTraceState[@"dispatchClientCalloutInterposeInstalled"] = @NO;
        }
        return;
    }

    MDKOriginalDispatchClientCallout =
        reinterpret_cast<MDKDispatchClientCalloutFn>(replacee);
    MDKResolvedDispatchClientCalloutAddress = replacee;
    MDKResolvedDispatchClientCalloutImageHeader = const_cast<mach_header *>(libdispatchHeader);
    const MDKDyldInterposeTuple interposes[] = {
        { reinterpret_cast<const void *>(&MDKInterposedDispatchClientCallout), replacee },
    };
    dynamicInterpose(libdispatchHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"dispatchClientCalloutInterposeInstalled"] = @YES;
            MDKActiveSCKTraceState[@"dispatchClientCalloutInterposeSymbolAddress"] = symbolAddress;
        }
    }
}

static void MDKRecordRQReceiverSetSourceInvokeBoundaryEvent(
    NSString *kind,
    void *blockLiteral
) {
    BOOL shouldRecord = NO;
    NSUInteger eventCount = 0;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSString *counterKey =
                [kind isEqualToString:@"rq-receiver-set-source-invoke-exit"] ?
                    @"rqReceiverSetSourceInvokeExitEventCount" :
                    @"rqReceiverSetSourceInvokeEntryEventCount";
            eventCount = [MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[counterKey] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"blockLiteral": MDKSummarizePointerValue(blockLiteral),
    } mutableCopy];
    if (eventCount <= 4) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(8, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordDispatchSourceInternalBoundaryEvent(
    NSString *kind,
    dispatch_source_t source,
    const void *secondaryPointer,
    uint32_t flags
) {
    BOOL shouldRecord = NO;
    NSUInteger eventCount = 0;
    NSString *counterKey = nil;
    if ([kind isEqualToString:@"dispatch-source-invoke-entry"]) {
        counterKey = @"dispatchSourceInvokeEntryEventCount";
    } else if ([kind isEqualToString:@"dispatch-source-invoke-exit"]) {
        counterKey = @"dispatchSourceInvokeExitEventCount";
    } else if ([kind isEqualToString:@"dispatch-source-latch-and-call-entry"]) {
        counterKey = @"dispatchSourceLatchAndCallEntryEventCount";
    } else {
        counterKey = @"dispatchSourceLatchAndCallExitEventCount";
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            eventCount = [MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[counterKey] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"source": MDKSummarizePointerValue((__bridge const void *) source),
        @"sourceMetadata": MDKCopyDispatchReadSourceMetadata(source) ?: [NSNull null],
        @"secondaryPointer": MDKSummarizePointerValue(secondaryPointer),
        @"flags": @(flags),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    if (eventCount <= 4) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(8, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordDispatchClientCalloutBoundaryEvent(
    NSString *kind,
    void *context,
    dispatch_function_t function
) {
    BOOL shouldRecord = NO;
    NSUInteger eventCount = 0;
    NSString *counterKey = [kind isEqualToString:@"dispatch-client-callout-rq-receiver-exit"] ?
        @"dispatchClientCalloutRQReceiverExitEventCount" :
        @"dispatchClientCalloutRQReceiverEntryEventCount";
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            eventCount = [MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[counterKey] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"context": MDKSummarizePointerValue(context),
        @"function": MDKDescribeCodePointer(reinterpret_cast<const void *>(function)),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    if (eventCount <= 4) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(8, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static NSDictionary<NSString *, id> * _Nullable MDKCopyDispatchReadSourceMetadata(dispatch_source_t source) {
    if (source == nil) {
        return nil;
    }

    NSDictionary<NSString *, id> *sourceSummary = MDKDescribeShallowPointerPointee((__bridge const void *) source);
    NSDictionary<NSString *, id> *objectSummary =
        [sourceSummary[@"object"] isKindOfClass:[NSDictionary class]] ? sourceSummary[@"object"] : nil;
    if (objectSummary == nil) {
        return nil;
    }

    NSString *fileType =
        [objectSummary[@"dispatchSourceHandleFileType"] isKindOfClass:[NSString class]] ? objectSummary[@"dispatchSourceHandleFileType"] : nil;
    NSArray<NSDictionary<NSString *, id> *> *dispatchSourceWords =
        [objectSummary[@"dispatchSourceWords"] isKindOfClass:[NSArray class]] ? objectSummary[@"dispatchSourceWords"] : nil;
    NSDictionary<NSString *, id> *typeWord = dispatchSourceWords.count > 11 ? dispatchSourceWords[11] : nil;
    NSDictionary<NSString *, id> *typeWordPointee =
        [typeWord[@"pointee"] isKindOfClass:[NSDictionary class]] ? typeWord[@"pointee"] : nil;
    NSDictionary<NSString *, id> *typeWord0CodePointer =
        [typeWordPointee[@"word0CodePointer"] isKindOfClass:[NSDictionary class]] ? typeWordPointee[@"word0CodePointer"] : nil;
    NSString *typeSymbol =
        [typeWord0CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? typeWord0CodePointer[@"symbolName"] : nil;
    if ((fileType == nil || ![fileType isEqualToString:@"fifo"]) &&
        (typeSymbol == nil || ![typeSymbol isEqualToString:@"_dispatch_source_type_read"])) {
        return nil;
    }

    NSDictionary<NSString *, id> *queueWord = dispatchSourceWords.count > 3 ? dispatchSourceWords[3] : nil;
    NSDictionary<NSString *, id> *queueWordPointee =
        [queueWord[@"pointee"] isKindOfClass:[NSDictionary class]] ? queueWord[@"pointee"] : nil;
    NSDictionary<NSString *, id> *queueWordObject =
        [queueWordPointee[@"object"] isKindOfClass:[NSDictionary class]] ? queueWordPointee[@"object"] : nil;
    NSString *targetQueueDescription =
        [queueWordObject[@"description"] isKindOfClass:[NSString class]] ? queueWordObject[@"description"] : nil;
    NSString *targetQueueClassName =
        [queueWordObject[@"className"] isKindOfClass:[NSString class]] ? queueWordObject[@"className"] : nil;

    return @{
        @"source": MDKSummarizePointerValue((__bridge const void *) source),
        @"handle": objectSummary[@"dispatchSourceHandle"] ?: [NSNull null],
        @"fileType": fileType ?: [NSNull null],
        @"typeSymbol": typeSymbol ?: [NSNull null],
        @"targetQueueClassName": targetQueueClassName ?: [NSNull null],
        @"targetQueueDescription": targetQueueDescription ?: [NSNull null],
    };
}

static BOOL MDKShouldTraceFIFOReadFD(int fd) {
    if (fd < 0) {
        return NO;
    }

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState == nil) {
            return NO;
        }
    }

    struct stat fdStat = {};
    if (fstat(fd, &fdStat) != 0) {
        return NO;
    }

    return S_ISFIFO(fdStat.st_mode);
}

static void MDKRecordFIFOReadInterposeEvent(
    NSString *kind,
    int fd,
    size_t requestedByteCount,
    ssize_t result,
    int savedErrno
) {
    BOOL shouldRecord = NO;
    NSUInteger overallEventCount = 0;
    NSString *counterKey = [kind isEqualToString:@"fifo-read-nocancel"] ?
        @"fifoReadNoCancelEventCount" :
        @"fifoReadEventCount";
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[counterKey] =
                @([MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1);
            overallEventCount = [MDKActiveSCKTraceState[@"fifoReadInterposeEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"fifoReadInterposeEventCount"] = @(overallEventCount);
            shouldRecord = overallEventCount <= 128;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"fd": @(fd),
        @"requestedByteCount": @(requestedByteCount),
        @"result": @(result),
        @"errno": @(savedErrno),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    if (overallEventCount <= 8) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(10, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordFIFOWriteInterposeEvent(
    NSString *kind,
    int fd,
    size_t requestedByteCount,
    ssize_t result,
    int savedErrno
) {
    BOOL shouldRecord = NO;
    NSUInteger overallEventCount = 0;
    NSString *counterKey = [kind isEqualToString:@"fifo-write-nocancel"] ?
        @"fifoWriteNoCancelEventCount" :
        @"fifoWriteEventCount";
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[counterKey] =
                @([MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1);
            overallEventCount = [MDKActiveSCKTraceState[@"fifoWriteInterposeEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"fifoWriteInterposeEventCount"] = @(overallEventCount);
            shouldRecord = overallEventCount <= 128;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"fd": @(fd),
        @"requestedByteCount": @(requestedByteCount),
        @"result": @(result),
        @"errno": @(savedErrno),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    if (overallEventCount <= 8) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(10, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static BOOL MDKShouldTraceXPCFDDupKey(const char *key) {
    if (key == nullptr) {
        return NO;
    }

    return strcmp(key, "RecvFd") == 0 || strcmp(key, "SendFd") == 0;
}

static void MDKRecordXPCFDInterposeEvent(
    NSString *kind,
    xpc_object_t object,
    const char *key,
    int resultFD,
    int savedErrno
) {
    BOOL shouldRecord = NO;
    NSUInteger overallEventCount = 0;
    NSString *counterKey = [kind isEqualToString:@"xpc-dictionary-dup-fd"] ?
        @"xpcDictionaryDupFDEventCount" :
        @"xpcFDDupEventCount";
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[counterKey] =
                @([MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1);
            overallEventCount = [MDKActiveSCKTraceState[@"xpcFDInterposeEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"xpcFDInterposeEventCount"] = @(overallEventCount);
            shouldRecord = overallEventCount <= 128;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"key": key != nullptr ? [NSString stringWithUTF8String:key] : [NSNull null],
        @"resultFD": @(resultFD),
        @"errno": @(savedErrno),
        @"resultIsFIFO": @(MDKShouldTraceFIFOReadFD(resultFD)),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    NSDictionary<NSString *, id> *xpcSummary = MDKSummarizeXPCObject(object);
    if (xpcSummary != nil) {
        payload[@"xpcObject"] = xpcSummary;
    }
    if (overallEventCount <= 8) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(10, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordXPCPipeInterposeEvent(
    NSString *kind,
    const char *name,
    std::uint64_t flags,
    xpc_object_t pipeObject,
    xpc_object_t message,
    xpc_object_t reply,
    int status
) {
    NSDictionary<NSString *, id> *pipeSummary = MDKCopyCompactXPCSummary(pipeObject);
    NSDictionary<NSString *, id> *messageSummary = MDKCopyCompactXPCSummary(message);
    NSDictionary<NSString *, id> *replySummary = MDKCopyCompactXPCSummary(reply);
    const BOOL interestingMessage = MDKCompactXPCSummaryContainsInterestingQueueArtifacts(messageSummary);
    const BOOL interestingReply = MDKCompactXPCSummaryContainsInterestingQueueArtifacts(replySummary);

    BOOL shouldRecord = NO;
    NSUInteger overallEventCount = 0;
    NSString *counterKey = [kind isEqualToString:@"xpc-pipe-create"] ?
        @"xpcPipeCreateEventCount" :
        @"xpcPipeSimpleRoutineEventCount";
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[counterKey] =
                @([MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1);
            overallEventCount = [MDKActiveSCKTraceState[@"xpcPipeInterposeEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"xpcPipeInterposeEventCount"] = @(overallEventCount);
            shouldRecord = interestingMessage || interestingReply || overallEventCount <= 24;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"name": name != nullptr ? [NSString stringWithUTF8String:name] : [NSNull null],
        @"flags": @(flags),
        @"status": @(status),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
        @"interestingMessage": @(interestingMessage),
        @"interestingReply": @(interestingReply),
        @"pipe": pipeSummary ?: @{},
        @"message": messageSummary ?: @{},
        @"reply": replySummary ?: @{},
    } mutableCopy];
    if (overallEventCount <= 8) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(10, 3);
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordPipeInterposeEvent(int result, const int fds[2], int savedErrno) {
    BOOL shouldRecord = NO;
    NSUInteger overallEventCount = 0;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            MDKActiveSCKTraceState[@"pipeCreateEventCount"] =
                @([MDKActiveSCKTraceState[@"pipeCreateEventCount"] unsignedIntegerValue] + (result == 0 ? 1 : 0));
            overallEventCount = [MDKActiveSCKTraceState[@"pipeInterposeEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"pipeInterposeEventCount"] = @(overallEventCount);
            shouldRecord = overallEventCount <= 32;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"result": @(result),
        @"errno": @(savedErrno),
        @"readFD": @(fds[0]),
        @"writeFD": @(fds[1]),
        @"readIsFIFO": @(MDKShouldTraceFIFOReadFD(fds[0])),
        @"writeIsFIFO": @(MDKShouldTraceFIFOReadFD(fds[1])),
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    if (overallEventCount <= 8) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(10, 3);
    }
    MDKRecordSCKTraceEvent(@"pipe-create", payload);
}

static void MDKRecordDispatchSourceHandlerCallbackEvent(void) {
    BOOL shouldRecord = NO;
    NSUInteger eventCount = 0;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            eventCount = [MDKActiveSCKTraceState[@"dispatchSourceHandlerCallbackEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"dispatchSourceHandlerCallbackEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"wrapperSequenceID": MDKCurrentVideoQueueWrapperSequence() > 0 ? @(MDKCurrentVideoQueueWrapperSequence()) : [NSNull null],
        @"wrapperDepth": @(MDKCurrentVideoQueueWrapperSequenceDepth()),
    } mutableCopy];
    if (eventCount <= 4) {
        payload[@"backtrace"] = MDKCopyBacktraceFrames(8, 3);
    }
    MDKRecordSCKTraceEvent(@"dispatch-source-handler-callback", payload);
}

static void MDKRecordDispatchReadSourceInterposeEvent(NSString *kind, NSDictionary<NSString *, id> *payload) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"dispatchReadSourceInterposeEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"dispatchReadSourceInterposeEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 64;
        }
    }
    if (!shouldRecord) {
        return;
    }

    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordVideoQueueWrapperCallbackEvent(
    uint64_t sequenceID,
    NSUInteger wrapperDepth,
    int status,
    const MDKFigRemoteQueueMessage *message,
    void *context
) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"videoQueueWrapperCallbackEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"videoQueueWrapperCallbackEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSDictionary<NSString *, id> *surfaceSummary = message != nullptr ? MDKSummarizeIOSurface(message->surface) : @{ @"present": @NO };
    id messageType = message != nullptr ? static_cast<id>(@(message->messageType)) : [NSNull null];
    NSDictionary<NSString *, id> *payload = @{
        @"wrapperSequenceID": sequenceID > 0 ? @(sequenceID) : [NSNull null],
        @"wrapperDepth": @(wrapperDepth),
        @"status": @(status),
        @"messageType": messageType,
        @"surface": surfaceSummary,
        @"context": MDKSummarizePointerValue(context),
    };
    MDKRecordSCKTraceEvent(@"video-queue-wrapper-callback", payload);
}

static void MDKRecordVideoQueueWrapperInvokeBoundaryEvent(
    NSString *kind,
    uint64_t sequenceID,
    NSUInteger wrapperDepth,
    int status,
    const MDKFigRemoteQueueMessage *message,
    void *context
) {
    BOOL shouldRecord = NO;
    NSUInteger eventCount = 0;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSString *counterKey =
                [kind isEqualToString:@"video-queue-wrapper-invoke-exit"] ?
                    @"videoQueueWrapperInvokeExitEventCount" :
                    @"videoQueueWrapperInvokeEntryEventCount";
            eventCount = [MDKActiveSCKTraceState[counterKey] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[counterKey] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSDictionary<NSString *, id> *surfaceSummary = message != nullptr ? MDKSummarizeIOSurface(message->surface) : @{ @"present": @NO };
    id messageType = message != nullptr ? static_cast<id>(@(message->messageType)) : [NSNull null];
    NSMutableDictionary<NSString *, id> *payload = [@{
        @"wrapperSequenceID": sequenceID > 0 ? @(sequenceID) : [NSNull null],
        @"wrapperDepth": @(wrapperDepth),
        @"status": @(status),
        @"messageType": messageType,
        @"surface": surfaceSummary,
        @"context": MDKSummarizePointerValue(context),
    } mutableCopy];
    if (eventCount <= 4) {
        NSArray<NSDictionary<NSString *, id> *> *backtrace = MDKCopyBacktraceFrames(8, 3);
        payload[@"backtrace"] = backtrace;
        for (NSDictionary<NSString *, id> *frame in backtrace) {
            NSString *frameSymbolName = [frame[@"symbolName"] isKindOfClass:[NSString class]] ? frame[@"symbolName"] : nil;
            if ([frameSymbolName isEqualToString:@"_dispatch_client_callout"]) {
                MDKInstallDispatchClientCalloutInterposeIfPossible(frame);
                continue;
            }
            if ([frameSymbolName isEqualToString:@"_dispatch_source_invoke"] ||
                [frameSymbolName isEqualToString:@"_dispatch_source_latch_and_call"]) {
                MDKInstallDispatchSourceInternalInterposeIfPossible(frame);
                continue;
            }
            if ([frameSymbolName isEqualToString:@"__rqReceiverSetSource_block_invoke"]) {
                MDKInstallRQReceiverSetSourceBlockInterposeIfPossible(frame);
            }
        }
    }
    MDKRecordSCKTraceEvent(kind, payload);
}

static void MDKRecordVideoQueueNestedBlockCallbackEvent(
    uint64_t wrapperSequenceID,
    NSUInteger wrapperDepth,
    int status,
    const void *operation,
    void *context
) {
    BOOL shouldRecord = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSUInteger eventCount = [MDKActiveSCKTraceState[@"videoQueueNestedBlockCallbackEventCount"] unsignedIntegerValue] + 1;
            MDKActiveSCKTraceState[@"videoQueueNestedBlockCallbackEventCount"] = @(eventCount);
            shouldRecord = eventCount <= 512;
        }
    }
    if (!shouldRecord) {
        return;
    }

    NSDictionary<NSString *, id> *payload = @{
        @"wrapperSequenceID": wrapperSequenceID > 0 ? @(wrapperSequenceID) : [NSNull null],
        @"wrapperDepth": @(wrapperDepth),
        @"status": @(status),
        @"operation": MDKSummarizePointerValue(operation),
        @"context": MDKSummarizePointerValue(context),
    };
    MDKRecordSCKTraceEvent(@"video-queue-nested-block-callback", payload);
}

static NSString * _Nullable MDKCopyVideoQueueBlockDescriptorKey(const MDKBlockLiteral *literal) {
    if (literal == nullptr || literal->descriptor == nullptr) {
        return nil;
    }

    return [NSString stringWithFormat:@"%p", literal->descriptor];
}

static void MDKInterposedVideoQueueBlockInvoke(
    void *blockLiteral,
    int status,
    MDKFigRemoteQueueMessage *message,
    void *context
) {
    const uint64_t sequenceID = MDKPushVideoQueueWrapperSequence();
    const NSUInteger wrapperDepth = MDKCurrentVideoQueueWrapperSequenceDepth();
    MDKRecordVideoQueueWrapperCallbackEvent(sequenceID, wrapperDepth, status, message, context);
    MDKRecordVideoQueueWrapperInvokeBoundaryEvent(
        @"video-queue-wrapper-invoke-entry",
        sequenceID,
        wrapperDepth,
        status,
        message,
        context
    );

    MDKVideoReceiveQueueBlockInvokeFn originalInvoke = nullptr;
    @synchronized(MDKActiveSCKTraceLock) {
        NSDictionary<NSString *, id> *wrappedInvokes = MDKActiveSCKTraceState[@"videoQueueWrapperInvokes"];
        NSString *blockKey = [NSString stringWithFormat:@"%p", blockLiteral];
        NSValue *invokeValue = [wrappedInvokes[blockKey] isKindOfClass:[NSValue class]] ? wrappedInvokes[blockKey] : nil;
        if (invokeValue == nil) {
            NSString *descriptorKey = MDKCopyVideoQueueBlockDescriptorKey(reinterpret_cast<const MDKBlockLiteral *>(blockLiteral));
            invokeValue = [wrappedInvokes[descriptorKey] isKindOfClass:[NSValue class]] ? wrappedInvokes[descriptorKey] : nil;
        }
        if (invokeValue != nil) {
            originalInvoke = reinterpret_cast<MDKVideoReceiveQueueBlockInvokeFn>(invokeValue.pointerValue);
        }
    }

    if (originalInvoke != nullptr) {
        originalInvoke(blockLiteral, status, message, context);
    }

    MDKRecordVideoQueueWrapperInvokeBoundaryEvent(
        @"video-queue-wrapper-invoke-exit",
        sequenceID,
        wrapperDepth,
        status,
        message,
        context
    );
    MDKPopVideoQueueWrapperSequence();
}

extern "C" void MDKInterposedRQReceiverSetSourceBlockInvoke(void *blockLiteral) {
    MDKRecordRQReceiverSetSourceInvokeBoundaryEvent(@"rq-receiver-set-source-invoke-entry", blockLiteral);
    if (MDKOriginalRQReceiverSetSourceBlockInvoke != nullptr) {
        MDKOriginalRQReceiverSetSourceBlockInvoke(blockLiteral);
    }
    MDKRecordRQReceiverSetSourceInvokeBoundaryEvent(@"rq-receiver-set-source-invoke-exit", blockLiteral);
}

extern "C" void MDKInterposedDispatchClientCallout(
    void *context,
    dispatch_function_t function
) {
    const void *functionPointer = reinterpret_cast<const void *>(function);
    const BOOL isRQReceiverSetSourceCallout =
        functionPointer != nullptr &&
        (functionPointer == MDKResolvedRQReceiverSetSourceBlockInvokeAddress ||
         functionPointer == reinterpret_cast<const void *>(MDKOriginalRQReceiverSetSourceBlockInvoke));
    if (isRQReceiverSetSourceCallout) {
        MDKRecordDispatchClientCalloutBoundaryEvent(
            @"dispatch-client-callout-rq-receiver-entry",
            context,
            function
        );
    }
    if (MDKOriginalDispatchClientCallout != nullptr) {
        MDKOriginalDispatchClientCallout(context, function);
    }
    if (isRQReceiverSetSourceCallout) {
        MDKRecordDispatchClientCalloutBoundaryEvent(
            @"dispatch-client-callout-rq-receiver-exit",
            context,
            function
        );
    }
}

extern "C" void MDKInterposedDispatchSourceInvokeInternal(
    dispatch_source_t source,
    void *invokeContext,
    uint32_t flags
) {
    MDKRecordDispatchSourceInternalBoundaryEvent(
        @"dispatch-source-invoke-entry",
        source,
        invokeContext,
        flags
    );
    if (MDKOriginalDispatchSourceInvokeInternal != nullptr) {
        MDKOriginalDispatchSourceInvokeInternal(source, invokeContext, flags);
    }
    MDKRecordDispatchSourceInternalBoundaryEvent(
        @"dispatch-source-invoke-exit",
        source,
        invokeContext,
        flags
    );
}

extern "C" void MDKInterposedDispatchSourceLatchAndCallInternal(
    dispatch_source_t source,
    dispatch_queue_t queue,
    uint32_t flags
) {
    MDKRecordDispatchSourceInternalBoundaryEvent(
        @"dispatch-source-latch-and-call-entry",
        source,
        (__bridge const void *) queue,
        flags
    );
    if (MDKOriginalDispatchSourceLatchAndCallInternal != nullptr) {
        MDKOriginalDispatchSourceLatchAndCallInternal(source, queue, flags);
    }
    MDKRecordDispatchSourceInternalBoundaryEvent(
        @"dispatch-source-latch-and-call-exit",
        source,
        (__bridge const void *) queue,
        flags
    );
}

static void MDKInterposedVideoQueueNestedBlockInvoke(
    void *blockLiteral,
    int status,
    void *operation,
    void *context
) {
    MDKRecordVideoQueueNestedBlockCallbackEvent(
        MDKCurrentVideoQueueWrapperSequence(),
        MDKCurrentVideoQueueWrapperSequenceDepth(),
        status,
        operation,
        context
    );

    MDKVideoQueueNestedBlockInvokeFn originalInvoke = nullptr;
    @synchronized(MDKActiveSCKTraceLock) {
        NSDictionary<NSString *, id> *wrappedInvokes = MDKActiveSCKTraceState[@"videoQueueNestedBlockInvokes"];
        NSString *blockKey = [NSString stringWithFormat:@"%p", blockLiteral];
        NSValue *invokeValue = [wrappedInvokes[blockKey] isKindOfClass:[NSValue class]] ? wrappedInvokes[blockKey] : nil;
        if (invokeValue == nil) {
            NSString *descriptorKey = MDKCopyVideoQueueBlockDescriptorKey(reinterpret_cast<const MDKBlockLiteral *>(blockLiteral));
            invokeValue = [wrappedInvokes[descriptorKey] isKindOfClass:[NSValue class]] ? wrappedInvokes[descriptorKey] : nil;
        }
        if (invokeValue != nil) {
            originalInvoke = reinterpret_cast<MDKVideoQueueNestedBlockInvokeFn>(invokeValue.pointerValue);
        }
    }

    if (originalInvoke != nullptr) {
        originalInvoke(blockLiteral, status, operation, context);
    }
}

static const void *MDKFindVideoQueueCallbackBlockPointerInWrapper(
    const void *wrapperPointer,
    size_t *callbackOffsetOut,
    NSString **blockSignatureOut
) {
    if (callbackOffsetOut != nullptr) {
        *callbackOffsetOut = SIZE_MAX;
    }
    if (blockSignatureOut != nullptr) {
        *blockSignatureOut = nil;
    }
    if (wrapperPointer == nullptr) {
        return nullptr;
    }

    uint8_t *wrapperBase = reinterpret_cast<uint8_t *>(const_cast<void *>(wrapperPointer));
    size_t wrapperAllocationSize = malloc_size(const_cast<void *>(wrapperPointer));
    if (wrapperAllocationSize == 0) {
        wrapperAllocationSize = 0x80;
    }
    const size_t maxInspectableBytes = std::min<size_t>(wrapperAllocationSize, 0x80);
    const size_t lastOffset = maxInspectableBytes >= sizeof(void *) ? maxInspectableBytes - sizeof(void *) : 0;
    for (size_t offset = 0; offset <= lastOffset; offset += sizeof(void *)) {
        void *candidatePointer = nullptr;
        memcpy(&candidatePointer, wrapperBase + offset, sizeof(candidatePointer));
        if (candidatePointer == nullptr) {
            continue;
        }
        NSString *candidateSignature = MDKCopyBlockSignatureString((__bridge id) candidatePointer);
        if (MDKIsVideoQueueWrapperBlockSignature(candidateSignature)) {
            if (callbackOffsetOut != nullptr) {
                *callbackOffsetOut = offset;
            }
            if (blockSignatureOut != nullptr) {
                *blockSignatureOut = candidateSignature;
            }
            return candidatePointer;
        }
    }

    return nullptr;
}

static BOOL MDKInstallNestedVideoQueueBlockAtPointer(const void *blockPointer) {
    if (blockPointer == nullptr) {
        return NO;
    }

    id callbackObject = (__bridge id) blockPointer;
    NSString *signature = MDKCopyBlockSignatureString(callbackObject);
    if (!MDKIsVideoQueueNestedBlockSignature(signature)) {
        return NO;
    }

    NSString *blockKey = [NSString stringWithFormat:@"%p", blockPointer];
    auto *callbackLiteral = reinterpret_cast<MDKBlockLiteral *>(const_cast<void *>(blockPointer));
    if (callbackLiteral == nullptr || callbackLiteral->invoke == nullptr) {
        return NO;
    }

    NSString *descriptorKey = MDKCopyVideoQueueBlockDescriptorKey(callbackLiteral);
    MDKVideoQueueNestedBlockInvokeFn originalInvoke =
        reinterpret_cast<MDKVideoQueueNestedBlockInvokeFn>(callbackLiteral->invoke);
    @synchronized(MDKActiveSCKTraceLock) {
        NSMutableDictionary<NSString *, id> *wrappedBlocks = MDKActiveSCKTraceState[@"videoQueueNestedBlockBlocks"];
        NSMutableDictionary<NSString *, id> *wrappedInvokes = MDKActiveSCKTraceState[@"videoQueueNestedBlockInvokes"];
        if (wrappedInvokes[blockKey] != nil) {
            return YES;
        }

        wrappedBlocks[blockKey] = callbackObject;
        wrappedInvokes[blockKey] = [NSValue valueWithPointer:reinterpret_cast<void *>(originalInvoke)];
        if (descriptorKey != nil) {
            wrappedInvokes[descriptorKey] = [NSValue valueWithPointer:reinterpret_cast<void *>(originalInvoke)];
        }
        callbackLiteral->invoke = reinterpret_cast<void (*)(void *, ...)>(MDKInterposedVideoQueueNestedBlockInvoke);
    }

    MDKRecordSCKTraceEvent(
        @"video-queue-nested-block-installed",
        @{
            @"callbackPointer": [NSString stringWithFormat:@"%p", blockPointer],
            @"blockSignature": signature,
            @"originalInvoke": MDKDescribeCodePointer(reinterpret_cast<void *>(originalInvoke)),
        }
    );
    return YES;
}

static const void *MDKFindDispatchSourcePointerInWrapper(const void *wrapperPointer) {
    if (wrapperPointer == nullptr) {
        return nullptr;
    }

    uint8_t *wrapperBase = reinterpret_cast<uint8_t *>(const_cast<void *>(wrapperPointer));
    size_t wrapperAllocationSize = malloc_size(const_cast<void *>(wrapperPointer));
    if (wrapperAllocationSize == 0) {
        wrapperAllocationSize = 0x80;
    }
    const size_t maxInspectableBytes = std::min<size_t>(wrapperAllocationSize, 0x80);
    const size_t lastOffset = maxInspectableBytes >= sizeof(void *) ? maxInspectableBytes - sizeof(void *) : 0;
    for (size_t offset = 0; offset <= lastOffset; offset += sizeof(void *)) {
        void *candidatePointer = nullptr;
        memcpy(&candidatePointer, wrapperBase + offset, sizeof(candidatePointer));
        if (candidatePointer == nullptr) {
            continue;
        }
        NSDictionary<NSString *, id> *pointee = MDKDescribeShallowPointerPointee(candidatePointer);
        NSDictionary<NSString *, id> *object = [pointee[@"object"] isKindOfClass:[NSDictionary class]] ? pointee[@"object"] : nil;
        NSString *className = [object[@"className"] isKindOfClass:[NSString class]] ? object[@"className"] : nil;
        NSString *fileType =
            [object[@"dispatchSourceHandleFileType"] isKindOfClass:[NSString class]] ? object[@"dispatchSourceHandleFileType"] : nil;
        if ([className isEqualToString:@"OS_dispatch_source"] &&
            (fileType == nil || [fileType isEqualToString:@"fifo"])) {
            return candidatePointer;
        }
    }

    return nullptr;
}

static const void *MDKFindDispatchSourceHandlerBlockPointer(
    const void *dispatchSourcePointer,
    size_t *blockOffsetOut,
    NSString **blockSignatureOut
) {
    if (blockOffsetOut != nullptr) {
        *blockOffsetOut = SIZE_MAX;
    }
    if (blockSignatureOut != nullptr) {
        *blockSignatureOut = nil;
    }
    if (dispatchSourcePointer == nullptr) {
        return nullptr;
    }

    uint8_t *sourceBase = reinterpret_cast<uint8_t *>(const_cast<void *>(dispatchSourcePointer));
    size_t allocationSize = malloc_size(const_cast<void *>(dispatchSourcePointer));
    if (allocationSize == 0) {
        return nullptr;
    }

    const size_t lastOffset = allocationSize >= sizeof(void *) ? allocationSize - sizeof(void *) : 0;
    for (size_t offset = 0; offset <= lastOffset; offset += sizeof(void *)) {
        void *candidatePointer = nullptr;
        memcpy(&candidatePointer, sourceBase + offset, sizeof(candidatePointer));
        if (candidatePointer == nullptr) {
            continue;
        }

        NSString *candidateSignature = MDKCopyBlockSignatureString((__bridge id) candidatePointer);
        if (!MDKIsDispatchSourceHandlerBlockSignature(candidateSignature)) {
            continue;
        }

        NSDictionary<NSString *, id> *blockSummary = MDKDescribeBlockLiteralObject((__bridge id) candidatePointer);
        NSDictionary<NSString *, id> *invokeSummary =
            [blockSummary[@"invoke"] isKindOfClass:[NSDictionary class]] ? blockSummary[@"invoke"] : nil;
        NSString *imagePath =
            [invokeSummary[@"imagePath"] isKindOfClass:[NSString class]] ? invokeSummary[@"imagePath"] : nil;
        if (imagePath != nil &&
            ![imagePath containsString:@"libdispatch"] &&
            ![imagePath containsString:@"CMCapture"] &&
            ![imagePath containsString:@"ScreenCaptureKit"]) {
            continue;
        }

        if (blockOffsetOut != nullptr) {
            *blockOffsetOut = offset;
        }
        if (blockSignatureOut != nullptr) {
            *blockSignatureOut = candidateSignature;
        }
        return candidatePointer;
    }

    return nullptr;
}

static void MDKInterposedDispatchSourceHandlerBlockInvoke(void *blockLiteral) {
    MDKRecordDispatchSourceHandlerCallbackEvent();

    MDKDispatchSourceHandlerBlockInvokeFn originalInvoke = nullptr;
    @synchronized(MDKActiveSCKTraceLock) {
        NSDictionary<NSString *, id> *wrappedInvokes = MDKActiveSCKTraceState[@"dispatchSourceHandlerInvokes"];
        NSString *blockKey = [NSString stringWithFormat:@"%p", blockLiteral];
        NSValue *invokeValue = [wrappedInvokes[blockKey] isKindOfClass:[NSValue class]] ? wrappedInvokes[blockKey] : nil;
        if (invokeValue == nil) {
            NSString *descriptorKey = MDKCopyVideoQueueBlockDescriptorKey(reinterpret_cast<const MDKBlockLiteral *>(blockLiteral));
            invokeValue = [wrappedInvokes[descriptorKey] isKindOfClass:[NSValue class]] ? wrappedInvokes[descriptorKey] : nil;
        }
        if (invokeValue != nil) {
            originalInvoke = reinterpret_cast<MDKDispatchSourceHandlerBlockInvokeFn>(invokeValue.pointerValue);
        }
    }

    if (originalInvoke != nullptr) {
        originalInvoke(blockLiteral);
    }
}

static BOOL MDKInstallDispatchSourceHandlerBlockAtPointer(const void *dispatchSourcePointer) {
    if (dispatchSourcePointer == nullptr) {
        return NO;
    }

    size_t blockOffset = SIZE_MAX;
    NSString *signature = nil;
    const void *blockPointer = MDKFindDispatchSourceHandlerBlockPointer(dispatchSourcePointer, &blockOffset, &signature);
    if (blockPointer == nullptr) {
        return NO;
    }

    NSString *blockKey = [NSString stringWithFormat:@"%p", blockPointer];
    auto *blockLiteral = reinterpret_cast<MDKBlockLiteral *>(const_cast<void *>(blockPointer));
    if (blockLiteral == nullptr || blockLiteral->invoke == nullptr) {
        return NO;
    }

    NSString *descriptorKey = MDKCopyVideoQueueBlockDescriptorKey(blockLiteral);
    MDKDispatchSourceHandlerBlockInvokeFn originalInvoke =
        reinterpret_cast<MDKDispatchSourceHandlerBlockInvokeFn>(blockLiteral->invoke);
    @synchronized(MDKActiveSCKTraceLock) {
        NSMutableDictionary<NSString *, id> *wrappedBlocks = MDKActiveSCKTraceState[@"dispatchSourceHandlerBlocks"];
        NSMutableDictionary<NSString *, id> *wrappedInvokes = MDKActiveSCKTraceState[@"dispatchSourceHandlerInvokes"];
        if (wrappedInvokes[blockKey] != nil) {
            return YES;
        }

        wrappedBlocks[blockKey] = (__bridge id) blockPointer;
        wrappedInvokes[blockKey] = [NSValue valueWithPointer:reinterpret_cast<void *>(originalInvoke)];
        if (descriptorKey != nil) {
            wrappedInvokes[descriptorKey] = [NSValue valueWithPointer:reinterpret_cast<void *>(originalInvoke)];
        }
        blockLiteral->invoke = reinterpret_cast<void (*)(void *, ...)>(MDKInterposedDispatchSourceHandlerBlockInvoke);
    }

    MDKRecordSCKTraceEvent(
        @"dispatch-source-handler-installed",
        @{
            @"dispatchSourcePointer": [NSString stringWithFormat:@"%p", dispatchSourcePointer],
            @"blockPointer": [NSString stringWithFormat:@"%p", blockPointer],
            @"blockOffset": blockOffset == SIZE_MAX ? [NSNull null] : @(blockOffset),
            @"blockSignature": signature ?: @"",
            @"originalInvoke": MDKDescribeCodePointer(reinterpret_cast<void *>(originalInvoke)),
        }
    );
    return YES;
}

static BOOL MDKMaybeInstallNestedVideoQueueBlockFromWrapperPointer(const void *wrapperPointer, NSString *reason) {
    size_t callbackOffset = SIZE_MAX;
    NSString *callbackSignature = nil;
    const void *callbackPointer = MDKFindVideoQueueCallbackBlockPointerInWrapper(
        wrapperPointer,
        &callbackOffset,
        &callbackSignature
    );

    const auto *callbackLiteral =
        reinterpret_cast<const MDKBlockLiteral *>(const_cast<void *>(callbackPointer));
    uintptr_t nestedBlockRawValue = 0;
    if (callbackLiteral != nullptr && callbackLiteral->descriptor != nullptr && callbackLiteral->descriptor->size >= 40) {
        memcpy(&nestedBlockRawValue, reinterpret_cast<const uint8_t *>(callbackLiteral) + 32, sizeof(nestedBlockRawValue));
    }

    NSString *nestedBlockSignature = nil;
    if (nestedBlockRawValue != 0) {
        nestedBlockSignature = MDKCopyBlockSignatureString((__bridge id) reinterpret_cast<const void *>(nestedBlockRawValue));
    }

    const BOOL installed = nestedBlockRawValue != 0 &&
        MDKInstallNestedVideoQueueBlockAtPointer(reinterpret_cast<const void *>(nestedBlockRawValue));

    MDKRecordSCKTraceEvent(
        @"video-queue-nested-block-rescan",
        @{
            @"reason": reason ?: @"",
            @"wrapperPointer": wrapperPointer != nullptr ? [NSString stringWithFormat:@"%p", wrapperPointer] : @"",
            @"callbackPointer": callbackPointer != nullptr ? [NSString stringWithFormat:@"%p", callbackPointer] : @"",
            @"callbackOffset": callbackOffset == SIZE_MAX ? [NSNull null] : @(callbackOffset),
            @"callbackSignature": callbackSignature ?: @"",
            @"nestedBlockPointer": nestedBlockRawValue != 0 ? [NSString stringWithFormat:@"%p", reinterpret_cast<const void *>(nestedBlockRawValue)] : @"",
            @"nestedBlockSignature": nestedBlockSignature ?: @"",
            @"installed": @(installed),
        }
    );

    return installed;
}

static BOOL MDKInstallVideoQueueWrapperCallbackAtPointer(const void *wrapperPointer) {
    if (wrapperPointer == nullptr) {
        return NO;
    }

    size_t callbackOffset = SIZE_MAX;
    NSString *signature = nil;
    const void *callbackPointer = MDKFindVideoQueueCallbackBlockPointerInWrapper(
        wrapperPointer,
        &callbackOffset,
        &signature
    );
    if (callbackPointer == nullptr) {
        return NO;
    }

    id callbackObject = (__bridge id) callbackPointer;
    if (!MDKIsVideoQueueWrapperBlockSignature(signature)) {
        return NO;
    }

    NSString *wrapperKey = [NSString stringWithFormat:@"%p", wrapperPointer];
    NSString *blockKey = [NSString stringWithFormat:@"%p", callbackPointer];
    auto *callbackLiteral = reinterpret_cast<MDKBlockLiteral *>(const_cast<void *>(callbackPointer));
    if (callbackLiteral == nullptr || callbackLiteral->invoke == nullptr) {
        return NO;
    }
    const void *dispatchSourcePointer = MDKFindDispatchSourcePointerInWrapper(wrapperPointer);
    MDKInstallDispatchSourceHandlerBlockAtPointer(dispatchSourcePointer);
    MDKMaybeInstallNestedVideoQueueBlockFromWrapperPointer(wrapperPointer, @"wrapper-install");
    NSString *descriptorKey = MDKCopyVideoQueueBlockDescriptorKey(callbackLiteral);
    MDKVideoReceiveQueueBlockInvokeFn originalInvoke =
        reinterpret_cast<MDKVideoReceiveQueueBlockInvokeFn>(callbackLiteral->invoke);
    @synchronized(MDKActiveSCKTraceLock) {
        NSMutableDictionary<NSString *, id> *wrappedBlocks = MDKActiveSCKTraceState[@"videoQueueWrapperBlocks"];
        NSMutableDictionary<NSString *, id> *wrappedInvokes = MDKActiveSCKTraceState[@"videoQueueWrapperInvokes"];
        if (wrappedInvokes[blockKey] != nil) {
            return YES;
        }

        wrappedBlocks[wrapperKey] = callbackObject;
        wrappedInvokes[blockKey] = [NSValue valueWithPointer:reinterpret_cast<void *>(originalInvoke)];
        if (descriptorKey != nil) {
            wrappedInvokes[descriptorKey] = [NSValue valueWithPointer:reinterpret_cast<void *>(originalInvoke)];
        }
        callbackLiteral->invoke = reinterpret_cast<void (*)(void *, ...)>(MDKInterposedVideoQueueBlockInvoke);
    }

    MDKRecordSCKTraceEvent(
        @"video-queue-wrapper-installed",
        @{
            @"wrapperPointer": [NSString stringWithFormat:@"%p", wrapperPointer],
            @"callbackPointer": [NSString stringWithFormat:@"%p", callbackPointer],
            @"callbackOffset": @(callbackOffset),
            @"blockSignature": signature,
            @"originalInvoke": MDKDescribeCodePointer(reinterpret_cast<void *>(originalInvoke)),
            @"installationMode": @"invoke-pointer",
        }
    );
    return YES;
}

static BOOL MDKWrapVideoReceiveQueueCallbackIfPossible(id stream) {
    if (stream == nil) {
        return NO;
    }

    NSValue *wrapperValue = MDKCopyRawPointerIvar(stream, "_videoReceiveQueue");
    if (wrapperValue == nil || wrapperValue.pointerValue == nullptr) {
        return NO;
    }

    return MDKInstallVideoQueueWrapperCallbackAtPointer(wrapperValue.pointerValue);
}

static void MDKRescanNestedVideoQueueBlockIfPossible(id stream, NSString *reason) {
    if (stream == nil) {
        return;
    }

    NSValue *wrapperValue = MDKCopyRawPointerIvar(stream, "_videoReceiveQueue");
    if (wrapperValue == nil || wrapperValue.pointerValue == nullptr) {
        return;
    }

    MDKMaybeInstallNestedVideoQueueBlockFromWrapperPointer(wrapperValue.pointerValue, reason);
}

extern "C" void MDKInterposedFigRemoteQueueReceiverSetHandler(void *receiver, dispatch_queue_t queue, id handler);
extern "C" int MDKInterposedFigRemoteQueueReceiverDequeue(void *receiver, MDKFigRemoteQueueMessage *message);
extern "C" int MDKInterposedFigRemoteQueueReceiverUnsetHandler(void *receiver);
extern "C" dispatch_source_t MDKInterposedDispatchSourceCreate(dispatch_source_type_t type, uintptr_t handle, unsigned long mask, dispatch_queue_t queue);
extern "C" void MDKInterposedDispatchSourceSetEventHandler(dispatch_source_t source, dispatch_block_t handler);
extern "C" void MDKInterposedDispatchSourceSetEventHandlerF(dispatch_source_t source, dispatch_function_t handler);
extern "C" ssize_t MDKInterposedRead(int fd, void *buffer, size_t size);
extern "C" ssize_t MDKInterposedReadNoCancel(int fd, void *buffer, size_t size);
extern "C" ssize_t MDKInterposedWrite(int fd, const void *buffer, size_t size);
extern "C" ssize_t MDKInterposedWriteNoCancel(int fd, const void *buffer, size_t size);
extern "C" int MDKInterposedPipe(int fds[2]);
extern "C" IOSurfaceRef MDKInterposedIOSurfaceLookupFromMachPort(mach_port_t port);
extern "C" mach_port_t MDKInterposedIOSurfaceCreateMachPort(IOSurfaceRef surface);
extern "C" xpc_object_t MDKInterposedXPCPipeCreate(const char *name, std::uint64_t flags);
extern "C" int MDKInterposedXPCPipeSimpleRoutine(xpc_object_t pipe, xpc_object_t message, xpc_object_t *reply);
extern "C" int MDKInterposedXPCFDDup(xpc_object_t object);
extern "C" int MDKInterposedXPCDictionaryDupFD(xpc_object_t object, const char *key);

static void MDKInstallRuntimeFigRemoteQueueReceiverInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeAttempted", @YES);
        MDKEnsureCaptureImageLoaded("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture");
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            MDKAppendSCKTraceNote(@"dyld_dynamic_interpose is unavailable, so FigRemoteQueueReceiver runtime interpose could not be installed.");
            return;
        }

        const void *setHandler = MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverSetHandler");
        const void *dequeue = MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverDequeue");
        const void *unsetHandler = MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverUnsetHandler");
        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeSetHandlerSymbolAvailable", @(setHandler != nullptr));
        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeDequeueSymbolAvailable", @(dequeue != nullptr));
        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeUnsetHandlerSymbolAvailable", @(unsetHandler != nullptr));
        if (setHandler == nullptr || dequeue == nullptr || unsetHandler == nullptr) {
            MDKAppendSCKTraceNote(@"One or more FigRemoteQueueReceiver symbols were unavailable, so runtime interpose stayed disabled.");
            return;
        }

        const MDKDyldInterposeTuple interposes[] = {
            { reinterpret_cast<const void *>(&MDKInterposedFigRemoteQueueReceiverSetHandler), setHandler },
            { reinterpret_cast<const void *>(&MDKInterposedFigRemoteQueueReceiverDequeue), dequeue },
            { reinterpret_cast<const void *>(&MDKInterposedFigRemoteQueueReceiverUnsetHandler), unsetHandler },
        };
        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
            installedImageCount += 1;
        }
        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeScreenCaptureKitImagePresent", @(screenCaptureKitHeader != nullptr));

        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
            installedImageCount += 1;
        }
        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeCMCaptureImagePresent", @(cmCaptureHeader != nullptr));
        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeInstalledImageCount", @(installedImageCount));

        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"Neither ScreenCaptureKit nor CMCapture appeared in the loaded image list, so FigRemoteQueueReceiver runtime interpose could not be installed.");
            return;
        }

        MDKSetSCKTraceStateValue(@"figRemoteQueueReceiverInterposeInstalled", @YES);
        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed FigRemoteQueueReceiver runtime interpose on %lu image(s).", (unsigned long)installedImageCount]);
    });
}

static void MDKInstallDispatchReadSourceInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"dispatchReadSourceInterposeAttempted", @YES);
        MDKEnsureCaptureImageLoaded("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture");
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"dispatchReadSourceInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            return;
        }

        MDKOriginalDispatchSourceCreate =
            reinterpret_cast<MDKDispatchSourceCreateFn>(dlsym(RTLD_DEFAULT, "dispatch_source_create"));
        MDKOriginalDispatchSourceSetEventHandler =
            reinterpret_cast<MDKDispatchSourceSetEventHandlerFn>(dlsym(RTLD_DEFAULT, "dispatch_source_set_event_handler"));
        MDKOriginalDispatchSourceSetEventHandlerF =
            reinterpret_cast<MDKDispatchSourceSetEventHandlerFFn>(dlsym(RTLD_DEFAULT, "dispatch_source_set_event_handler_f"));
        MDKSetSCKTraceStateValue(@"dispatchReadSourceInterposeCreateSymbolAvailable", @(MDKOriginalDispatchSourceCreate != nullptr));
        MDKSetSCKTraceStateValue(@"dispatchReadSourceInterposeSetEventHandlerSymbolAvailable", @(MDKOriginalDispatchSourceSetEventHandler != nullptr));
        MDKSetSCKTraceStateValue(@"dispatchReadSourceInterposeSetEventHandlerFSymbolAvailable", @(MDKOriginalDispatchSourceSetEventHandlerF != nullptr));
        if (MDKOriginalDispatchSourceCreate == nullptr ||
            MDKOriginalDispatchSourceSetEventHandler == nullptr ||
            MDKOriginalDispatchSourceSetEventHandlerF == nullptr) {
            MDKAppendSCKTraceNote(@"One or more libdispatch read-source symbols were unavailable, so dispatch-source interpose stayed disabled.");
            return;
        }

        const MDKDyldInterposeTuple interposes[] = {
            { reinterpret_cast<const void *>(&MDKInterposedDispatchSourceCreate), reinterpret_cast<const void *>(MDKOriginalDispatchSourceCreate) },
            { reinterpret_cast<const void *>(&MDKInterposedDispatchSourceSetEventHandler), reinterpret_cast<const void *>(MDKOriginalDispatchSourceSetEventHandler) },
            { reinterpret_cast<const void *>(&MDKInterposedDispatchSourceSetEventHandlerF), reinterpret_cast<const void *>(MDKOriginalDispatchSourceSetEventHandlerF) },
        };

        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
            installedImageCount += 1;
        }
        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
            installedImageCount += 1;
        }

        MDKSetSCKTraceStateValue(@"dispatchReadSourceInterposeInstalledImageCount", @(installedImageCount));
        MDKSetSCKTraceStateValue(@"dispatchReadSourceInterposeInstalled", @(installedImageCount > 0));
        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"Neither ScreenCaptureKit nor CMCapture appeared in the loaded image list, so dispatch-source interpose stayed disabled.");
            return;
        }

        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed dispatch read-source interpose on %lu image(s).", (unsigned long) installedImageCount]);
    });
}

static void MDKInstallFIFOReadInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"fifoReadInterposeAttempted", @YES);
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"fifoReadInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            return;
        }

        MDKOriginalRead = reinterpret_cast<MDKReadFn>(dlsym(RTLD_DEFAULT, "read"));
        MDKOriginalReadNoCancel = reinterpret_cast<MDKReadFn>(dlsym(RTLD_DEFAULT, "read_nocancel"));
        if (MDKOriginalReadNoCancel == nullptr) {
            MDKOriginalReadNoCancel = reinterpret_cast<MDKReadFn>(dlsym(RTLD_DEFAULT, "__read_nocancel"));
        }
        MDKSetSCKTraceStateValue(@"fifoReadInterposeReadSymbolAvailable", @(MDKOriginalRead != nullptr));
        MDKSetSCKTraceStateValue(@"fifoReadInterposeReadNoCancelSymbolAvailable", @(MDKOriginalReadNoCancel != nullptr));
        if (MDKOriginalRead == nullptr && MDKOriginalReadNoCancel == nullptr) {
            MDKAppendSCKTraceNote(@"Neither read nor read_nocancel was available, so fifo read interpose stayed disabled.");
            return;
        }

        MDKDyldInterposeTuple interposes[2] = {};
        size_t interposeCount = 0;
        if (MDKOriginalRead != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedRead),
                reinterpret_cast<const void *>(MDKOriginalRead),
            };
        }
        if (MDKOriginalReadNoCancel != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedReadNoCancel),
                reinterpret_cast<const void *>(MDKOriginalReadNoCancel),
            };
        }

        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *libdispatchHeader =
            MDKFindLoadedImageHeader("/usr/lib/system/libdispatch.dylib");
        if (libdispatchHeader != nullptr) {
            dynamicInterpose(libdispatchHeader, interposes, interposeCount);
            installedImageCount += 1;
        }

        MDKSetSCKTraceStateValue(@"fifoReadInterposeInstalledImageCount", @(installedImageCount));
        MDKSetSCKTraceStateValue(@"fifoReadInterposeInstalledSymbolCount", @(interposeCount));
        MDKSetSCKTraceStateValue(@"fifoReadInterposeInstalled", @(installedImageCount > 0));
        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"ScreenCaptureKit, CMCapture, and libdispatch were absent from the loaded image list, so fifo read interpose stayed disabled.");
            return;
        }

        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed fifo read interpose on %lu image(s) using %lu symbol(s).",
                               (unsigned long)installedImageCount,
                               (unsigned long)interposeCount]);
    });
}

static void MDKInstallFIFOWriteInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"fifoWriteInterposeAttempted", @YES);
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"fifoWriteInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            return;
        }

        MDKOriginalWrite = reinterpret_cast<MDKWriteFn>(dlsym(RTLD_DEFAULT, "write"));
        MDKOriginalWriteNoCancel = reinterpret_cast<MDKWriteFn>(dlsym(RTLD_DEFAULT, "write_nocancel"));
        if (MDKOriginalWriteNoCancel == nullptr) {
            MDKOriginalWriteNoCancel = reinterpret_cast<MDKWriteFn>(dlsym(RTLD_DEFAULT, "__write_nocancel"));
        }
        MDKSetSCKTraceStateValue(@"fifoWriteInterposeWriteSymbolAvailable", @(MDKOriginalWrite != nullptr));
        MDKSetSCKTraceStateValue(@"fifoWriteInterposeWriteNoCancelSymbolAvailable", @(MDKOriginalWriteNoCancel != nullptr));
        if (MDKOriginalWrite == nullptr && MDKOriginalWriteNoCancel == nullptr) {
            MDKAppendSCKTraceNote(@"Neither write nor write_nocancel was available, so fifo write interpose stayed disabled.");
            return;
        }

        MDKDyldInterposeTuple interposes[2] = {};
        size_t interposeCount = 0;
        if (MDKOriginalWrite != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedWrite),
                reinterpret_cast<const void *>(MDKOriginalWrite),
            };
        }
        if (MDKOriginalWriteNoCancel != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedWriteNoCancel),
                reinterpret_cast<const void *>(MDKOriginalWriteNoCancel),
            };
        }

        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *libdispatchHeader =
            MDKFindLoadedImageHeader("/usr/lib/system/libdispatch.dylib");
        if (libdispatchHeader != nullptr) {
            dynamicInterpose(libdispatchHeader, interposes, interposeCount);
            installedImageCount += 1;
        }

        MDKSetSCKTraceStateValue(@"fifoWriteInterposeInstalledImageCount", @(installedImageCount));
        MDKSetSCKTraceStateValue(@"fifoWriteInterposeInstalledSymbolCount", @(interposeCount));
        MDKSetSCKTraceStateValue(@"fifoWriteInterposeInstalled", @(installedImageCount > 0));
        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"ScreenCaptureKit, CMCapture, and libdispatch were absent from the loaded image list, so fifo write interpose stayed disabled.");
            return;
        }

        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed fifo write interpose on %lu image(s) using %lu symbol(s).",
                               (unsigned long)installedImageCount,
                               (unsigned long)interposeCount]);
    });
}

static void MDKInstallXPCFDInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"xpcFDInterposeAttempted", @YES);
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"xpcFDInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            return;
        }

        MDKOriginalXPCFDDup = reinterpret_cast<MDKXPCFDDupFn>(dlsym(RTLD_DEFAULT, "xpc_fd_dup"));
        MDKOriginalXPCDictionaryDupFD =
            reinterpret_cast<MDKXPCDictionaryDupFDFn>(dlsym(RTLD_DEFAULT, "xpc_dictionary_dup_fd"));
        MDKSetSCKTraceStateValue(@"xpcFDInterposeXPCFDDupSymbolAvailable", @(MDKOriginalXPCFDDup != nullptr));
        MDKSetSCKTraceStateValue(@"xpcFDInterposeXPCDictionaryDupFDSymbolAvailable", @(MDKOriginalXPCDictionaryDupFD != nullptr));
        if (MDKOriginalXPCFDDup == nullptr && MDKOriginalXPCDictionaryDupFD == nullptr) {
            MDKAppendSCKTraceNote(@"Neither xpc_fd_dup nor xpc_dictionary_dup_fd was available, so xpc fd interpose stayed disabled.");
            return;
        }

        MDKDyldInterposeTuple interposes[2] = {};
        size_t interposeCount = 0;
        if (MDKOriginalXPCFDDup != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedXPCFDDup),
                reinterpret_cast<const void *>(MDKOriginalXPCFDDup),
            };
        }
        if (MDKOriginalXPCDictionaryDupFD != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedXPCDictionaryDupFD),
                reinterpret_cast<const void *>(MDKOriginalXPCDictionaryDupFD),
            };
        }

        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *libxpcHeader =
            MDKFindLoadedImageHeader("/usr/lib/system/libxpc.dylib");
        if (libxpcHeader != nullptr) {
            dynamicInterpose(libxpcHeader, interposes, interposeCount);
            installedImageCount += 1;
        }

        MDKSetSCKTraceStateValue(@"xpcFDInterposeInstalledImageCount", @(installedImageCount));
        MDKSetSCKTraceStateValue(@"xpcFDInterposeInstalledSymbolCount", @(interposeCount));
        MDKSetSCKTraceStateValue(@"xpcFDInterposeInstalled", @(installedImageCount > 0));
        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"ScreenCaptureKit, CMCapture, and libxpc were absent from the loaded image list, so xpc fd interpose stayed disabled.");
            return;
        }

        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed xpc fd interpose on %lu image(s) using %lu symbol(s).",
                               (unsigned long)installedImageCount,
                               (unsigned long)interposeCount]);
    });
}

static void MDKInstallXPCPipeInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"xpcPipeInterposeAttempted", @YES);
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"xpcPipeInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            return;
        }

        MDKOriginalXPCPipeCreate =
            reinterpret_cast<MDKXPCPipeCreateFn>(dlsym(RTLD_DEFAULT, "xpc_pipe_create"));
        MDKOriginalXPCPipeSimpleRoutine =
            reinterpret_cast<MDKXPCPipeSimpleRoutineFn>(dlsym(RTLD_DEFAULT, "xpc_pipe_simpleroutine"));
        MDKSetSCKTraceStateValue(@"xpcPipeInterposeCreateSymbolAvailable", @(MDKOriginalXPCPipeCreate != nullptr));
        MDKSetSCKTraceStateValue(@"xpcPipeInterposeSimpleRoutineSymbolAvailable", @(MDKOriginalXPCPipeSimpleRoutine != nullptr));
        if (MDKOriginalXPCPipeCreate == nullptr && MDKOriginalXPCPipeSimpleRoutine == nullptr) {
            MDKAppendSCKTraceNote(@"Neither xpc_pipe_create nor xpc_pipe_simpleroutine was available, so xpc pipe interpose stayed disabled.");
            return;
        }

        MDKDyldInterposeTuple interposes[2] = {};
        size_t interposeCount = 0;
        if (MDKOriginalXPCPipeCreate != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedXPCPipeCreate),
                reinterpret_cast<const void *>(MDKOriginalXPCPipeCreate),
            };
        }
        if (MDKOriginalXPCPipeSimpleRoutine != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedXPCPipeSimpleRoutine),
                reinterpret_cast<const void *>(MDKOriginalXPCPipeSimpleRoutine),
            };
        }

        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *libxpcHeader =
            MDKFindLoadedImageHeader("/usr/lib/system/libxpc.dylib");
        if (libxpcHeader != nullptr) {
            dynamicInterpose(libxpcHeader, interposes, interposeCount);
            installedImageCount += 1;
        }

        MDKSetSCKTraceStateValue(@"xpcPipeInterposeInstalledImageCount", @(installedImageCount));
        MDKSetSCKTraceStateValue(@"xpcPipeInterposeInstalledSymbolCount", @(interposeCount));
        MDKSetSCKTraceStateValue(@"xpcPipeInterposeInstalled", @(installedImageCount > 0));
        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"ScreenCaptureKit, CMCapture, and libxpc were absent from the loaded image list, so xpc pipe interpose stayed disabled.");
            return;
        }

        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed xpc pipe interpose on %lu image(s) using %lu symbol(s).",
                               (unsigned long)installedImageCount,
                               (unsigned long)interposeCount]);
    });
}

static void MDKInstallPipeInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"pipeInterposeAttempted", @YES);
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"pipeInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            return;
        }

        MDKOriginalPipe = reinterpret_cast<MDKPipeFn>(dlsym(RTLD_DEFAULT, "pipe"));
        MDKSetSCKTraceStateValue(@"pipeInterposeSymbolAvailable", @(MDKOriginalPipe != nullptr));
        if (MDKOriginalPipe == nullptr) {
            MDKAppendSCKTraceNote(@"pipe was unavailable, so pipe interpose stayed disabled.");
            return;
        }

        const MDKDyldInterposeTuple interposes[] = {
            { reinterpret_cast<const void *>(&MDKInterposedPipe), reinterpret_cast<const void *>(MDKOriginalPipe) },
        };

        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
            installedImageCount += 1;
        }
        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
            installedImageCount += 1;
        }
        const mach_header *libxpcHeader =
            MDKFindLoadedImageHeader("/usr/lib/system/libxpc.dylib");
        if (libxpcHeader != nullptr) {
            dynamicInterpose(libxpcHeader, interposes, sizeof(interposes) / sizeof(interposes[0]));
            installedImageCount += 1;
        }

        MDKSetSCKTraceStateValue(@"pipeInterposeInstalledImageCount", @(installedImageCount));
        MDKSetSCKTraceStateValue(@"pipeInterposeInstalled", @(installedImageCount > 0));
        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"ScreenCaptureKit, CMCapture, and libxpc were absent from the loaded image list, so pipe interpose stayed disabled.");
            return;
        }

        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed pipe interpose on %lu image(s).",
                               (unsigned long)installedImageCount]);
    });
}

static void MDKInstallIOSurfaceMachPortInterposes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        using MDKDyldDynamicInterposeFn = void (*)(const mach_header *, const MDKDyldInterposeTuple[], size_t);

        MDKSetSCKTraceStateValue(@"ioSurfaceMachInterposeAttempted", @YES);
        auto dynamicInterpose =
            reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "dyld_dynamic_interpose"));
        if (dynamicInterpose == nullptr) {
            dynamicInterpose =
                reinterpret_cast<MDKDyldDynamicInterposeFn>(dlsym(RTLD_DEFAULT, "_dyld_dynamic_interpose"));
        }
        MDKSetSCKTraceStateValue(@"ioSurfaceMachInterposeDyldAvailable", @(dynamicInterpose != nullptr));
        if (dynamicInterpose == nullptr) {
            return;
        }

        MDKOriginalIOSurfaceLookupFromMachPort =
            reinterpret_cast<MDKIOSurfaceLookupFromMachPortFn>(dlsym(RTLD_DEFAULT, "IOSurfaceLookupFromMachPort"));
        MDKOriginalIOSurfaceCreateMachPort =
            reinterpret_cast<MDKIOSurfaceCreateMachPortFn>(dlsym(RTLD_DEFAULT, "IOSurfaceCreateMachPort"));
        MDKSetSCKTraceStateValue(@"ioSurfaceMachLookupSymbolAvailable", @(MDKOriginalIOSurfaceLookupFromMachPort != nullptr));
        MDKSetSCKTraceStateValue(@"ioSurfaceCreateMachPortSymbolAvailable", @(MDKOriginalIOSurfaceCreateMachPort != nullptr));
        if (MDKOriginalIOSurfaceLookupFromMachPort == nullptr && MDKOriginalIOSurfaceCreateMachPort == nullptr) {
            MDKAppendSCKTraceNote(@"Neither IOSurfaceLookupFromMachPort nor IOSurfaceCreateMachPort was available, so IOSurface mach-port interpose stayed disabled.");
            return;
        }

        MDKDyldInterposeTuple interposes[2] = {};
        size_t interposeCount = 0;
        if (MDKOriginalIOSurfaceLookupFromMachPort != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedIOSurfaceLookupFromMachPort),
                reinterpret_cast<const void *>(MDKOriginalIOSurfaceLookupFromMachPort),
            };
        }
        if (MDKOriginalIOSurfaceCreateMachPort != nullptr) {
            interposes[interposeCount++] = {
                reinterpret_cast<const void *>(&MDKInterposedIOSurfaceCreateMachPort),
                reinterpret_cast<const void *>(MDKOriginalIOSurfaceCreateMachPort),
            };
        }

        NSUInteger installedImageCount = 0;
        const mach_header *screenCaptureKitHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/ScreenCaptureKit.framework/");
        if (screenCaptureKitHeader != nullptr) {
            dynamicInterpose(screenCaptureKitHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *cmCaptureHeader =
            MDKFindLoadedImageHeader("/System/Library/PrivateFrameworks/CMCapture.framework/");
        if (cmCaptureHeader != nullptr) {
            dynamicInterpose(cmCaptureHeader, interposes, interposeCount);
            installedImageCount += 1;
        }
        const mach_header *ioSurfaceHeader =
            MDKFindLoadedImageHeader("/System/Library/Frameworks/IOSurface.framework/");
        if (ioSurfaceHeader != nullptr) {
            dynamicInterpose(ioSurfaceHeader, interposes, interposeCount);
            installedImageCount += 1;
        }

        MDKSetSCKTraceStateValue(@"ioSurfaceMachInterposeInstalledImageCount", @(installedImageCount));
        MDKSetSCKTraceStateValue(@"ioSurfaceMachInterposeInstalledSymbolCount", @(interposeCount));
        MDKSetSCKTraceStateValue(@"ioSurfaceMachInterposeInstalled", @(installedImageCount > 0));
        if (installedImageCount == 0) {
            MDKAppendSCKTraceNote(@"ScreenCaptureKit, CMCapture, and IOSurface were absent from the loaded image list, so IOSurface mach-port interpose stayed disabled.");
            return;
        }

        MDKAppendSCKTraceNote([NSString stringWithFormat:@"Installed IOSurface mach-port interpose on %lu image(s) using %lu symbol(s).",
                               (unsigned long)installedImageCount,
                               (unsigned long)interposeCount]);
    });
}

static void (*MDKResolveOriginalFigRemoteQueueReceiverSetHandler(void))(void *, dispatch_queue_t, id) {
    static void (*original)(void *, dispatch_queue_t, id) = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        original = reinterpret_cast<void (*)(void *, dispatch_queue_t, id)>(dlsym(RTLD_NEXT, "FigRemoteQueueReceiverSetHandler"));
        if (original == nullptr) {
            original = reinterpret_cast<void (*)(void *, dispatch_queue_t, id)>(MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverSetHandler"));
        }
    });
    return original;
}

static int (*MDKResolveOriginalFigRemoteQueueReceiverDequeue(void))(void *, MDKFigRemoteQueueMessage *) {
    static int (*original)(void *, MDKFigRemoteQueueMessage *) = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        original = reinterpret_cast<int (*)(void *, MDKFigRemoteQueueMessage *)>(dlsym(RTLD_NEXT, "FigRemoteQueueReceiverDequeue"));
        if (original == nullptr) {
            original = reinterpret_cast<int (*)(void *, MDKFigRemoteQueueMessage *)>(MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverDequeue"));
        }
    });
    return original;
}

static int (*MDKResolveOriginalFigRemoteQueueReceiverUnsetHandler(void))(void *) {
    static int (*original)(void *) = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        original = reinterpret_cast<int (*)(void *)>(dlsym(RTLD_NEXT, "FigRemoteQueueReceiverUnsetHandler"));
        if (original == nullptr) {
            original = reinterpret_cast<int (*)(void *)>(MDKLookupCMCaptureSymbol("FigRemoteQueueReceiverUnsetHandler"));
        }
    });
    return original;
}

static void MDKRecordFigRemoteQueueReceiverHandlerCallbackEvent(
    void *receiver,
    int status,
    MDKFigRemoteQueueMessage *message,
    void *context
) {
    NSDictionary<NSString *, id> *payload = @{
        @"receiver": MDKSummarizePointerValue(receiver),
        @"status": @(status),
        @"context": MDKSummarizePointerValue(context),
        @"messageType": message != nullptr ? static_cast<id>(@(message->messageType)) : [NSNull null],
        @"surface": message != nullptr ? MDKSummarizeIOSurface(message->surface) : @{ @"present": @NO },
    };
    MDKRecordSCKTraceEvent(@"fig-remote-queue-receiver-handler-callback", payload);
}

extern "C" void MDKInterposedFigRemoteQueueReceiverSetHandler(void *receiver, dispatch_queue_t queue, id handler) {
    auto original = MDKResolveOriginalFigRemoteQueueReceiverSetHandler();
    if (original == nullptr) {
        return;
    }

    NSString *blockSignature = MDKCopyBlockSignatureString(handler);
    NSString *queueLabel = queue != nil ? ([NSString stringWithUTF8String:dispatch_queue_get_label(queue)] ?: @"") : @"";

    id wrappedHandler = handler;
    if (handler != nil && blockSignature != nil && [blockSignature containsString:@"FigRemoteQueueMessage"]) {
        MDKFigRemoteQueueReceiverHandlerBlock originalHandler = handler;
        dispatch_queue_t targetQueue = MDKNormalizeTraceQueue(queue, @"com.skyline23.MacDisplayKit.fig-remote-queue-handler");
        MDKFigRemoteQueueReceiverHandlerBlock wrappedBlock = [^(int status, MDKFigRemoteQueueMessage *message, void *context) {
            MDKRecordFigRemoteQueueReceiverHandlerCallbackEvent(receiver, status, message, context);
            originalHandler(status, message, context);
        } copy];
        wrappedHandler = wrappedBlock;

        @synchronized(MDKActiveSCKTraceLock) {
            if (MDKActiveSCKTraceState != nil) {
                NSMutableDictionary<NSString *, id> *wrappedHandlers = MDKActiveSCKTraceState[@"figRemoteQueueReceiverWrappedHandlers"];
                NSString *receiverKey = [NSString stringWithFormat:@"%p", receiver];
                wrappedHandlers[receiverKey] = wrappedBlock;
                MDKActiveFigRemoteQueueReceiver = receiver;
                MDKActiveFigRemoteQueueReceiverQueue = targetQueue;
            }
        }
    }

    MDKRecordSCKTraceEvent(
        @"fig-remote-queue-receiver-set-handler",
        @{
            @"receiver": MDKSummarizePointerValue(receiver),
            @"queue": MDKSummarizeObject(queue),
            @"queueLabel": queueLabel,
            @"handler": MDKSummarizeObject(handler),
            @"handlerPointer": MDKSummarizePointerValue((__bridge const void *)handler),
            @"handlerWrapped": @(wrappedHandler != handler),
            @"blockSignature": blockSignature ?: [NSNull null],
        }
    );

    original(receiver, queue, wrappedHandler);
}

extern "C" int MDKInterposedFigRemoteQueueReceiverDequeue(void *receiver, MDKFigRemoteQueueMessage *message) {
    auto original = MDKResolveOriginalFigRemoteQueueReceiverDequeue();
    if (original == nullptr) {
        return -1;
    }

    const int status = original(receiver, message);
    MDKRecordSCKTraceEvent(
        @"fig-remote-queue-receiver-dequeue",
        @{
            @"receiver": MDKSummarizePointerValue(receiver),
            @"status": @(status),
            @"messageType": message != nullptr ? static_cast<id>(@(message->messageType)) : [NSNull null],
            @"surface": message != nullptr ? MDKSummarizeIOSurface(message->surface) : @{ @"present": @NO },
        }
    );
    return status;
}

extern "C" int MDKInterposedFigRemoteQueueReceiverUnsetHandler(void *receiver) {
    auto original = MDKResolveOriginalFigRemoteQueueReceiverUnsetHandler();
    if (original == nullptr) {
        return -1;
    }

    MDKRecordSCKTraceEvent(
        @"fig-remote-queue-receiver-unset-handler",
        @{
            @"receiver": MDKSummarizePointerValue(receiver),
        }
    );

    @synchronized(MDKActiveSCKTraceLock) {
        if (MDKActiveSCKTraceState != nil) {
            NSMutableDictionary<NSString *, id> *wrappedHandlers = MDKActiveSCKTraceState[@"figRemoteQueueReceiverWrappedHandlers"];
            NSString *receiverKey = [NSString stringWithFormat:@"%p", receiver];
            [wrappedHandlers removeObjectForKey:receiverKey];
        }
    }

    return original(receiver);
}

extern "C" dispatch_source_t MDKInterposedDispatchSourceCreate(
    dispatch_source_type_t type,
    uintptr_t handle,
    unsigned long mask,
    dispatch_queue_t queue
) {
    if (MDKOriginalDispatchSourceCreate == nullptr) {
        return nil;
    }

    dispatch_source_t source = MDKOriginalDispatchSourceCreate(type, handle, mask, queue);
    NSDictionary<NSString *, id> *typePointer = MDKDescribeCodePointer(type);
    NSString *typeSymbol =
        [typePointer[@"symbolName"] isKindOfClass:[NSString class]] ? typePointer[@"symbolName"] : nil;
    if (typeSymbol != nil && [typeSymbol isEqualToString:@"_dispatch_source_type_read"]) {
        NSString *queueLabel = queue != nil ? ([NSString stringWithUTF8String:dispatch_queue_get_label(queue)] ?: @"") : @"";
        MDKRecordDispatchReadSourceInterposeEvent(
            @"dispatch-read-source-create",
            @{
                @"source": MDKSummarizePointerValue((__bridge const void *) source),
                @"type": typePointer,
                @"handle": @(handle),
                @"mask": @(mask),
                @"queue": MDKSummarizeObject(queue),
                @"queueLabel": queueLabel,
            }
        );
    }

    return source;
}

extern "C" void MDKInterposedDispatchSourceSetEventHandler(dispatch_source_t source, dispatch_block_t handler) {
    if (MDKOriginalDispatchSourceSetEventHandler == nullptr) {
        return;
    }

    NSDictionary<NSString *, id> *sourceMetadata = MDKCopyDispatchReadSourceMetadata(source);
    if (sourceMetadata != nil) {
        NSDictionary<NSString *, id> *handlerSummary = handler != nil ? MDKDescribeBlockLiteralObject(handler) : @{ @"present": @NO };
        NSDictionary<NSString *, id> *handlerInvoke =
            [handlerSummary[@"invoke"] isKindOfClass:[NSDictionary class]] ? handlerSummary[@"invoke"] : nil;
        NSString *handlerInvokeSymbol =
            [handlerInvoke[@"symbolName"] isKindOfClass:[NSString class]] ? handlerInvoke[@"symbolName"] : nil;
        MDKRecordDispatchReadSourceInterposeEvent(
            @"dispatch-read-source-set-event-handler",
            @{
                @"dispatchSource": sourceMetadata,
                @"handler": handlerSummary,
                @"handlerInvokeSymbol": handlerInvokeSymbol ?: [NSNull null],
            }
        );
    }

    MDKOriginalDispatchSourceSetEventHandler(source, handler);
}

extern "C" void MDKInterposedDispatchSourceSetEventHandlerF(dispatch_source_t source, dispatch_function_t handler) {
    if (MDKOriginalDispatchSourceSetEventHandlerF == nullptr) {
        return;
    }

    NSDictionary<NSString *, id> *sourceMetadata = MDKCopyDispatchReadSourceMetadata(source);
    if (sourceMetadata != nil) {
        NSDictionary<NSString *, id> *handlerPointer =
            handler != nullptr ? MDKDescribeCodePointer(reinterpret_cast<const void *>(handler)) : @{ @"present": @NO };
        NSString *handlerSymbol =
            [handlerPointer[@"symbolName"] isKindOfClass:[NSString class]] ? handlerPointer[@"symbolName"] : nil;
        MDKRecordDispatchReadSourceInterposeEvent(
            @"dispatch-read-source-set-event-handler-f",
            @{
                @"dispatchSource": sourceMetadata,
                @"handler": handlerPointer,
                @"handlerSymbol": handlerSymbol ?: [NSNull null],
            }
        );
    }

    MDKOriginalDispatchSourceSetEventHandlerF(source, handler);
}

extern "C" ssize_t MDKInterposedRead(int fd, void *buffer, size_t size) {
    if (MDKOriginalRead == nullptr) {
        errno = ENOSYS;
        return -1;
    }

    const BOOL shouldTrace = MDKInterposedFIFOReadDepth == 0 && MDKShouldTraceFIFOReadFD(fd);
    MDKInterposedFIFOReadDepth += 1;
    const ssize_t result = MDKOriginalRead(fd, buffer, size);
    const int savedErrno = errno;
    MDKInterposedFIFOReadDepth -= 1;
    if (shouldTrace) {
        MDKRecordFIFOReadInterposeEvent(@"fifo-read", fd, size, result, savedErrno);
    }
    errno = savedErrno;
    return result;
}

extern "C" ssize_t MDKInterposedReadNoCancel(int fd, void *buffer, size_t size) {
    if (MDKOriginalReadNoCancel == nullptr) {
        errno = ENOSYS;
        return -1;
    }

    const BOOL shouldTrace = MDKInterposedFIFOReadDepth == 0 && MDKShouldTraceFIFOReadFD(fd);
    MDKInterposedFIFOReadDepth += 1;
    const ssize_t result = MDKOriginalReadNoCancel(fd, buffer, size);
    const int savedErrno = errno;
    MDKInterposedFIFOReadDepth -= 1;
    if (shouldTrace) {
        MDKRecordFIFOReadInterposeEvent(@"fifo-read-nocancel", fd, size, result, savedErrno);
    }
    errno = savedErrno;
    return result;
}

extern "C" ssize_t MDKInterposedWrite(int fd, const void *buffer, size_t size) {
    if (MDKOriginalWrite == nullptr) {
        errno = ENOSYS;
        return -1;
    }

    const BOOL shouldTrace = MDKInterposedFIFOWriteDepth == 0 && MDKShouldTraceFIFOReadFD(fd);
    MDKInterposedFIFOWriteDepth += 1;
    const ssize_t result = MDKOriginalWrite(fd, buffer, size);
    const int savedErrno = errno;
    MDKInterposedFIFOWriteDepth -= 1;
    if (shouldTrace) {
        MDKRecordFIFOWriteInterposeEvent(@"fifo-write", fd, size, result, savedErrno);
    }
    errno = savedErrno;
    return result;
}

extern "C" ssize_t MDKInterposedWriteNoCancel(int fd, const void *buffer, size_t size) {
    if (MDKOriginalWriteNoCancel == nullptr) {
        errno = ENOSYS;
        return -1;
    }

    const BOOL shouldTrace = MDKInterposedFIFOWriteDepth == 0 && MDKShouldTraceFIFOReadFD(fd);
    MDKInterposedFIFOWriteDepth += 1;
    const ssize_t result = MDKOriginalWriteNoCancel(fd, buffer, size);
    const int savedErrno = errno;
    MDKInterposedFIFOWriteDepth -= 1;
    if (shouldTrace) {
        MDKRecordFIFOWriteInterposeEvent(@"fifo-write-nocancel", fd, size, result, savedErrno);
    }
    errno = savedErrno;
    return result;
}

extern "C" int MDKInterposedPipe(int fds[2]) {
    if (MDKOriginalPipe == nullptr) {
        errno = ENOSYS;
        return -1;
    }

    int localFDs[2] = { -1, -1 };
    int *targetFDs = fds != nullptr ? fds : localFDs;
    const int result = MDKOriginalPipe(targetFDs);
    const int savedErrno = errno;
    MDKRecordPipeInterposeEvent(result, targetFDs, savedErrno);
    errno = savedErrno;
    return result;
}

extern "C" IOSurfaceRef MDKInterposedIOSurfaceLookupFromMachPort(mach_port_t port) {
    if (MDKOriginalIOSurfaceLookupFromMachPort == nullptr) {
        return nullptr;
    }

    IOSurfaceRef surface = MDKOriginalIOSurfaceLookupFromMachPort(port);
    MDKRecordIOSurfaceMachPortEvent(@"iosurface-lookup-from-mach-port", port, surface);
    return surface;
}

extern "C" mach_port_t MDKInterposedIOSurfaceCreateMachPort(IOSurfaceRef surface) {
    if (MDKOriginalIOSurfaceCreateMachPort == nullptr) {
        return MACH_PORT_NULL;
    }

    const mach_port_t port = MDKOriginalIOSurfaceCreateMachPort(surface);
    MDKRecordIOSurfaceMachPortEvent(@"iosurface-create-mach-port", port, surface);
    return port;
}

extern "C" int MDKInterposedXPCFDDup(xpc_object_t object) {
    if (MDKOriginalXPCFDDup == nullptr) {
        errno = ENOSYS;
        return -1;
    }

    MDKInterposedXPCFDDepth += 1;
    const int result = MDKOriginalXPCFDDup(object);
    const int savedErrno = errno;
    MDKInterposedXPCFDDepth -= 1;
    if (MDKInterposedXPCFDDepth == 0 && MDKShouldTraceFIFOReadFD(result)) {
        MDKRecordXPCFDInterposeEvent(@"xpc-fd-dup", object, nullptr, result, savedErrno);
    }
    errno = savedErrno;
    return result;
}

extern "C" xpc_object_t MDKInterposedXPCPipeCreate(const char *name, std::uint64_t flags) {
    if (MDKOriginalXPCPipeCreate == nullptr) {
        return nullptr;
    }

    MDKInterposedXPCPipeDepth += 1;
    xpc_object_t result = MDKOriginalXPCPipeCreate(name, flags);
    MDKInterposedXPCPipeDepth -= 1;
    if (MDKInterposedXPCPipeDepth == 0) {
        MDKRecordXPCPipeInterposeEvent(@"xpc-pipe-create", name, flags, result, nullptr, nullptr, 0);
    }
    return result;
}

extern "C" int MDKInterposedXPCPipeSimpleRoutine(xpc_object_t pipe, xpc_object_t message, xpc_object_t *reply) {
    if (MDKOriginalXPCPipeSimpleRoutine == nullptr) {
        return ENOSYS;
    }

    MDKInterposedXPCPipeDepth += 1;
    const int status = MDKOriginalXPCPipeSimpleRoutine(pipe, message, reply);
    const xpc_object_t replyObject = reply != nullptr ? *reply : nullptr;
    MDKInterposedXPCPipeDepth -= 1;
    if (MDKInterposedXPCPipeDepth == 0) {
        MDKRecordXPCPipeInterposeEvent(@"xpc-pipe-simpleroutine", nullptr, 0, pipe, message, replyObject, status);
    }
    return status;
}

extern "C" int MDKInterposedXPCDictionaryDupFD(xpc_object_t object, const char *key) {
    if (MDKOriginalXPCDictionaryDupFD == nullptr) {
        errno = ENOSYS;
        return -1;
    }

    MDKInterposedXPCFDDepth += 1;
    const int result = MDKOriginalXPCDictionaryDupFD(object, key);
    const int savedErrno = errno;
    MDKInterposedXPCFDDepth -= 1;
    if (MDKInterposedXPCFDDepth == 0 &&
        (MDKShouldTraceXPCFDDupKey(key) || MDKShouldTraceFIFOReadFD(result))) {
        MDKRecordXPCFDInterposeEvent(@"xpc-dictionary-dup-fd", object, key, result, savedErrno);
    }
    errno = savedErrno;
    return result;
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

static void MDKSwizzledFrameSenderClientSendXCPSampleBuffer(id self, SEL _cmd, id sample) {
    MDKRecordFrameSenderEvent(@"frame-sender-client-send-xcp-sample-buffer", sample);
    MDKOriginalFrameSenderClientSendXCPSampleBuffer(self, _cmd, sample);
}

static void MDKSwizzledFrameSenderServiceSendFrame(id self, SEL _cmd, id sample) {
    MDKRecordFrameSenderEvent(@"frame-sender-service-send-frame", sample);
    MDKOriginalFrameSenderServiceSendFrame(self, _cmd, sample);
}

static id MDKSwizzledFrameSenderServiceNewSampleBuffer(id self, SEL _cmd, id sample) {
    id convertedSample = MDKOriginalFrameSenderServiceNewSampleBuffer(self, _cmd, sample);
    MDKRecordFrameSenderEvent(@"frame-sender-service-new-sample-buffer", convertedSample);
    return convertedSample;
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

static void MDKSwizzledIOSurfaceRemoteHandleMessage(id self, SEL _cmd, id message) {
    MDKRecordSurfaceTransportEvent(
        @"iosurface-remote-handle-message",
        @{
            @"message": MDKSummarizeObject(message),
            @"client": MDKSummarizeObject(self),
        }
    );
    MDKOriginalIOSurfaceRemoteHandleMessage(self, _cmd, message);
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

static id MDKSwizzledBWRemoteQueueSinkInit(id self, SEL _cmd, id mediaType, id auditToken, id sinkID, id cameraInfoByPortType) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-init",
        @{
            @"mediaType": MDKSummarizeObject(mediaType),
            @"auditToken": MDKSummarizeObject(auditToken),
            @"sinkID": MDKSummarizeObject(sinkID),
            @"cameraInfoByPortType": MDKSummarizeObject(cameraInfoByPortType),
        }
    );

    return MDKOriginalBWRemoteQueueSinkInit(self, _cmd, mediaType, auditToken, sinkID, cameraInfoByPortType);
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

static void MDKSwizzledBWRegisterSurfacesFromSourcePool(id self, SEL _cmd, id sourcePool) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-register-surfaces",
        @{
            @"sourcePool": MDKSummarizeObject(sourcePool),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWRegisterSurfacesFromSourcePool(self, _cmd, sourcePool);
}

static void MDKSwizzledBWSetDiscardsLateSampleBuffers(id self, SEL _cmd, BOOL value) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-set-discards-late-sample-buffers",
        @{
            @"value": @(value),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWSetDiscardsLateSampleBuffers(self, _cmd, value);
}

static void MDKSwizzledBWSetFrameSenderSupportEnabled(id self, SEL _cmd, BOOL value) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-set-frame-sender-support-enabled",
        @{
            @"value": @(value),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWSetFrameSenderSupportEnabled(self, _cmd, value);
}

static void MDKSwizzledBWSetVideoHDRImageStatisticsEnabled(id self, SEL _cmd, BOOL value) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-set-video-hdr-image-statistics-enabled",
        @{
            @"value": @(value),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWSetVideoHDRImageStatisticsEnabled(self, _cmd, value);
}

static void MDKSwizzledBWSetClientVideoRetainedBufferCount(id self, SEL _cmd, NSInteger count) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-remote-queue-set-client-video-retained-buffer-count",
        @{
            @"count": @(count),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWSetClientVideoRetainedBufferCount(self, _cmd, count);
}

static void MDKSwizzledBWImageQueueSinkRenderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-image-queue-sink-render",
        @{
            @"sampleBuffer": MDKSummarizeSampleBuffer(sampleBuffer),
            @"input": MDKSummarizeObject(input),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWImageQueueSinkRenderSampleBuffer(self, _cmd, sampleBuffer, input);
}

static void MDKSwizzledBWImageQueueSinkRegisterSurfacesFromSourcePool(id self, SEL _cmd, id sourcePool) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-image-queue-sink-register-surfaces",
        @{
            @"sourcePool": MDKSummarizeObject(sourcePool),
            @"sinkNode": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWImageQueueSinkRegisterSurfacesFromSourcePool(self, _cmd, sourcePool);
}

static void MDKSwizzledBWNodeConnectionConsumeMessage(id self, SEL _cmd, id message, id output) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-node-connection-consume-message",
        @{
            @"message": MDKSummarizeObject(message),
            @"output": MDKSummarizeObject(output),
            @"connection": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWNodeConnectionConsumeMessage(self, _cmd, message, output);
}

static void MDKSwizzledBWNodeHandleMessage(id self, SEL _cmd, id message, id input) {
    MDKRecordRemoteQueueSinkEvent(
        @"bw-node-handle-message",
        @{
            @"message": MDKSummarizeObject(message),
            @"input": MDKSummarizeObject(input),
            @"node": MDKSummarizeObject(self),
        }
    );

    MDKOriginalBWNodeHandleMessage(self, _cmd, message, input);
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
    BOOL shouldWrapVideoQueueCallback = NO;
    @synchronized(MDKActiveSCKTraceLock) {
        needsPrime = MDKActiveSCKAllowPrivateQueueProbes && (MDKActiveSCRemoteQueueWrapper == nullptr);
        shouldWrapVideoQueueCallback = MDKActiveSCKAllowVideoQueueWrapperProbe;
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
    if (shouldWrapVideoQueueCallback) {
        MDKWrapVideoReceiveQueueCallbackIfPossible(self);
        MDKRescanNestedVideoQueueBlockIfPossible(self, @"post-wrap-video");
    }
    MDKRecordSCKTraceEvent(
        @"stream-post-start-remote-video-state",
        @{
            @"queue": MDKSummarizeObject(queue),
            @"streamState": MDKCopySCStreamInternalState(self),
        }
    );
    MDKRescanNestedVideoQueueBlockIfPossible(self, @"post-start-video");
}

static void MDKSwizzledStartRemoteAudioReceiveQueue(id self, SEL _cmd, id queue) {
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-audio-receive-queue", queue);
    MDKOriginalStartRemoteAudioReceiveQueue(self, _cmd, queue);
    MDKRescanNestedVideoQueueBlockIfPossible(self, @"post-start-audio");
}

static void MDKSwizzledStartRemoteMicrophoneReceiveQueue(id self, SEL _cmd, id queue) {
    MDKRecordRemoteQueueConsumerEvent(@"stream-start-remote-microphone-receive-queue", queue);
    MDKOriginalStartRemoteMicrophoneReceiveQueue(self, _cmd, queue);
    MDKRescanNestedVideoQueueBlockIfPossible(self, @"post-start-microphone");
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
        MDKRescanNestedVideoQueueBlockIfPossible(self, @"collect-enter");
        MDKRecordSCKTraceEvent(
            @"collect-stream-data-enter",
            @{
                @"streamState": MDKCopySCStreamInternalState(self),
                @"videoReceiveQueueWrapper": MDKCopyVideoReceiveQueueWrapperState(self),
            }
        );
    }
    MDKOriginalCollectStreamData(self, _cmd);
    if (shouldRecord) {
        MDKRescanNestedVideoQueueBlockIfPossible(self, @"collect-exit");
        MDKRecordSCKTraceEvent(
            @"collect-stream-data-exit",
            @{
                @"streamState": MDKCopySCStreamInternalState(self),
                @"videoReceiveQueueWrapper": MDKCopyVideoReceiveQueueWrapperState(self),
            }
        );
    }
}

static NSDictionary<NSString *, id> *MDKDescribeFigScreenCaptureControllerState(id controller) {
    id configuration = MDKPerformObjectGetter(controller, sel_registerName("screenCaptureConfiguration"));
    return @{
        @"controller": MDKSummarizeObject(controller),
        @"configuration": MDKSummarizeObject(configuration),
        @"minFrameInterval": MDKCopyTraceFriendlyKVCDescription(configuration, @"minFrameInterval"),
        @"numOfIdleFrames": MDKCopyTraceFriendlyKVCDescription(configuration, @"numOfIdleFrames"),
        @"sourceRect": MDKCopyTraceFriendlyKVCDescription(configuration, @"sourceRect"),
    };
}

static void MDKSwizzledFigScreenCaptureControllerStartCapture(id self, SEL _cmd) {
    MDKRecordSCKTraceEvent(@"fig-screen-capture-controller-start-capture", MDKDescribeFigScreenCaptureControllerState(self));
    MDKOriginalFigScreenCaptureControllerStartCapture(self, _cmd);
}

static void MDKSwizzledFigScreenCaptureControllerResumeCapture(id self, SEL _cmd) {
    MDKRecordSCKTraceEvent(@"fig-screen-capture-controller-resume-capture", MDKDescribeFigScreenCaptureControllerState(self));
    MDKOriginalFigScreenCaptureControllerResumeCapture(self, _cmd);
}

static void MDKSwizzledFigScreenCaptureControllerSuspendCapture(id self, SEL _cmd) {
    MDKRecordSCKTraceEvent(@"fig-screen-capture-controller-suspend-capture", MDKDescribeFigScreenCaptureControllerState(self));
    MDKOriginalFigScreenCaptureControllerSuspendCapture(self, _cmd);
}

static void MDKSwizzledFigScreenCaptureControllerStopCapture(id self, SEL _cmd) {
    MDKRecordSCKTraceEvent(@"fig-screen-capture-controller-stop-capture", MDKDescribeFigScreenCaptureControllerState(self));
    MDKOriginalFigScreenCaptureControllerStopCapture(self, _cmd);
}

static void MDKInstallSCKProxyTraceHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW | RTLD_GLOBAL);
        MDKInstallRuntimeFigRemoteQueueReceiverInterposes();
        MDKInstallDispatchReadSourceInterposes();
        MDKInstallFIFOReadInterposes();
        MDKInstallFIFOWriteInterposes();
        MDKInstallPipeInterposes();
        MDKInstallIOSurfaceMachPortInterposes();
        MDKInstallXPCPipeInterposes();
        MDKInstallXPCFDInterposes();
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

        Class figScreenCaptureControllerClass = NSClassFromString(@"FigScreenCaptureController");
        if (figScreenCaptureControllerClass != Nil) {
            Method startCaptureMethod = class_getInstanceMethod(
                figScreenCaptureControllerClass,
                sel_registerName("startCapture")
            );
            if (startCaptureMethod != nullptr) {
                MDKOriginalFigScreenCaptureControllerStartCapture =
                    reinterpret_cast<MDKFigScreenCaptureControllerLifecycleFn>(method_getImplementation(startCaptureMethod));
                method_setImplementation(
                    startCaptureMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFigScreenCaptureControllerStartCapture)
                );
            }

            Method resumeCaptureMethod = class_getInstanceMethod(
                figScreenCaptureControllerClass,
                sel_registerName("resumeCapture")
            );
            if (resumeCaptureMethod != nullptr) {
                MDKOriginalFigScreenCaptureControllerResumeCapture =
                    reinterpret_cast<MDKFigScreenCaptureControllerLifecycleFn>(method_getImplementation(resumeCaptureMethod));
                method_setImplementation(
                    resumeCaptureMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFigScreenCaptureControllerResumeCapture)
                );
            }

            Method suspendCaptureMethod = class_getInstanceMethod(
                figScreenCaptureControllerClass,
                sel_registerName("suspendCapture")
            );
            if (suspendCaptureMethod != nullptr) {
                MDKOriginalFigScreenCaptureControllerSuspendCapture =
                    reinterpret_cast<MDKFigScreenCaptureControllerLifecycleFn>(method_getImplementation(suspendCaptureMethod));
                method_setImplementation(
                    suspendCaptureMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFigScreenCaptureControllerSuspendCapture)
                );
            }

            Method stopCaptureMethod = class_getInstanceMethod(
                figScreenCaptureControllerClass,
                sel_registerName("stopCapture")
            );
            if (stopCaptureMethod != nullptr) {
                MDKOriginalFigScreenCaptureControllerStopCapture =
                    reinterpret_cast<MDKFigScreenCaptureControllerLifecycleFn>(method_getImplementation(stopCaptureMethod));
                method_setImplementation(
                    stopCaptureMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFigScreenCaptureControllerStopCapture)
                );
            }
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

        Class frameSenderClientClass = NSClassFromString(@"CMCaptureFrameSenderClient");
        if (frameSenderClientClass != Nil) {
            Method sendXCPSampleBufferMethod = class_getInstanceMethod(
                frameSenderClientClass,
                sel_registerName("sendXCPSampleBuffer:")
            );
            if (sendXCPSampleBufferMethod != nullptr) {
                MDKOriginalFrameSenderClientSendXCPSampleBuffer =
                    reinterpret_cast<MDKFrameSenderSendSampleFn>(method_getImplementation(sendXCPSampleBufferMethod));
                method_setImplementation(
                    sendXCPSampleBufferMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFrameSenderClientSendXCPSampleBuffer)
                );
            }
        }

        Class frameSenderServiceClass = NSClassFromString(@"CMCaptureFrameSenderService");
        if (frameSenderServiceClass != Nil) {
            Method sendFrameMethod = class_getInstanceMethod(
                frameSenderServiceClass,
                sel_registerName("sendFrame:")
            );
            if (sendFrameMethod != nullptr) {
                MDKOriginalFrameSenderServiceSendFrame =
                    reinterpret_cast<MDKFrameSenderSendSampleFn>(method_getImplementation(sendFrameMethod));
                method_setImplementation(
                    sendFrameMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFrameSenderServiceSendFrame)
                );
            }

            Method newSampleBufferMethod = class_getInstanceMethod(
                frameSenderServiceClass,
                sel_registerName("_newSampleBufferToSendFromSampleBuffer:")
            );
            if (newSampleBufferMethod != nullptr) {
                MDKOriginalFrameSenderServiceNewSampleBuffer =
                    reinterpret_cast<MDKFrameSenderNewSampleBufferFn>(method_getImplementation(newSampleBufferMethod));
                method_setImplementation(
                    newSampleBufferMethod,
                    reinterpret_cast<IMP>(MDKSwizzledFrameSenderServiceNewSampleBuffer)
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

            Method handleMessageMethod = class_getInstanceMethod(
                ioSurfaceRemoteClientClass,
                sel_registerName("_handleMessage:")
            );
            if (handleMessageMethod != nullptr) {
                MDKOriginalIOSurfaceRemoteHandleMessage =
                    reinterpret_cast<MDKIOSurfaceRemoteHandleMessageFn>(method_getImplementation(handleMessageMethod));
                method_setImplementation(
                    handleMessageMethod,
                    reinterpret_cast<IMP>(MDKSwizzledIOSurfaceRemoteHandleMessage)
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
            Method initMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("initWithMediaType:clientAuditToken:sinkID:cameraInfoByPortType:")
            );
            if (initMethod != nullptr) {
                MDKOriginalBWRemoteQueueSinkInit =
                    reinterpret_cast<MDKBWRemoteQueueSinkInitFn>(method_getImplementation(initMethod));
                method_setImplementation(
                    initMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWRemoteQueueSinkInit)
                );
            }

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

            Method registerSurfacesMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("registerSurfacesFromSourcePool:")
            );
            if (registerSurfacesMethod != nullptr) {
                MDKOriginalBWRegisterSurfacesFromSourcePool =
                    reinterpret_cast<MDKBWRegisterSurfacesFromSourcePoolFn>(method_getImplementation(registerSurfacesMethod));
                method_setImplementation(
                    registerSurfacesMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWRegisterSurfacesFromSourcePool)
                );
            }

            Method setDiscardsLateSampleBuffersMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("setDiscardsLateSampleBuffers:")
            );
            if (setDiscardsLateSampleBuffersMethod != nullptr) {
                MDKOriginalBWSetDiscardsLateSampleBuffers =
                    reinterpret_cast<MDKBWSetBoolFn>(method_getImplementation(setDiscardsLateSampleBuffersMethod));
                method_setImplementation(
                    setDiscardsLateSampleBuffersMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWSetDiscardsLateSampleBuffers)
                );
            }

            Method setFrameSenderSupportEnabledMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("setFrameSenderSupportEnabled:")
            );
            if (setFrameSenderSupportEnabledMethod != nullptr) {
                MDKOriginalBWSetFrameSenderSupportEnabled =
                    reinterpret_cast<MDKBWSetBoolFn>(method_getImplementation(setFrameSenderSupportEnabledMethod));
                method_setImplementation(
                    setFrameSenderSupportEnabledMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWSetFrameSenderSupportEnabled)
                );
            }

            Method setVideoHDRImageStatisticsEnabledMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("setVideoHDRImageStatisticsEnabled:")
            );
            if (setVideoHDRImageStatisticsEnabledMethod != nullptr) {
                MDKOriginalBWSetVideoHDRImageStatisticsEnabled =
                    reinterpret_cast<MDKBWSetBoolFn>(method_getImplementation(setVideoHDRImageStatisticsEnabledMethod));
                method_setImplementation(
                    setVideoHDRImageStatisticsEnabledMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWSetVideoHDRImageStatisticsEnabled)
                );
            }

            Method setClientVideoRetainedBufferCountMethod = class_getInstanceMethod(
                bwRemoteQueueSinkNodeClass,
                sel_registerName("setClientVideoRetainedBufferCount:")
            );
            if (setClientVideoRetainedBufferCountMethod != nullptr) {
                MDKOriginalBWSetClientVideoRetainedBufferCount =
                    reinterpret_cast<MDKBWSetIntegerFn>(method_getImplementation(setClientVideoRetainedBufferCountMethod));
                method_setImplementation(
                    setClientVideoRetainedBufferCountMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWSetClientVideoRetainedBufferCount)
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

        Class bwImageQueueSinkNodeClass = NSClassFromString(@"BWImageQueueSinkNode");
        if (bwImageQueueSinkNodeClass != Nil) {
            Method renderSampleBufferMethod = class_getInstanceMethod(
                bwImageQueueSinkNodeClass,
                sel_registerName("renderSampleBuffer:forInput:")
            );
            if (renderSampleBufferMethod != nullptr) {
                MDKOriginalBWImageQueueSinkRenderSampleBuffer =
                    reinterpret_cast<MDKBWRenderSampleBufferFn>(method_getImplementation(renderSampleBufferMethod));
                method_setImplementation(
                    renderSampleBufferMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWImageQueueSinkRenderSampleBuffer)
                );
            }

            Method registerSurfacesMethod = class_getInstanceMethod(
                bwImageQueueSinkNodeClass,
                sel_registerName("registerSurfacesFromSourcePool:")
            );
            if (registerSurfacesMethod != nullptr) {
                MDKOriginalBWImageQueueSinkRegisterSurfacesFromSourcePool =
                    reinterpret_cast<MDKBWRegisterSurfacesFromSourcePoolFn>(method_getImplementation(registerSurfacesMethod));
                method_setImplementation(
                    registerSurfacesMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWImageQueueSinkRegisterSurfacesFromSourcePool)
                );
            }
        }

        Class bwNodeConnectionClass = NSClassFromString(@"BWNodeConnection");
        if (bwNodeConnectionClass != Nil) {
            Method consumeMessageMethod = class_getInstanceMethod(
                bwNodeConnectionClass,
                sel_registerName("consumeMessage:fromOutput:")
            );
            if (consumeMessageMethod != nullptr) {
                MDKOriginalBWNodeConnectionConsumeMessage =
                    reinterpret_cast<MDKBWNodeConnectionConsumeMessageFn>(method_getImplementation(consumeMessageMethod));
                method_setImplementation(
                    consumeMessageMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWNodeConnectionConsumeMessage)
                );
            }
        }

        Class bwNodeClass = NSClassFromString(@"BWNode");
        if (bwNodeClass != Nil) {
            Method handleMessageMethod = class_getInstanceMethod(
                bwNodeClass,
                sel_registerName("_handleMessage:fromInput:")
            );
            if (handleMessageMethod != nullptr) {
                MDKOriginalBWNodeHandleMessage =
                    reinterpret_cast<MDKBWNodeHandleMessageFn>(method_getImplementation(handleMessageMethod));
                method_setImplementation(
                    handleMessageMethod,
                    reinterpret_cast<IMP>(MDKSwizzledBWNodeHandleMessage)
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
    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKAllowPrivateQueueProbes = includePrivateQueueProbes;
        MDKActiveSCKAllowVideoQueueWrapperProbe = YES;
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
        int videoRecvFD = -1;
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
        while (CFAbsoluteTimeGetCurrent() < deadline) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
            }
            if (videoRecvFD < 0) {
                videoRecvFD = MDKDuplicateVideoRemoteQueueFD("RecvFd");
            }
            MDKObserveVideoRemoteQueueReceiveFD(videoRecvFD);
            MDKObserveVideoRemoteQueueSharedRegion();
        }
        if (videoRecvFD >= 0) {
            close(videoRecvFD);
        }
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

    NSDictionary<NSString *, id> *videoReceiveQueueWrapper =
        MDKCopyVideoReceiveQueueWrapperState(stream);

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKTraceState = nil;
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

        if ([kind isEqualToString:@"collect-stream-data-enter"] || [kind isEqualToString:@"collect-stream-data-exit"]) {
            [selectors addObject:@"collectStreamData"];
            [symbols addObject:@"SCStream"];
            NSDictionary<NSString *, id> *wrapperState =
                [event[@"videoReceiveQueueWrapper"] isKindOfClass:[NSDictionary class]] ? event[@"videoReceiveQueueWrapper"] : nil;
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"streamState=%@", MDKDescribeTraceValue(event[@"streamState"])],
                [NSString stringWithFormat:@"videoReceiveQueueWrapper=%@", MDKDescribeTraceValue(wrapperState)],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
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

        if ([kind isEqualToString:@"frame-sender-client-send-xcp-sample-buffer"] ||
            [kind isEqualToString:@"frame-sender-service-send-frame"] ||
            [kind isEqualToString:@"frame-sender-service-new-sample-buffer"]) {
            NSString *selector = nil;
            NSString *symbol = nil;
            if ([kind isEqualToString:@"frame-sender-client-send-xcp-sample-buffer"]) {
                selector = @"sendXCPSampleBuffer:";
                symbol = @"CMCaptureFrameSenderClient";
            } else if ([kind isEqualToString:@"frame-sender-service-send-frame"]) {
                selector = @"sendFrame:";
                symbol = @"CMCaptureFrameSenderService";
            } else {
                selector = @"_newSampleBufferToSendFromSampleBuffer:";
                symbol = @"CMCaptureFrameSenderService";
            }
            [selectors addObject:selector];
            [symbols addObject:symbol];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"sample=%@", MDKDescribeTraceValue(event[@"sample"])],
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

        if ([kind isEqualToString:@"bw-remote-queue-init"] ||
            [kind isEqualToString:@"bw-remote-queue-render"] ||
            [kind isEqualToString:@"bw-remote-queue-drop"] ||
            [kind isEqualToString:@"bw-remote-queue-register-surfaces"] ||
            [kind isEqualToString:@"bw-remote-queue-set-discards-late-sample-buffers"] ||
            [kind isEqualToString:@"bw-remote-queue-set-frame-sender-support-enabled"] ||
            [kind isEqualToString:@"bw-remote-queue-set-video-hdr-image-statistics-enabled"] ||
            [kind isEqualToString:@"bw-remote-queue-set-client-video-retained-buffer-count"] ||
            [kind isEqualToString:@"bw-image-queue-sink-render"] ||
            [kind isEqualToString:@"bw-image-queue-sink-register-surfaces"] ||
            [kind isEqualToString:@"bw-node-connection-consume-message"] ||
            [kind isEqualToString:@"bw-node-handle-message"]) {
            NSString *selector = nil;
            if ([kind isEqualToString:@"bw-remote-queue-init"]) {
                selector = @"initWithMediaType:clientAuditToken:sinkID:cameraInfoByPortType:";
            } else if ([kind isEqualToString:@"bw-remote-queue-render"]) {
                selector = @"renderSampleBuffer:forInput:";
            } else if ([kind isEqualToString:@"bw-remote-queue-drop"]) {
                selector = @"handleDroppedSample:forInput:";
            } else if ([kind isEqualToString:@"bw-remote-queue-register-surfaces"]) {
                selector = @"registerSurfacesFromSourcePool:";
            } else if ([kind isEqualToString:@"bw-remote-queue-set-discards-late-sample-buffers"]) {
                selector = @"setDiscardsLateSampleBuffers:";
            } else if ([kind isEqualToString:@"bw-remote-queue-set-frame-sender-support-enabled"]) {
                selector = @"setFrameSenderSupportEnabled:";
            } else if ([kind isEqualToString:@"bw-remote-queue-set-video-hdr-image-statistics-enabled"]) {
                selector = @"setVideoHDRImageStatisticsEnabled:";
            } else if ([kind isEqualToString:@"bw-remote-queue-set-client-video-retained-buffer-count"]) {
                selector = @"setClientVideoRetainedBufferCount:";
            } else if ([kind isEqualToString:@"bw-image-queue-sink-render"]) {
                selector = @"renderSampleBuffer:forInput:";
            } else if ([kind isEqualToString:@"bw-image-queue-sink-register-surfaces"]) {
                selector = @"registerSurfacesFromSourcePool:";
            } else if ([kind isEqualToString:@"bw-node-connection-consume-message"]) {
                selector = @"consumeMessage:fromOutput:";
            } else if ([kind isEqualToString:@"bw-node-handle-message"]) {
                selector = @"_handleMessage:fromInput:";
            }
            [selectors addObject:selector];
            NSString *symbol = @"BWRemoteQueueSinkNode";
            if ([kind isEqualToString:@"bw-image-queue-sink-render"] || [kind isEqualToString:@"bw-image-queue-sink-register-surfaces"]) {
                symbol = @"BWImageQueueSinkNode";
            } else if ([kind isEqualToString:@"bw-node-connection-consume-message"]) {
                symbol = @"BWNodeConnection";
            } else if ([kind isEqualToString:@"bw-node-handle-message"]) {
                symbol = @"BWNode";
            }
            [symbols addObject:symbol];
            NSMutableArray<NSString *> *notes = [NSMutableArray array];
            if (event[@"sinkNode"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"sinkNode=%@", MDKDescribeTraceValue(event[@"sinkNode"])]];
            }
            if (event[@"input"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"input=%@", MDKDescribeTraceValue(event[@"input"])]];
            }
            if (event[@"connection"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"connection=%@", MDKDescribeTraceValue(event[@"connection"])]];
            }
            if (event[@"node"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"node=%@", MDKDescribeTraceValue(event[@"node"])]];
            }
            if (event[@"output"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"output=%@", MDKDescribeTraceValue(event[@"output"])]];
            }
            if (event[@"message"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"message=%@", MDKDescribeTraceValue(event[@"message"])]];
            }
            if ([kind isEqualToString:@"bw-remote-queue-init"]) {
                [notes addObject:[NSString stringWithFormat:@"mediaType=%@", MDKDescribeTraceValue(event[@"mediaType"])]];
                [notes addObject:[NSString stringWithFormat:@"auditToken=%@", MDKDescribeTraceValue(event[@"auditToken"])]];
                [notes addObject:[NSString stringWithFormat:@"sinkID=%@", MDKDescribeTraceValue(event[@"sinkID"])]];
                [notes addObject:[NSString stringWithFormat:@"cameraInfoByPortType=%@", MDKDescribeTraceValue(event[@"cameraInfoByPortType"])]];
            } else if ([kind isEqualToString:@"bw-remote-queue-render"]) {
                [notes addObject:[NSString stringWithFormat:@"sampleBuffer=%@", MDKDescribeTraceValue(event[@"sampleBuffer"])]];
            } else if ([kind isEqualToString:@"bw-remote-queue-drop"]) {
                [notes addObject:[NSString stringWithFormat:@"sample=%@", MDKDescribeTraceValue(event[@"sample"])]];
            } else if ([kind isEqualToString:@"bw-remote-queue-register-surfaces"]) {
                [notes addObject:[NSString stringWithFormat:@"sourcePool=%@", MDKDescribeTraceValue(event[@"sourcePool"])]];
            } else if (event[@"value"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"value=%@", MDKDescribeTraceValue(event[@"value"])]];
            } else if (event[@"count"] != nil) {
                [notes addObject:[NSString stringWithFormat:@"count=%@", MDKDescribeTraceValue(event[@"count"])]];
            }
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

        if ([kind isEqualToString:@"fig-screen-capture-controller-start-capture"] ||
            [kind isEqualToString:@"fig-screen-capture-controller-resume-capture"] ||
            [kind isEqualToString:@"fig-screen-capture-controller-suspend-capture"] ||
            [kind isEqualToString:@"fig-screen-capture-controller-stop-capture"]) {
            NSString *selector = @"startCapture";
            if ([kind isEqualToString:@"fig-screen-capture-controller-resume-capture"]) {
                selector = @"resumeCapture";
            } else if ([kind isEqualToString:@"fig-screen-capture-controller-suspend-capture"]) {
                selector = @"suspendCapture";
            } else if ([kind isEqualToString:@"fig-screen-capture-controller-stop-capture"]) {
                selector = @"stopCapture";
            }
            [selectors addObject:selector];
            [symbols addObject:@"FigScreenCaptureController"];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"controller=%@", MDKDescribeTraceValue(event[@"controller"])],
                [NSString stringWithFormat:@"configuration=%@", MDKDescribeTraceValue(event[@"configuration"])],
                [NSString stringWithFormat:@"minFrameInterval=%@", MDKDescribeTraceValue(event[@"minFrameInterval"])],
                [NSString stringWithFormat:@"numOfIdleFrames=%@", MDKDescribeTraceValue(event[@"numOfIdleFrames"])],
                [NSString stringWithFormat:@"sourceRect=%@", MDKDescribeTraceValue(event[@"sourceRect"])],
            ] mutableCopy];
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(kind, selector, @"FigScreenCaptureController", nil, @YES, notes)];
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

        if ([kind isEqualToString:@"fig-remote-queue-receiver-set-handler"] ||
            [kind isEqualToString:@"fig-remote-queue-receiver-unset-handler"]) {
            NSString *symbol = [kind isEqualToString:@"fig-remote-queue-receiver-set-handler"]
                ? @"FigRemoteQueueReceiverSetHandler"
                : @"FigRemoteQueueReceiverUnsetHandler";
            [symbols addObject:symbol];
            NSMutableArray<NSString *> *notes = [@[
                [NSString stringWithFormat:@"receiver=%@", MDKDescribeTraceValue(event[@"receiver"])],
            ] mutableCopy];
            if ([kind isEqualToString:@"fig-remote-queue-receiver-set-handler"]) {
                [notes addObject:[NSString stringWithFormat:@"queue=%@", MDKDescribeTraceValue(event[@"queue"])]];
                [notes addObject:[NSString stringWithFormat:@"queueLabel=%@", MDKDescribeTraceValue(event[@"queueLabel"])]];
                [notes addObject:[NSString stringWithFormat:@"handler=%@", MDKDescribeTraceValue(event[@"handler"])]];
                [notes addObject:[NSString stringWithFormat:@"handlerPointer=%@", MDKDescribeTraceValue(event[@"handlerPointer"])]];
                [notes addObject:[NSString stringWithFormat:@"handlerWrapped=%@", MDKDescribeTraceValue(event[@"handlerWrapped"])]];
                [notes addObject:[NSString stringWithFormat:@"blockSignature=%@", MDKDescribeTraceValue(event[@"blockSignature"])]];
            }
            [notes addObjectsFromArray:MDKTraceDiagnosticNotes(event)];
            [steps addObject:MDKMakeTraceStep(
                kind,
                nil,
                symbol,
                nil,
                @YES,
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
        @"video-queue-wrapper-callback",
        @"sc-remote-queue-wrapper-probe",
        @"fig-remote-queue-receiver-probe",
    ];
    for (NSDictionary<NSString *, id> *event in traceEvents) {
        NSString *kind = event[@"kind"];
        if (![privateQueueEventKinds containsObject:kind]) {
            continue;
        }

        NSNumber *callbackTimestampNanos =
            [event[@"callbackTimestampNanos"] isKindOfClass:[NSNumber class]] ? event[@"callbackTimestampNanos"] :
            ([event[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? event[@"timestampNanos"] : nil);
        if (![callbackTimestampNanos isKindOfClass:[NSNumber class]]) {
            continue;
        }

        if (firstPrivateQueueTimestampNanos == nil ||
            callbackTimestampNanos.unsignedLongLongValue < firstPrivateQueueTimestampNanos.unsignedLongLongValue) {
            firstPrivateQueueTimestampNanos = callbackTimestampNanos;
            firstPrivateQueueSource = kind;
            if ([event[@"callbackSurface"] isKindOfClass:[NSDictionary class]]) {
                firstPrivateQueueSurface = event[@"callbackSurface"];
            } else if ([event[@"surface"] isKindOfClass:[NSDictionary class]]) {
                firstPrivateQueueSurface = event[@"surface"];
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

    NSDictionary<NSString *, id> *firstVideoQueueCallbackEvent = nil;
    NSDictionary<NSString *, id> *firstVideoQueueCallbackPrecedingEvent = nil;
    NSDictionary<NSString *, id> *firstVideoQueueNestedBlockCallbackEvent = nil;
    NSUInteger firstVideoQueueCallbackEventIndex = NSNotFound;
    NSUInteger firstVideoQueueNestedBlockCallbackEventIndex = NSNotFound;
    for (NSUInteger idx = 0; idx < traceEvents.count; ++idx) {
        NSDictionary<NSString *, id> *event = traceEvents[idx];
        if (firstVideoQueueNestedBlockCallbackEvent == nil &&
            [event[@"kind"] isEqualToString:@"video-queue-nested-block-callback"]) {
            firstVideoQueueNestedBlockCallbackEvent = event;
            firstVideoQueueNestedBlockCallbackEventIndex = idx;
        }
        if (firstVideoQueueCallbackEvent != nil ||
            ![event[@"kind"] isEqualToString:@"video-queue-wrapper-callback"]) {
            continue;
        }

        firstVideoQueueCallbackEvent = event;
        firstVideoQueueCallbackEventIndex = idx;
        if (idx > 0 && [traceEvents[idx - 1] isKindOfClass:[NSDictionary class]]) {
            firstVideoQueueCallbackPrecedingEvent = traceEvents[idx - 1];
        }
    }

    NSNumber *firstVideoQueueCallbackTimestampNanos =
        [firstVideoQueueCallbackEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? firstVideoQueueCallbackEvent[@"timestampNanos"] : nil;
    NSNumber *firstVideoQueueNestedBlockCallbackTimestampNanos =
        [firstVideoQueueNestedBlockCallbackEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? firstVideoQueueNestedBlockCallbackEvent[@"timestampNanos"] : nil;
    NSDictionary<NSString *, id> *firstVideoQueueNestedBlockPrecedingEvent =
        (firstVideoQueueNestedBlockCallbackEventIndex != NSNotFound && firstVideoQueueNestedBlockCallbackEventIndex > 0 &&
         [traceEvents[firstVideoQueueNestedBlockCallbackEventIndex - 1] isKindOfClass:[NSDictionary class]]) ?
            traceEvents[firstVideoQueueNestedBlockCallbackEventIndex - 1] : nil;
    NSString *firstVideoQueueNestedBlockPrecedingEventKind =
        [firstVideoQueueNestedBlockPrecedingEvent[@"kind"] isKindOfClass:[NSString class]] ? firstVideoQueueNestedBlockPrecedingEvent[@"kind"] : nil;
    NSNumber *firstVideoQueueNestedBlockPrecedingEventTimestampNanos =
        [firstVideoQueueNestedBlockPrecedingEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ?
            firstVideoQueueNestedBlockPrecedingEvent[@"timestampNanos"] : nil;
    NSNumber *firstVideoQueueNestedBlockPrecedingEventLeadMilliseconds = nil;
    if ([firstVideoQueueNestedBlockCallbackTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstVideoQueueNestedBlockPrecedingEventTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstVideoQueueNestedBlockCallbackTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstVideoQueueNestedBlockPrecedingEventTimestampNanos.unsignedLongLongValue);
        firstVideoQueueNestedBlockPrecedingEventLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }
    NSDictionary<NSString *, id> *firstVideoQueueCallbackSurface =
        [firstVideoQueueCallbackEvent[@"surface"] isKindOfClass:[NSDictionary class]] ? firstVideoQueueCallbackEvent[@"surface"] : nil;
    NSString *firstVideoQueueCallbackSurfacePointer =
        [firstVideoQueueCallbackSurface[@"pointer"] isKindOfClass:[NSString class]] ? firstVideoQueueCallbackSurface[@"pointer"] : nil;
    NSNumber *firstVideoQueueNestedBlockLeadMilliseconds = nil;
    if ([firstPublicSampleTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstVideoQueueNestedBlockCallbackTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstPublicSampleTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstVideoQueueNestedBlockCallbackTimestampNanos.unsignedLongLongValue);
        firstVideoQueueNestedBlockLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }
    NSDictionary<NSString *, id> *firstSuccessfulVideoQueueNestedBlockRescan = nil;
    if (firstVideoQueueCallbackEventIndex != NSNotFound) {
        for (NSUInteger idx = 0; idx < firstVideoQueueCallbackEventIndex; ++idx) {
            NSDictionary<NSString *, id> *event = traceEvents[idx];
            if (![event[@"kind"] isEqualToString:@"video-queue-nested-block-rescan"]) {
                continue;
            }

            NSNumber *installed = [event[@"installed"] isKindOfClass:[NSNumber class]] ? event[@"installed"] : nil;
            if (installed != nil && installed.boolValue) {
                firstSuccessfulVideoQueueNestedBlockRescan = event;
                break;
            }
        }
    }
    NSString *firstSuccessfulVideoQueueNestedBlockRescanReason =
        [firstSuccessfulVideoQueueNestedBlockRescan[@"reason"] isKindOfClass:[NSString class]] ? firstSuccessfulVideoQueueNestedBlockRescan[@"reason"] : nil;
    NSNumber *firstSuccessfulVideoQueueNestedBlockRescanTimestampNanos =
        [firstSuccessfulVideoQueueNestedBlockRescan[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? firstSuccessfulVideoQueueNestedBlockRescan[@"timestampNanos"] : nil;
    NSNumber *firstSuccessfulVideoQueueNestedBlockRescanLeadMilliseconds = nil;
    if ([firstVideoQueueCallbackTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstSuccessfulVideoQueueNestedBlockRescanTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstVideoQueueCallbackTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstSuccessfulVideoQueueNestedBlockRescanTimestampNanos.unsignedLongLongValue);
        firstSuccessfulVideoQueueNestedBlockRescanLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }
    NSNumber *firstVideoQueueCallbackPrecedingEventIndexNumber =
        (firstVideoQueueCallbackEventIndex != NSNotFound && firstVideoQueueCallbackEventIndex > 0) ?
            @(firstVideoQueueCallbackEventIndex - 1) : nil;
    NSString *firstVideoQueueCallbackPrecedingEventKind =
        [firstVideoQueueCallbackPrecedingEvent[@"kind"] isKindOfClass:[NSString class]] ? firstVideoQueueCallbackPrecedingEvent[@"kind"] : nil;
    NSString *firstVideoQueueCallbackPrecedingEventSelector =
        [firstVideoQueueCallbackPrecedingEvent[@"selector"] isKindOfClass:[NSString class]] ? firstVideoQueueCallbackPrecedingEvent[@"selector"] : nil;
    NSString *firstVideoQueueCallbackPrecedingEventSymbol =
        [firstVideoQueueCallbackPrecedingEvent[@"symbol"] isKindOfClass:[NSString class]] ? firstVideoQueueCallbackPrecedingEvent[@"symbol"] : nil;
    NSNumber *firstVideoQueueCallbackPrecedingEventTimestampNanos =
        [firstVideoQueueCallbackPrecedingEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ?
            firstVideoQueueCallbackPrecedingEvent[@"timestampNanos"] : nil;
    NSDictionary<NSString *, id> *firstVideoQueueCallbackPrecedingEventStreamState =
        [firstVideoQueueCallbackPrecedingEvent[@"streamState"] isKindOfClass:[NSDictionary class]] ?
            firstVideoQueueCallbackPrecedingEvent[@"streamState"] : nil;
    NSNumber *firstVideoQueueCallbackPrecedingEventLeadMilliseconds = nil;
    if ([firstVideoQueueCallbackTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstVideoQueueCallbackPrecedingEventTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstVideoQueueCallbackTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstVideoQueueCallbackPrecedingEventTimestampNanos.unsignedLongLongValue);
        firstVideoQueueCallbackPrecedingEventLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }

    NSDictionary<NSString *, id> *firstVideoQueueCallbackLastSetupEvent = nil;
    NSNumber *firstVideoQueueCallbackLastSetupEventIndexNumber = nil;
    if (firstVideoQueueCallbackEventIndex != NSNotFound) {
        for (NSInteger idx = static_cast<NSInteger>(firstVideoQueueCallbackEventIndex) - 1; idx >= 0; --idx) {
            NSDictionary<NSString *, id> *event = traceEvents[static_cast<NSUInteger>(idx)];
            if (!isVideoRelatedTraceEvent(event)) {
                continue;
            }

            firstVideoQueueCallbackLastSetupEvent = event;
            firstVideoQueueCallbackLastSetupEventIndexNumber = @(idx);
            break;
        }
    }
    NSString *firstVideoQueueCallbackLastSetupEventKind =
        [firstVideoQueueCallbackLastSetupEvent[@"kind"] isKindOfClass:[NSString class]] ?
            firstVideoQueueCallbackLastSetupEvent[@"kind"] : nil;
    NSString *firstVideoQueueCallbackLastSetupEventSelector =
        [firstVideoQueueCallbackLastSetupEvent[@"selector"] isKindOfClass:[NSString class]] ?
            firstVideoQueueCallbackLastSetupEvent[@"selector"] : nil;
    NSString *firstVideoQueueCallbackLastSetupEventSymbol =
        [firstVideoQueueCallbackLastSetupEvent[@"symbol"] isKindOfClass:[NSString class]] ?
            firstVideoQueueCallbackLastSetupEvent[@"symbol"] : nil;
    NSNumber *firstVideoQueueCallbackLastSetupEventTimestampNanos =
        [firstVideoQueueCallbackLastSetupEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ?
            firstVideoQueueCallbackLastSetupEvent[@"timestampNanos"] : nil;
    NSNumber *firstVideoQueueCallbackLastSetupEventLeadMilliseconds = nil;
    if ([firstVideoQueueCallbackTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstVideoQueueCallbackLastSetupEventTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstVideoQueueCallbackTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstVideoQueueCallbackLastSetupEventTimestampNanos.unsignedLongLongValue);
        firstVideoQueueCallbackLastSetupEventLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }
    NSNumber *firstVideoQueueCrossQueueSetupTailMilliseconds = nil;
    if ([firstVideoQueueCallbackPrecedingEventTimestampNanos isKindOfClass:[NSNumber class]] &&
        [firstVideoQueueCallbackLastSetupEventTimestampNanos isKindOfClass:[NSNumber class]]) {
        const long double deltaNanos =
            static_cast<long double>(firstVideoQueueCallbackPrecedingEventTimestampNanos.unsignedLongLongValue) -
            static_cast<long double>(firstVideoQueueCallbackLastSetupEventTimestampNanos.unsignedLongLongValue);
        firstVideoQueueCrossQueueSetupTailMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
    }
    NSMutableArray<NSString *> *firstVideoQueueCallbackInterveningEventKinds = [NSMutableArray array];
    if ([firstVideoQueueCallbackLastSetupEventIndexNumber isKindOfClass:[NSNumber class]] &&
        firstVideoQueueCallbackEventIndex != NSNotFound) {
        NSUInteger lastSetupEventIndex = firstVideoQueueCallbackLastSetupEventIndexNumber.unsignedIntegerValue;
        for (NSUInteger idx = lastSetupEventIndex + 1; idx < firstVideoQueueCallbackEventIndex; ++idx) {
            NSDictionary<NSString *, id> *event = traceEvents[idx];
            NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
            if (kind != nil) {
                [firstVideoQueueCallbackInterveningEventKinds addObject:kind];
            }
        }
    }
    NSDictionary<NSString *, id> *lastCollectStreamDataEnterBeforeVideoQueueCallback = nil;
    NSDictionary<NSString *, id> *lastCollectStreamDataExitBeforeVideoQueueCallback = nil;
    if (firstVideoQueueCallbackEventIndex != NSNotFound) {
        for (NSInteger idx = static_cast<NSInteger>(firstVideoQueueCallbackEventIndex) - 1; idx >= 0; --idx) {
            NSDictionary<NSString *, id> *event = traceEvents[idx];
            NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
            if (lastCollectStreamDataExitBeforeVideoQueueCallback == nil &&
                [kind isEqualToString:@"collect-stream-data-exit"]) {
                lastCollectStreamDataExitBeforeVideoQueueCallback = event;
            }
            if (lastCollectStreamDataEnterBeforeVideoQueueCallback == nil &&
                [kind isEqualToString:@"collect-stream-data-enter"]) {
                lastCollectStreamDataEnterBeforeVideoQueueCallback = event;
            }
            if (lastCollectStreamDataEnterBeforeVideoQueueCallback != nil &&
                lastCollectStreamDataExitBeforeVideoQueueCallback != nil) {
                break;
            }
        }
    }
    NSNumber *lastCollectStreamDataEnterLeadMilliseconds = nil;
    NSNumber *lastCollectStreamDataExitLeadMilliseconds = nil;
    if ([firstVideoQueueCallbackTimestampNanos isKindOfClass:[NSNumber class]]) {
        NSNumber *enterTimestampNanos =
            [lastCollectStreamDataEnterBeforeVideoQueueCallback[@"timestampNanos"] isKindOfClass:[NSNumber class]] ?
                lastCollectStreamDataEnterBeforeVideoQueueCallback[@"timestampNanos"] : nil;
        NSNumber *exitTimestampNanos =
            [lastCollectStreamDataExitBeforeVideoQueueCallback[@"timestampNanos"] isKindOfClass:[NSNumber class]] ?
                lastCollectStreamDataExitBeforeVideoQueueCallback[@"timestampNanos"] : nil;
        if (enterTimestampNanos != nil) {
            const long double deltaNanos =
                static_cast<long double>(firstVideoQueueCallbackTimestampNanos.unsignedLongLongValue) -
                static_cast<long double>(enterTimestampNanos.unsignedLongLongValue);
            lastCollectStreamDataEnterLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
        }
        if (exitTimestampNanos != nil) {
            const long double deltaNanos =
                static_cast<long double>(firstVideoQueueCallbackTimestampNanos.unsignedLongLongValue) -
                static_cast<long double>(exitTimestampNanos.unsignedLongLongValue);
            lastCollectStreamDataExitLeadMilliseconds = @(static_cast<double>(deltaNanos / 1.0e6L));
        }
    }

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
    NSDictionary<NSString *, id> *videoQueueWrapperCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"video-queue-wrapper-callback",
        ]]
    );
    NSDictionary<NSString *, id> *videoQueueWrapperInvokeEntryCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"video-queue-wrapper-invoke-entry",
        ]]
    );
    NSDictionary<NSString *, id> *videoQueueWrapperInvokeExitCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"video-queue-wrapper-invoke-exit",
        ]]
    );
    NSDictionary<NSString *, id> *rqReceiverSetSourceInvokeEntryCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"rq-receiver-set-source-invoke-entry",
        ]]
    );
    NSDictionary<NSString *, id> *rqReceiverSetSourceInvokeExitCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"rq-receiver-set-source-invoke-exit",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchSourceInvokeEntryCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-source-invoke-entry",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchSourceInvokeExitCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-source-invoke-exit",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchSourceLatchAndCallEntryCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-source-latch-and-call-entry",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchSourceLatchAndCallExitCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-source-latch-and-call-exit",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchClientCalloutRQReceiverEntryCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-client-callout-rq-receiver-entry",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchClientCalloutRQReceiverExitCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-client-callout-rq-receiver-exit",
        ]]
    );
    NSDictionary<NSString *, id> *videoQueueNestedBlockCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"video-queue-nested-block-callback",
        ]]
    );
    NSArray<NSDictionary<NSString *, id> *> *firstVideoQueueWrapperInvokeEntryBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstVideoQueueWrapperInvokeExitBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstRQReceiverSetSourceInvokeEntryBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstRQReceiverSetSourceInvokeExitBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstDispatchSourceInvokeEntryBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstDispatchSourceInvokeExitBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstDispatchSourceLatchAndCallEntryBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstDispatchSourceLatchAndCallExitBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstDispatchClientCalloutRQReceiverEntryBacktrace = nil;
    NSArray<NSDictionary<NSString *, id> *> *firstDispatchClientCalloutRQReceiverExitBacktrace = nil;
    auto copyFirstInterestingWrapperBacktraceFrame = ^NSDictionary<NSString *, id> * _Nullable(NSArray<NSDictionary<NSString *, id> *> *frames) {
        for (NSDictionary<NSString *, id> *frame in frames) {
            NSString *imagePath = [frame[@"imagePath"] isKindOfClass:[NSString class]] ? frame[@"imagePath"] : nil;
            NSString *symbolName = [frame[@"symbolName"] isKindOfClass:[NSString class]] ? frame[@"symbolName"] : nil;
            if (imagePath != nil && [imagePath containsString:@"MacDisplayKitObjCShim"]) {
                continue;
            }
            if (symbolName != nil &&
                ([symbolName containsString:@"MDKInterposedVideoQueueBlockInvoke"] ||
                 [symbolName containsString:@"MDKRecordVideoQueueWrapperInvokeBoundaryEvent"] ||
                 [symbolName containsString:@"MDKInterposedDispatchClientCallout"] ||
                 [symbolName containsString:@"MDKRecordDispatchClientCalloutBoundaryEvent"] ||
                 [symbolName containsString:@"MDKInterposedDispatchSourceInvokeInternal"] ||
                 [symbolName containsString:@"MDKInterposedDispatchSourceLatchAndCallInternal"] ||
                 [symbolName containsString:@"MDKRecordDispatchSourceInternalBoundaryEvent"] ||
                 [symbolName containsString:@"MDKCopyBacktraceFrames"])) {
                continue;
            }
            return frame;
        }
        return nil;
    };
    for (NSDictionary<NSString *, id> *event in traceEvents) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
        NSArray<NSDictionary<NSString *, id> *> *backtrace =
            [event[@"backtrace"] isKindOfClass:[NSArray class]] ? event[@"backtrace"] : nil;
        if (backtrace == nil) {
            continue;
        }
        if (firstVideoQueueWrapperInvokeEntryBacktrace == nil &&
            [kind isEqualToString:@"video-queue-wrapper-invoke-entry"]) {
            firstVideoQueueWrapperInvokeEntryBacktrace = backtrace;
        } else if (firstVideoQueueWrapperInvokeExitBacktrace == nil &&
                   [kind isEqualToString:@"video-queue-wrapper-invoke-exit"]) {
            firstVideoQueueWrapperInvokeExitBacktrace = backtrace;
        } else if (firstRQReceiverSetSourceInvokeEntryBacktrace == nil &&
                   [kind isEqualToString:@"rq-receiver-set-source-invoke-entry"]) {
            firstRQReceiverSetSourceInvokeEntryBacktrace = backtrace;
        } else if (firstRQReceiverSetSourceInvokeExitBacktrace == nil &&
                   [kind isEqualToString:@"rq-receiver-set-source-invoke-exit"]) {
            firstRQReceiverSetSourceInvokeExitBacktrace = backtrace;
        } else if (firstDispatchSourceInvokeEntryBacktrace == nil &&
                   [kind isEqualToString:@"dispatch-source-invoke-entry"]) {
            firstDispatchSourceInvokeEntryBacktrace = backtrace;
        } else if (firstDispatchSourceInvokeExitBacktrace == nil &&
                   [kind isEqualToString:@"dispatch-source-invoke-exit"]) {
            firstDispatchSourceInvokeExitBacktrace = backtrace;
        } else if (firstDispatchSourceLatchAndCallEntryBacktrace == nil &&
                   [kind isEqualToString:@"dispatch-source-latch-and-call-entry"]) {
            firstDispatchSourceLatchAndCallEntryBacktrace = backtrace;
        } else if (firstDispatchSourceLatchAndCallExitBacktrace == nil &&
                   [kind isEqualToString:@"dispatch-source-latch-and-call-exit"]) {
            firstDispatchSourceLatchAndCallExitBacktrace = backtrace;
        } else if (firstDispatchClientCalloutRQReceiverEntryBacktrace == nil &&
                   [kind isEqualToString:@"dispatch-client-callout-rq-receiver-entry"]) {
            firstDispatchClientCalloutRQReceiverEntryBacktrace = backtrace;
        } else if (firstDispatchClientCalloutRQReceiverExitBacktrace == nil &&
                   [kind isEqualToString:@"dispatch-client-callout-rq-receiver-exit"]) {
            firstDispatchClientCalloutRQReceiverExitBacktrace = backtrace;
        }
        if (firstVideoQueueWrapperInvokeEntryBacktrace != nil &&
            firstVideoQueueWrapperInvokeExitBacktrace != nil &&
            firstRQReceiverSetSourceInvokeEntryBacktrace != nil &&
            firstRQReceiverSetSourceInvokeExitBacktrace != nil &&
            firstDispatchSourceInvokeEntryBacktrace != nil &&
            firstDispatchSourceInvokeExitBacktrace != nil &&
            firstDispatchSourceLatchAndCallEntryBacktrace != nil &&
            firstDispatchSourceLatchAndCallExitBacktrace != nil &&
            firstDispatchClientCalloutRQReceiverEntryBacktrace != nil &&
            firstDispatchClientCalloutRQReceiverExitBacktrace != nil) {
            break;
        }
    }
    NSDictionary<NSString *, id> *firstVideoQueueWrapperInvokeEntryFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstVideoQueueWrapperInvokeEntryBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstVideoQueueWrapperInvokeExitFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstVideoQueueWrapperInvokeExitBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstRQReceiverSetSourceInvokeEntryFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstRQReceiverSetSourceInvokeEntryBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstRQReceiverSetSourceInvokeExitFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstRQReceiverSetSourceInvokeExitBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstDispatchSourceInvokeEntryFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstDispatchSourceInvokeEntryBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstDispatchSourceInvokeExitFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstDispatchSourceInvokeExitBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstDispatchSourceLatchAndCallEntryFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstDispatchSourceLatchAndCallEntryBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstDispatchSourceLatchAndCallExitFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstDispatchSourceLatchAndCallExitBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstDispatchClientCalloutRQReceiverEntryFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstDispatchClientCalloutRQReceiverEntryBacktrace ?: @[]);
    NSDictionary<NSString *, id> *firstDispatchClientCalloutRQReceiverExitFirstInterestingFrame =
        copyFirstInterestingWrapperBacktraceFrame(firstDispatchClientCalloutRQReceiverExitBacktrace ?: @[]);
    NSMutableDictionary<NSString *, NSNumber *> *videoQueueWrapperToNestedLeadHistogramMutable = [NSMutableDictionary dictionary];
    NSUInteger videoQueueWrapperToNestedLeadPairCount = 0;
    double videoQueueWrapperToNestedLeadMinMilliseconds = DBL_MAX;
    double videoQueueWrapperToNestedLeadMaxMilliseconds = 0.0;
    for (NSUInteger idx = 0; idx < traceEvents.count; ++idx) {
        NSDictionary<NSString *, id> *event = traceEvents[idx];
        if (![event[@"kind"] isEqualToString:@"video-queue-wrapper-callback"]) {
            continue;
        }

        NSNumber *wrapperTimestampNanos =
            [event[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? event[@"timestampNanos"] : nil;
        if (wrapperTimestampNanos == nil) {
            continue;
        }

        for (NSUInteger nextIndex = idx + 1; nextIndex < traceEvents.count; ++nextIndex) {
            NSDictionary<NSString *, id> *nextEvent = traceEvents[nextIndex];
            NSString *nextKind = [nextEvent[@"kind"] isKindOfClass:[NSString class]] ? nextEvent[@"kind"] : nil;
            if ([nextKind isEqualToString:@"video-queue-wrapper-callback"]) {
                break;
            }
            if (![nextKind isEqualToString:@"video-queue-nested-block-callback"]) {
                continue;
            }

            NSNumber *nestedTimestampNanos =
                [nextEvent[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? nextEvent[@"timestampNanos"] : nil;
            if (nestedTimestampNanos == nil ||
                nestedTimestampNanos.unsignedLongLongValue < wrapperTimestampNanos.unsignedLongLongValue) {
                break;
            }

            const double leadMilliseconds =
                static_cast<double>(nestedTimestampNanos.unsignedLongLongValue - wrapperTimestampNanos.unsignedLongLongValue) / 1.0e6;
            NSString *bucket = MDKBucketMilliseconds(leadMilliseconds);
            videoQueueWrapperToNestedLeadHistogramMutable[bucket] =
                @([videoQueueWrapperToNestedLeadHistogramMutable[bucket] unsignedIntegerValue] + 1);
            videoQueueWrapperToNestedLeadPairCount += 1;
            videoQueueWrapperToNestedLeadMinMilliseconds =
                std::min(videoQueueWrapperToNestedLeadMinMilliseconds, leadMilliseconds);
            videoQueueWrapperToNestedLeadMaxMilliseconds =
                std::max(videoQueueWrapperToNestedLeadMaxMilliseconds, leadMilliseconds);
            break;
        }
    }
    NSDictionary<NSString *, NSNumber *> *videoQueueWrapperToNestedLeadHistogram =
        [videoQueueWrapperToNestedLeadHistogramMutable copy];
    NSNumber *videoQueueWrapperToNestedLeadMinMillisecondsNumber =
        videoQueueWrapperToNestedLeadPairCount > 0 ? @(videoQueueWrapperToNestedLeadMinMilliseconds) : nil;
    NSNumber *videoQueueWrapperToNestedLeadMaxMillisecondsNumber =
        videoQueueWrapperToNestedLeadPairCount > 0 ? @(videoQueueWrapperToNestedLeadMaxMilliseconds) : nil;
    NSNumber *videoQueueWrapperToNestedLead120HzEquivalentCount =
        @(MDKHistogramCountInRange(videoQueueWrapperToNestedLeadHistogram, 0.0, 10.0));
    NSMutableDictionary<NSNumber *, NSNumber *> *videoQueueWrapperEntryTimestampBySequence = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *videoQueueWrapperExitTimestampBySequence = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *videoQueueFirstNestedTimestampBySequence = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *videoQueueInvokeEntryToExitLeadHistogramMutable = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *videoQueueInvokeEntryToNestedLeadHistogramMutable = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *videoQueueNestedToInvokeExitLeadHistogramMutable = [NSMutableDictionary dictionary];
    NSUInteger videoQueueNestedAttributedCallbackCount = 0;
    NSUInteger videoQueueNestedUnattributedCallbackCount = 0;
    NSUInteger videoQueueNestedInsideWrapperSequenceCount = 0;
    NSUInteger videoQueueInvokeEntryToExitLeadPairCount = 0;
    NSUInteger videoQueueNestedToInvokeExitPairCount = 0;
    double videoQueueInvokeEntryToExitLeadMinMilliseconds = DBL_MAX;
    double videoQueueInvokeEntryToExitLeadMaxMilliseconds = 0.0;
    double videoQueueInvokeEntryToNestedLeadMinMilliseconds = DBL_MAX;
    double videoQueueInvokeEntryToNestedLeadMaxMilliseconds = 0.0;
    double videoQueueNestedToInvokeExitLeadMinMilliseconds = DBL_MAX;
    double videoQueueNestedToInvokeExitLeadMaxMilliseconds = 0.0;
    for (NSDictionary<NSString *, id> *event in traceEvents) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
        NSNumber *timestampNanos = [event[@"timestampNanos"] isKindOfClass:[NSNumber class]] ? event[@"timestampNanos"] : nil;
        NSNumber *wrapperSequenceID = [event[@"wrapperSequenceID"] isKindOfClass:[NSNumber class]] ? event[@"wrapperSequenceID"] : nil;
        if (kind == nil || timestampNanos == nil) {
            continue;
        }

        if ([kind isEqualToString:@"video-queue-wrapper-invoke-entry"]) {
            if (wrapperSequenceID != nil && wrapperSequenceID.unsignedLongLongValue > 0) {
                videoQueueWrapperEntryTimestampBySequence[wrapperSequenceID] = timestampNanos;
            }
            continue;
        }

        if ([kind isEqualToString:@"video-queue-wrapper-invoke-exit"]) {
            if (wrapperSequenceID != nil && wrapperSequenceID.unsignedLongLongValue > 0) {
                videoQueueWrapperExitTimestampBySequence[wrapperSequenceID] = timestampNanos;
            }
            continue;
        }

        if (![kind isEqualToString:@"video-queue-nested-block-callback"]) {
            continue;
        }

        if (wrapperSequenceID == nil || wrapperSequenceID.unsignedLongLongValue == 0) {
            videoQueueNestedUnattributedCallbackCount += 1;
            continue;
        }

        videoQueueNestedAttributedCallbackCount += 1;
        if (videoQueueFirstNestedTimestampBySequence[wrapperSequenceID] == nil) {
            videoQueueFirstNestedTimestampBySequence[wrapperSequenceID] = timestampNanos;
        }
    }

    for (NSNumber *wrapperSequenceID in videoQueueWrapperEntryTimestampBySequence) {
        NSNumber *entryTimestampNanos = videoQueueWrapperEntryTimestampBySequence[wrapperSequenceID];
        NSNumber *nestedTimestampNanos = videoQueueFirstNestedTimestampBySequence[wrapperSequenceID];
        NSNumber *exitTimestampNanos = videoQueueWrapperExitTimestampBySequence[wrapperSequenceID];
        if (entryTimestampNanos != nil &&
            exitTimestampNanos != nil &&
            exitTimestampNanos.unsignedLongLongValue >= entryTimestampNanos.unsignedLongLongValue) {
            const double entryToExitLeadMilliseconds =
                static_cast<double>(exitTimestampNanos.unsignedLongLongValue - entryTimestampNanos.unsignedLongLongValue) / 1.0e6;
            MDKIncrementMutableHistogram(
                videoQueueInvokeEntryToExitLeadHistogramMutable,
                MDKBucketMilliseconds(entryToExitLeadMilliseconds)
            );
            videoQueueInvokeEntryToExitLeadPairCount += 1;
            videoQueueInvokeEntryToExitLeadMinMilliseconds =
                std::min(videoQueueInvokeEntryToExitLeadMinMilliseconds, entryToExitLeadMilliseconds);
            videoQueueInvokeEntryToExitLeadMaxMilliseconds =
                std::max(videoQueueInvokeEntryToExitLeadMaxMilliseconds, entryToExitLeadMilliseconds);
        }

        if (entryTimestampNanos == nil || nestedTimestampNanos == nil ||
            nestedTimestampNanos.unsignedLongLongValue < entryTimestampNanos.unsignedLongLongValue) {
            continue;
        }

        const double entryToNestedLeadMilliseconds =
            static_cast<double>(nestedTimestampNanos.unsignedLongLongValue - entryTimestampNanos.unsignedLongLongValue) / 1.0e6;
        MDKIncrementMutableHistogram(
            videoQueueInvokeEntryToNestedLeadHistogramMutable,
            MDKBucketMilliseconds(entryToNestedLeadMilliseconds)
        );
        videoQueueInvokeEntryToNestedLeadMinMilliseconds =
            std::min(videoQueueInvokeEntryToNestedLeadMinMilliseconds, entryToNestedLeadMilliseconds);
        videoQueueInvokeEntryToNestedLeadMaxMilliseconds =
            std::max(videoQueueInvokeEntryToNestedLeadMaxMilliseconds, entryToNestedLeadMilliseconds);

        if (exitTimestampNanos == nil || exitTimestampNanos.unsignedLongLongValue < nestedTimestampNanos.unsignedLongLongValue) {
            continue;
        }

        videoQueueNestedInsideWrapperSequenceCount += 1;
        const double nestedToExitLeadMilliseconds =
            static_cast<double>(exitTimestampNanos.unsignedLongLongValue - nestedTimestampNanos.unsignedLongLongValue) / 1.0e6;
        MDKIncrementMutableHistogram(
            videoQueueNestedToInvokeExitLeadHistogramMutable,
            MDKBucketMilliseconds(nestedToExitLeadMilliseconds)
        );
        videoQueueNestedToInvokeExitPairCount += 1;
        videoQueueNestedToInvokeExitLeadMinMilliseconds =
            std::min(videoQueueNestedToInvokeExitLeadMinMilliseconds, nestedToExitLeadMilliseconds);
        videoQueueNestedToInvokeExitLeadMaxMilliseconds =
            std::max(videoQueueNestedToInvokeExitLeadMaxMilliseconds, nestedToExitLeadMilliseconds);
    }
    NSDictionary<NSString *, NSNumber *> *videoQueueInvokeEntryToExitLeadHistogram =
        [videoQueueInvokeEntryToExitLeadHistogramMutable copy];
    NSDictionary<NSString *, NSNumber *> *videoQueueInvokeEntryToNestedLeadHistogram =
        [videoQueueInvokeEntryToNestedLeadHistogramMutable copy];
    NSDictionary<NSString *, NSNumber *> *videoQueueNestedToInvokeExitLeadHistogram =
        [videoQueueNestedToInvokeExitLeadHistogramMutable copy];
    NSNumber *videoQueueInvokeEntryToExitLeadMinMillisecondsNumber =
        videoQueueInvokeEntryToExitLeadPairCount > 0 ? @(videoQueueInvokeEntryToExitLeadMinMilliseconds) : nil;
    NSNumber *videoQueueInvokeEntryToExitLeadMaxMillisecondsNumber =
        videoQueueInvokeEntryToExitLeadPairCount > 0 ? @(videoQueueInvokeEntryToExitLeadMaxMilliseconds) : nil;
    NSNumber *videoQueueInvokeEntryToNestedLeadMinMillisecondsNumber =
        videoQueueInvokeEntryToNestedLeadHistogram.count > 0 ? @(videoQueueInvokeEntryToNestedLeadMinMilliseconds) : nil;
    NSNumber *videoQueueInvokeEntryToNestedLeadMaxMillisecondsNumber =
        videoQueueInvokeEntryToNestedLeadHistogram.count > 0 ? @(videoQueueInvokeEntryToNestedLeadMaxMilliseconds) : nil;
    NSNumber *videoQueueNestedToInvokeExitLeadMinMillisecondsNumber =
        videoQueueNestedToInvokeExitPairCount > 0 ? @(videoQueueNestedToInvokeExitLeadMinMilliseconds) : nil;
    NSNumber *videoQueueNestedToInvokeExitLeadMaxMillisecondsNumber =
        videoQueueNestedToInvokeExitPairCount > 0 ? @(videoQueueNestedToInvokeExitLeadMaxMilliseconds) : nil;
    NSNumber *videoQueueInvokeEntryToNestedLead120HzEquivalentCount =
        @(MDKHistogramCountInRange(videoQueueInvokeEntryToNestedLeadHistogram, 0.0, 10.0));
    NSNumber *videoQueueInvokeEntryToExitLead120HzEquivalentCount =
        @(MDKHistogramCountInRange(videoQueueInvokeEntryToExitLeadHistogram, 0.0, 10.0));
    NSNumber *videoQueueNestedToInvokeExitLead120HzEquivalentCount =
        @(MDKHistogramCountInRange(videoQueueNestedToInvokeExitLeadHistogram, 0.0, 10.0));
    NSNumber *firstVideoQueueNestedBlockWrapperSequenceID =
        [firstVideoQueueNestedBlockCallbackEvent[@"wrapperSequenceID"] isKindOfClass:[NSNumber class]] ?
            firstVideoQueueNestedBlockCallbackEvent[@"wrapperSequenceID"] : nil;
    NSNumber *firstVideoQueueNestedBlockWrapperDepth =
        [firstVideoQueueNestedBlockCallbackEvent[@"wrapperDepth"] isKindOfClass:[NSNumber class]] ?
            firstVideoQueueNestedBlockCallbackEvent[@"wrapperDepth"] : nil;
    NSNumber *firstVideoQueueNestedBlockInsideWrapperOriginalInvoke = nil;
    if (firstVideoQueueNestedBlockWrapperSequenceID != nil &&
        firstVideoQueueNestedBlockWrapperSequenceID.unsignedLongLongValue > 0 &&
        firstVideoQueueNestedBlockCallbackTimestampNanos != nil) {
        NSNumber *entryTimestampNanos =
            videoQueueWrapperEntryTimestampBySequence[firstVideoQueueNestedBlockWrapperSequenceID];
        NSNumber *exitTimestampNanos =
            videoQueueWrapperExitTimestampBySequence[firstVideoQueueNestedBlockWrapperSequenceID];
        if (entryTimestampNanos != nil && exitTimestampNanos != nil) {
            const uint64_t nestedTimestampNanos = firstVideoQueueNestedBlockCallbackTimestampNanos.unsignedLongLongValue;
            const BOOL inside =
                entryTimestampNanos.unsignedLongLongValue <= nestedTimestampNanos &&
                nestedTimestampNanos <= exitTimestampNanos.unsignedLongLongValue;
            firstVideoQueueNestedBlockInsideWrapperOriginalInvoke = @(inside);
        }
    }
    NSString *videoReceiveQueueWrapperPointer =
        [videoReceiveQueueWrapper[@"pointer"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapper[@"pointer"] : nil;
    NSNumber *videoReceiveQueueWrapperMallocSize =
        [videoReceiveQueueWrapper[@"mallocSize"] isKindOfClass:[NSNumber class]] ? videoReceiveQueueWrapper[@"mallocSize"] : nil;
    NSArray<NSNumber *> *videoReceiveQueueWrapperCandidateBlockOffsets =
        [videoReceiveQueueWrapper[@"candidateBlockOffsets"] isKindOfClass:[NSArray class]] ? videoReceiveQueueWrapper[@"candidateBlockOffsets"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlock = nil;
    NSArray<NSDictionary<NSString *, id> *> *videoReceiveQueueWrapperSlots =
        [videoReceiveQueueWrapper[@"slots"] isKindOfClass:[NSArray class]] ? videoReceiveQueueWrapper[@"slots"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32 = nil;
    for (NSDictionary<NSString *, id> *slot in videoReceiveQueueWrapperSlots) {
        NSNumber *offset = [slot[@"offset"] isKindOfClass:[NSNumber class]] ? slot[@"offset"] : nil;
        if (offset != nil && offset.unsignedIntegerValue == 32) {
            videoReceiveQueueWrapperSlot32 = slot;
        }
        NSDictionary<NSString *, id> *blockSummary =
            [slot[@"block"] isKindOfClass:[NSDictionary class]] ? slot[@"block"] : nil;
        if (blockSummary != nil) {
            videoReceiveQueuePrimaryBlock = blockSummary;
            break;
        }
    }
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockInvoke =
        [videoReceiveQueuePrimaryBlock[@"invoke"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueuePrimaryBlock[@"invoke"] : nil;
    NSString *videoReceiveQueuePrimaryBlockInvokeSymbol =
        [videoReceiveQueuePrimaryBlockInvoke[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockInvoke[@"symbolName"] : nil;
    NSNumber *videoReceiveQueuePrimaryBlockInvokeImageOffset =
        [videoReceiveQueuePrimaryBlockInvoke[@"imageOffset"] isKindOfClass:[NSNumber class]] ? videoReceiveQueuePrimaryBlockInvoke[@"imageOffset"] : nil;
    NSArray<NSDictionary<NSString *, id> *> *videoReceiveQueuePrimaryBlockCaptureSlots =
        [videoReceiveQueuePrimaryBlock[@"captureSlots"] isKindOfClass:[NSArray class]] ? videoReceiveQueuePrimaryBlock[@"captureSlots"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32 = nil;
    for (NSDictionary<NSString *, id> *slot in videoReceiveQueuePrimaryBlockCaptureSlots) {
        NSNumber *offset = [slot[@"offset"] isKindOfClass:[NSNumber class]] ? slot[@"offset"] : nil;
        if (offset != nil && offset.unsignedIntegerValue == 32) {
            videoReceiveQueuePrimaryBlockCaptureSlot32 = slot;
            break;
        }
    }
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32Pointer =
        [videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointer"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointer"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32CodePointer =
        [videoReceiveQueuePrimaryBlockCaptureSlot32[@"codePointer"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32[@"codePointer"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerSymbol =
        [videoReceiveQueuePrimaryBlockCaptureSlot32CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32CodePointer[@"symbolName"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerImagePath =
        [videoReceiveQueuePrimaryBlockCaptureSlot32CodePointer[@"imagePath"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32CodePointer[@"imagePath"] : nil;
    NSNumber *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeMallocSize =
        [videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointeeMallocSize"] isKindOfClass:[NSNumber class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointeeMallocSize"] : nil;
    NSArray<NSDictionary<NSString *, id> *> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWords =
        [videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointeeWords"] isKindOfClass:[NSArray class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointeeWords"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlock =
        [videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointeeBlock"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32[@"pointeeBlock"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0 =
        videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWords.count > 0 ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWords[0] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1 =
        videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWords.count > 1 ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWords[1] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0CodePointer =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0[@"codePointer"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0[@"codePointer"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1CodePointer =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1[@"codePointer"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1[@"codePointer"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0Symbol =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0CodePointer[@"symbolName"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1Symbol =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1CodePointer[@"symbolName"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0CodePointer[@"imagePath"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0CodePointer[@"imagePath"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1ImagePath =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1CodePointer[@"imagePath"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1CodePointer[@"imagePath"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvoke =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlock[@"invoke"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlock[@"invoke"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeSymbol =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvoke[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvoke[@"symbolName"] : nil;
    NSString *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvoke[@"imagePath"] isKindOfClass:[NSString class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvoke[@"imagePath"] : nil;
    NSArray<NSDictionary<NSString *, id> *> *videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockCaptureSlots =
        [videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlock[@"captureSlots"] isKindOfClass:[NSArray class]] ? videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlock[@"captureSlots"] : nil;
    NSString *videoReceiveQueueWrapperSlot32Pointer =
        [videoReceiveQueueWrapperSlot32[@"pointer"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32[@"pointer"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeObject =
        [videoReceiveQueueWrapperSlot32[@"pointeeObject"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32[@"pointeeObject"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeObjectClassName =
        [videoReceiveQueueWrapperSlot32PointeeObject[@"className"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeObject[@"className"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeObjectDescription =
        [videoReceiveQueueWrapperSlot32PointeeObject[@"description"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeObject[@"description"] : nil;
    NSArray<NSDictionary<NSString *, id> *> *videoReceiveQueueWrapperSlot32PointeeWords =
        [videoReceiveQueueWrapperSlot32[@"pointeeWords"] isKindOfClass:[NSArray class]] ? videoReceiveQueueWrapperSlot32[@"pointeeWords"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6 =
        videoReceiveQueueWrapperSlot32PointeeWords.count > 6 ? videoReceiveQueueWrapperSlot32PointeeWords[6] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord7 =
        videoReceiveQueueWrapperSlot32PointeeWords.count > 7 ? videoReceiveQueueWrapperSlot32PointeeWords[7] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6Pointer =
        [videoReceiveQueueWrapperSlot32PointeeWord6[@"pointer"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6[@"pointer"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6Pointee =
        [videoReceiveQueueWrapperSlot32PointeeWord6[@"pointee"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6[@"pointee"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6Object =
        [videoReceiveQueueWrapperSlot32PointeeWord6Pointee[@"object"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Pointee[@"object"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6ObjectClassName =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"className"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"className"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6ObjectDescription =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"description"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"description"] : nil;
    NSNumber *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandle =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandle"] isKindOfClass:[NSNumber class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandle"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleFileType =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandleFileType"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandleFileType"] : nil;
    NSNumber *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleMode =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandleMode"] isKindOfClass:[NSNumber class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandleMode"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandlePath =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandlePath"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceHandlePath"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointer =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceContextPointer"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceContextPointer"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointee =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceContextPointee"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceContextPointee"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObject =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointee[@"object"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointee[@"object"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObjectClassName =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObject[@"className"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObject[@"className"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0CodePointer =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointee[@"word0CodePointer"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointee[@"word0CodePointer"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0Symbol =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0CodePointer[@"symbolName"] : nil;
    NSArray<NSDictionary<NSString *, id> *> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWords =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceWords"] isKindOfClass:[NSArray class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceWords"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3 =
        videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWords.count > 3 ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWords[3] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3Pointee =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3[@"pointee"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3[@"pointee"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3PointeeObject =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3Pointee[@"object"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3Pointee[@"object"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueClassName =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3PointeeObject[@"className"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3PointeeObject[@"className"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueDescription =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3PointeeObject[@"description"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord3PointeeObject[@"description"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11 =
        videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWords.count > 11 ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWords[11] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11Pointee =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11[@"pointee"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11[@"pointee"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11PointeeWord0CodePointer =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11Pointee[@"word0CodePointer"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11Pointee[@"word0CodePointer"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTypeSymbol =
        [videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11PointeeWord0CodePointer[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceWord11PointeeWord0CodePointer[@"symbolName"] : nil;
    NSNumber *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceMask =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceMask"] isKindOfClass:[NSNumber class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceMask"] : nil;
    NSNumber *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceData =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceData"] isKindOfClass:[NSNumber class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceData"] : nil;
    NSNumber *videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceCancelled =
        [videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceCancelled"] isKindOfClass:[NSNumber class]] ? videoReceiveQueueWrapperSlot32PointeeWord6Object[@"dispatchSourceCancelled"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord7Pointer =
        [videoReceiveQueueWrapperSlot32PointeeWord7[@"pointer"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord7[@"pointer"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord7Pointee =
        [videoReceiveQueueWrapperSlot32PointeeWord7[@"pointee"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord7[@"pointee"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord7Block =
        [videoReceiveQueueWrapperSlot32PointeeWord7Pointee[@"block"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord7Pointee[@"block"] : nil;
    NSDictionary<NSString *, id> *videoReceiveQueueWrapperSlot32PointeeWord7BlockInvoke =
        [videoReceiveQueueWrapperSlot32PointeeWord7Block[@"invoke"] isKindOfClass:[NSDictionary class]] ? videoReceiveQueueWrapperSlot32PointeeWord7Block[@"invoke"] : nil;
    NSString *videoReceiveQueueWrapperSlot32PointeeWord7BlockInvokeSymbol =
        [videoReceiveQueueWrapperSlot32PointeeWord7BlockInvoke[@"symbolName"] isKindOfClass:[NSString class]] ? videoReceiveQueueWrapperSlot32PointeeWord7BlockInvoke[@"symbolName"] : nil;
    NSDictionary<NSString *, id> *figRemoteQueueReceiverSetHandlerSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-set-handler",
        ]]
    );
    NSDictionary<NSString *, id> *figRemoteQueueReceiverHandlerCallbackSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-handler-callback",
        ]]
    );
    NSDictionary<NSString *, id> *figRemoteQueueReceiverDequeueSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-dequeue",
        ]]
    );
    NSDictionary<NSString *, id> *figRemoteQueueReceiverUnsetHandlerSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-unset-handler",
        ]]
    );
    NSDictionary<NSString *, id> *videoQueueWrapperInstallSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"video-queue-wrapper-installed",
        ]]
    );
    NSDictionary<NSString *, id> *videoQueueWrapperInstallEvent = nil;
    NSDictionary<NSString *, id> *videoQueueNestedBlockInstallEvent = nil;
    for (NSDictionary<NSString *, id> *event in traceEvents) {
        NSString *kind = [event[@"kind"] isKindOfClass:[NSString class]] ? event[@"kind"] : nil;
        if ([kind isEqualToString:@"video-queue-wrapper-installed"]) {
            videoQueueWrapperInstallEvent = event;
        } else if ([kind isEqualToString:@"video-queue-nested-block-installed"]) {
            videoQueueNestedBlockInstallEvent = event;
        }
        if (videoQueueWrapperInstallEvent != nil && videoQueueNestedBlockInstallEvent != nil) {
            break;
        }
    }
    NSNumber *videoQueueWrapperInstalledOffset =
        [videoQueueWrapperInstallEvent[@"callbackOffset"] isKindOfClass:[NSNumber class]] ? videoQueueWrapperInstallEvent[@"callbackOffset"] : nil;
    NSDictionary<NSString *, id> *videoQueueWrapperOriginalInvoke =
        [videoQueueWrapperInstallEvent[@"originalInvoke"] isKindOfClass:[NSDictionary class]] ? videoQueueWrapperInstallEvent[@"originalInvoke"] : nil;
    NSString *videoQueueWrapperOriginalInvokeSymbol =
        [videoQueueWrapperOriginalInvoke[@"symbolName"] isKindOfClass:[NSString class]] ? videoQueueWrapperOriginalInvoke[@"symbolName"] : nil;
    NSString *videoQueueWrapperOriginalInvokeImagePath =
        [videoQueueWrapperOriginalInvoke[@"imagePath"] isKindOfClass:[NSString class]] ? videoQueueWrapperOriginalInvoke[@"imagePath"] : nil;
    NSNumber *videoQueueWrapperOriginalInvokeImageOffset =
        [videoQueueWrapperOriginalInvoke[@"imageOffset"] isKindOfClass:[NSNumber class]] ? videoQueueWrapperOriginalInvoke[@"imageOffset"] : nil;
    NSDictionary<NSString *, id> *videoQueueNestedBlockOriginalInvoke =
        [videoQueueNestedBlockInstallEvent[@"originalInvoke"] isKindOfClass:[NSDictionary class]] ? videoQueueNestedBlockInstallEvent[@"originalInvoke"] : nil;
    NSString *videoQueueNestedBlockOriginalInvokeSymbol =
        [videoQueueNestedBlockOriginalInvoke[@"symbolName"] isKindOfClass:[NSString class]] ? videoQueueNestedBlockOriginalInvoke[@"symbolName"] : nil;
    NSString *videoQueueNestedBlockOriginalInvokeImagePath =
        [videoQueueNestedBlockOriginalInvoke[@"imagePath"] isKindOfClass:[NSString class]] ? videoQueueNestedBlockOriginalInvoke[@"imagePath"] : nil;
    NSNumber *videoQueueNestedBlockOriginalInvokeImageOffset =
        [videoQueueNestedBlockOriginalInvoke[@"imageOffset"] isKindOfClass:[NSNumber class]] ? videoQueueNestedBlockOriginalInvoke[@"imageOffset"] : nil;
    NSDictionary<NSString *, id> *videoSharedRegionCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"video-shared-region-change",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchSourceHandlerCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-source-handler-callback",
        ]]
    );
    NSDictionary<NSString *, id> *dispatchSourceHandlerInstallSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"dispatch-source-handler-installed",
        ]]
    );
    NSDictionary<NSString *, id> *videoRecvFDCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"video-recv-fd-signal",
        ]]
    );
    NSDictionary<NSString *, id> *fifoWriteCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fifo-write",
            @"fifo-write-nocancel",
        ]]
    );
    NSDictionary<NSString *, id> *xpcFDDupCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"xpc-fd-dup",
        ]]
    );
    NSDictionary<NSString *, id> *xpcDictionaryDupFDCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"xpc-dictionary-dup-fd",
        ]]
    );
    NSDictionary<NSString *, id> *xpcPipeCreateCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"xpc-pipe-create",
        ]]
    );
    NSDictionary<NSString *, id> *xpcPipeSimpleRoutineCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"xpc-pipe-simpleroutine",
        ]]
    );
    NSDictionary<NSString *, id> *pipeCreateCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"pipe-create",
        ]]
    );
    NSDictionary<NSString *, id> *ioSurfaceLookupCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"iosurface-lookup-from-mach-port",
        ]]
    );
    NSDictionary<NSString *, id> *ioSurfaceCreateCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"iosurface-create-mach-port",
        ]]
    );
    NSDictionary<NSString *, id> *surfaceTransportHandleMessageCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"iosurface-remote-handle-message",
        ]]
    );
    NSDictionary<NSString *, NSNumber *> *frameReceiverKindHistogram = MDKCopyTraceEventKindHistogram(
        traceEvents,
        [NSSet setWithArray:@[
            @"frame-receiver-init",
        ]]
    );
    NSDictionary<NSString *, NSNumber *> *remoteQueueSinkKindHistogram = MDKCopyTraceEventKindHistogram(
        traceEvents,
        [NSSet setWithArray:@[
            @"bw-remote-queue-init",
            @"bw-remote-queue-render",
            @"bw-remote-queue-drop",
            @"bw-remote-queue-register-surfaces",
            @"bw-remote-queue-set-discards-late-sample-buffers",
            @"bw-remote-queue-set-frame-sender-support-enabled",
            @"bw-remote-queue-set-video-hdr-image-statistics-enabled",
            @"bw-remote-queue-set-client-video-retained-buffer-count",
            @"bw-image-queue-sink-render",
            @"bw-image-queue-sink-register-surfaces",
            @"bw-node-connection-consume-message",
            @"bw-node-handle-message",
            @"fig-remote-queue-set-sink",
        ]]
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
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageEventCount=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageDeltaCount=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageDeltaHistogram=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessage120HzEquivalentCount=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageCadenceClassification=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"frameReceiverEventCount=%@", MDKDescribeTraceValue(snapshot[@"frameReceiverEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"frameReceiverKindHistogram=%@", MDKDescribeTraceValue(frameReceiverKindHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkEventCount=%@", MDKDescribeTraceValue(snapshot[@"remoteQueueSinkEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkKindHistogram=%@", MDKDescribeTraceValue(remoteQueueSinkKindHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueObjectEventCount=%@", MDKDescribeTraceValue(snapshot[@"remoteQueueObjectEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperCallbackEventCount=%@", MDKDescribeTraceValue(videoQueueWrapperCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperCallbackDeltaCount=%@", MDKDescribeTraceValue(videoQueueWrapperCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperCallbackDeltaHistogram=%@", MDKDescribeTraceValue(videoQueueWrapperCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperCallback120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueWrapperCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperCallbackCadenceClassification=%@", MDKDescribeTraceValue(videoQueueWrapperCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeEntryEventCount=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeEntryCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeEntryDeltaHistogram=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeEntryCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeEntry120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeEntryCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeEntryCadenceClassification=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeEntryCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueWrapperInvokeEntryBacktrace=%@", MDKDescribeTraceValue(firstVideoQueueWrapperInvokeEntryBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueWrapperInvokeEntryFirstInterestingFrame=%@", MDKDescribeTraceValue(firstVideoQueueWrapperInvokeEntryFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeExitEventCount=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeExitCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeExitDeltaHistogram=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeExitCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeExit120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeExitCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeExitCadenceClassification=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeExitCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueWrapperInvokeExitBacktrace=%@", MDKDescribeTraceValue(firstVideoQueueWrapperInvokeExitBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueWrapperInvokeExitFirstInterestingFrame=%@", MDKDescribeTraceValue(firstVideoQueueWrapperInvokeExitFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"rqReceiverSetSourceInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"rqReceiverSetSourceInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInterposeSymbolAddress=%@", MDKDescribeTraceValue(snapshot[@"rqReceiverSetSourceInterposeSymbolAddress"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeEntryEventCount=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeEntryCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeEntryDeltaHistogram=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeEntryCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeEntry120HzEquivalentCount=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeEntryCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeEntryCadenceClassification=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeEntryCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstRQReceiverSetSourceInvokeEntryBacktrace=%@", MDKDescribeTraceValue(firstRQReceiverSetSourceInvokeEntryBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstRQReceiverSetSourceInvokeEntryFirstInterestingFrame=%@", MDKDescribeTraceValue(firstRQReceiverSetSourceInvokeEntryFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeExitEventCount=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeExitCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeExitDeltaHistogram=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeExitCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeExit120HzEquivalentCount=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeExitCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeExitCadenceClassification=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeExitCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstRQReceiverSetSourceInvokeExitBacktrace=%@", MDKDescribeTraceValue(firstRQReceiverSetSourceInvokeExitBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstRQReceiverSetSourceInvokeExitFirstInterestingFrame=%@", MDKDescribeTraceValue(firstRQReceiverSetSourceInvokeExitFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"dispatchSourceInvokeInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"dispatchSourceInvokeInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeInterposeSymbolAddress=%@", MDKDescribeTraceValue(snapshot[@"dispatchSourceInvokeInterposeSymbolAddress"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeEntryEventCount=%@", MDKDescribeTraceValue(dispatchSourceInvokeEntryCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeEntryDeltaHistogram=%@", MDKDescribeTraceValue(dispatchSourceInvokeEntryCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeEntry120HzEquivalentCount=%@", MDKDescribeTraceValue(dispatchSourceInvokeEntryCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeEntryCadenceClassification=%@", MDKDescribeTraceValue(dispatchSourceInvokeEntryCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceInvokeEntryBacktrace=%@", MDKDescribeTraceValue(firstDispatchSourceInvokeEntryBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceInvokeEntryFirstInterestingFrame=%@", MDKDescribeTraceValue(firstDispatchSourceInvokeEntryFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeExitEventCount=%@", MDKDescribeTraceValue(dispatchSourceInvokeExitCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeExitDeltaHistogram=%@", MDKDescribeTraceValue(dispatchSourceInvokeExitCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeExit120HzEquivalentCount=%@", MDKDescribeTraceValue(dispatchSourceInvokeExitCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceInvokeExitCadenceClassification=%@", MDKDescribeTraceValue(dispatchSourceInvokeExitCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceInvokeExitBacktrace=%@", MDKDescribeTraceValue(firstDispatchSourceInvokeExitBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceInvokeExitFirstInterestingFrame=%@", MDKDescribeTraceValue(firstDispatchSourceInvokeExitFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"dispatchSourceLatchAndCallInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"dispatchSourceLatchAndCallInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallInterposeSymbolAddress=%@", MDKDescribeTraceValue(snapshot[@"dispatchSourceLatchAndCallInterposeSymbolAddress"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallEntryEventCount=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallEntryCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallEntryDeltaHistogram=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallEntryCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallEntry120HzEquivalentCount=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallEntryCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallEntryCadenceClassification=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallEntryCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceLatchAndCallEntryBacktrace=%@", MDKDescribeTraceValue(firstDispatchSourceLatchAndCallEntryBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceLatchAndCallEntryFirstInterestingFrame=%@", MDKDescribeTraceValue(firstDispatchSourceLatchAndCallEntryFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallExitEventCount=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallExitCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallExitDeltaHistogram=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallExitCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallExit120HzEquivalentCount=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallExitCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceLatchAndCallExitCadenceClassification=%@", MDKDescribeTraceValue(dispatchSourceLatchAndCallExitCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceLatchAndCallExitBacktrace=%@", MDKDescribeTraceValue(firstDispatchSourceLatchAndCallExitBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchSourceLatchAndCallExitFirstInterestingFrame=%@", MDKDescribeTraceValue(firstDispatchSourceLatchAndCallExitFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"dispatchClientCalloutInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"dispatchClientCalloutInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutInterposeSymbolAddress=%@", MDKDescribeTraceValue(snapshot[@"dispatchClientCalloutInterposeSymbolAddress"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverEntryEventCount=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverEntryCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverEntryDeltaHistogram=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverEntryCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverEntry120HzEquivalentCount=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverEntryCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverEntryCadenceClassification=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverEntryCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchClientCalloutRQReceiverEntryBacktrace=%@", MDKDescribeTraceValue(firstDispatchClientCalloutRQReceiverEntryBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchClientCalloutRQReceiverEntryFirstInterestingFrame=%@", MDKDescribeTraceValue(firstDispatchClientCalloutRQReceiverEntryFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverExitEventCount=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverExitCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverExitDeltaHistogram=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverExitCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverExit120HzEquivalentCount=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverExitCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchClientCalloutRQReceiverExitCadenceClassification=%@", MDKDescribeTraceValue(dispatchClientCalloutRQReceiverExitCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchClientCalloutRQReceiverExitBacktrace=%@", MDKDescribeTraceValue(firstDispatchClientCalloutRQReceiverExitBacktrace)]];
    [notes addObject:[NSString stringWithFormat:@"firstDispatchClientCalloutRQReceiverExitFirstInterestingFrame=%@", MDKDescribeTraceValue(firstDispatchClientCalloutRQReceiverExitFirstInterestingFrame)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockCallbackEventCount=%@", MDKDescribeTraceValue(videoQueueNestedBlockCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockCallbackDeltaCount=%@", MDKDescribeTraceValue(videoQueueNestedBlockCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockCallbackDeltaHistogram=%@", MDKDescribeTraceValue(videoQueueNestedBlockCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockCallback120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueNestedBlockCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockCallbackCadenceClassification=%@", MDKDescribeTraceValue(videoQueueNestedBlockCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedAttributedCallbackCount=%@", MDKDescribeTraceValue(@(videoQueueNestedAttributedCallbackCount))]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedUnattributedCallbackCount=%@", MDKDescribeTraceValue(@(videoQueueNestedUnattributedCallbackCount))]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedInsideWrapperSequenceCount=%@", MDKDescribeTraceValue(@(videoQueueNestedInsideWrapperSequenceCount))]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadPairCount=%@", MDKDescribeTraceValue(@(videoQueueWrapperToNestedLeadPairCount))]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadHistogram=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLeadHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLead120HzEquivalentCount)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadMinMilliseconds=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLeadMinMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadMaxMilliseconds=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLeadMaxMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadPairCount=%@", MDKDescribeTraceValue(@(videoQueueInvokeEntryToExitLeadPairCount))]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadHistogram=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLeadHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLead120HzEquivalentCount)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadMinMilliseconds=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLeadMinMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadMaxMilliseconds=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLeadMaxMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToNestedLeadHistogram=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToNestedLeadHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToNestedLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToNestedLead120HzEquivalentCount)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToNestedLeadMinMilliseconds=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToNestedLeadMinMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToNestedLeadMaxMilliseconds=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToNestedLeadMaxMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedToInvokeExitLeadPairCount=%@", MDKDescribeTraceValue(@(videoQueueNestedToInvokeExitPairCount))]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedToInvokeExitLeadHistogram=%@", MDKDescribeTraceValue(videoQueueNestedToInvokeExitLeadHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedToInvokeExitLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueNestedToInvokeExitLead120HzEquivalentCount)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedToInvokeExitLeadMinMilliseconds=%@", MDKDescribeTraceValue(videoQueueNestedToInvokeExitLeadMinMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedToInvokeExitLeadMaxMilliseconds=%@", MDKDescribeTraceValue(videoQueueNestedToInvokeExitLeadMaxMillisecondsNumber)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperPointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperPointer)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperMallocSize=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperMallocSize)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperCandidateBlockOffsets=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperCandidateBlockOffsets)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32Pointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32Pointer)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeObjectClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeObjectClassName)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeObjectDescription=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeObjectDescription)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6Pointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6Pointer)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6ObjectClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6ObjectClassName)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6ObjectDescription=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6ObjectDescription)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandle=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandle)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleFileType=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleFileType)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleMode=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleMode)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandlePath=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandlePath)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointer)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObjectClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObjectClassName)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0Symbol=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0Symbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueClassName)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueDescription=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueDescription)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTypeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTypeSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceMask=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceMask)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceData=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceData)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceCancelled=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceCancelled)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord7Pointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord7Pointer)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord7BlockInvokeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord7BlockInvokeSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInstalledOffset=%@", MDKDescribeTraceValue(videoQueueWrapperInstalledOffset)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperOriginalInvokeSymbol=%@", MDKDescribeTraceValue(videoQueueWrapperOriginalInvokeSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperOriginalInvokeImagePath=%@", MDKDescribeTraceValue(videoQueueWrapperOriginalInvokeImagePath)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperOriginalInvokeImageOffset=%@", MDKDescribeTraceValue(videoQueueWrapperOriginalInvokeImageOffset)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockOriginalInvokeSymbol=%@", MDKDescribeTraceValue(videoQueueNestedBlockOriginalInvokeSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockOriginalInvokeImagePath=%@", MDKDescribeTraceValue(videoQueueNestedBlockOriginalInvokeImagePath)]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockOriginalInvokeImageOffset=%@", MDKDescribeTraceValue(videoQueueNestedBlockOriginalInvokeImageOffset)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockInvokeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockInvokeSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockInvokeImageOffset=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockInvokeImageOffset)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlots=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlots)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32Pointer=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32Pointer)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerSymbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerImagePath)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeMallocSize=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeMallocSize)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0Symbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0Symbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1Symbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1Symbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1ImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1ImagePath)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath)]];
    [notes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockCaptureSlots=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockCaptureSlots)]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeDyldAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeDyldAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeSetHandlerSymbolAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeSetHandlerSymbolAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeDequeueSymbolAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeDequeueSymbolAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeUnsetHandlerSymbolAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeUnsetHandlerSymbolAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeScreenCaptureKitImagePresent=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeScreenCaptureKitImagePresent"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeCMCaptureImagePresent=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeCMCaptureImagePresent"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeInstalledImageCount=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeInstalledImageCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverSetHandlerEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverSetHandlerSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackDeltaCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackDeltaHistogram=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallback120HzEquivalentCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackCadenceClassification=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueDeltaCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueDeltaHistogram=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeue120HzEquivalentCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueCadenceClassification=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverUnsetHandlerEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverUnsetHandlerSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoQueueWrapperInstalledCount=%@", MDKDescribeTraceValue(videoQueueWrapperInstallSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueCallbackTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockCallbackTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockCallbackTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockPrecedingEventKind=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockPrecedingEventKind)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockPrecedingEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockPrecedingEventLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockWrapperSequenceID=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockWrapperSequenceID)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockWrapperDepth=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockWrapperDepth)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockInsideWrapperOriginalInvoke=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockInsideWrapperOriginalInvoke)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstSuccessfulVideoQueueNestedBlockRescanReason=%@", MDKDescribeTraceValue(firstSuccessfulVideoQueueNestedBlockRescanReason)]];
    [notes addObject:[NSString stringWithFormat:@"firstSuccessfulVideoQueueNestedBlockRescanTimestampNanos=%@", MDKDescribeTraceValue(firstSuccessfulVideoQueueNestedBlockRescanTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstSuccessfulVideoQueueNestedBlockRescanLeadMilliseconds=%@", MDKDescribeTraceValue(firstSuccessfulVideoQueueNestedBlockRescanLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackSurfacePointer=%@", MDKDescribeTraceValue(firstVideoQueueCallbackSurfacePointer)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventIndex=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventIndexNumber)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventKind=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventKind)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventSelector=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventSelector)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventSymbol=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventStreamState=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventStreamState)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventIndex=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventIndexNumber)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventKind=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventKind)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventSelector=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventSelector)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventSymbol=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventSymbol)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventTimestampNanos)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCrossQueueSetupTailMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueCrossQueueSetupTailMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackInterveningEventKinds=%@", MDKDescribeTraceValue(firstVideoQueueCallbackInterveningEventKinds)]];
    [notes addObject:[NSString stringWithFormat:@"lastCollectStreamDataEnterBeforeVideoQueueCallback=%@", MDKDescribeTraceValue(lastCollectStreamDataEnterBeforeVideoQueueCallback)]];
    [notes addObject:[NSString stringWithFormat:@"lastCollectStreamDataEnterLeadMilliseconds=%@", MDKDescribeTraceValue(lastCollectStreamDataEnterLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"lastCollectStreamDataExitBeforeVideoQueueCallback=%@", MDKDescribeTraceValue(lastCollectStreamDataExitBeforeVideoQueueCallback)]];
    [notes addObject:[NSString stringWithFormat:@"lastCollectStreamDataExitLeadMilliseconds=%@", MDKDescribeTraceValue(lastCollectStreamDataExitLeadMilliseconds)]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionPollCount=%@", MDKDescribeTraceValue(snapshot[@"videoSharedRegionPollCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionMappedSize=%@", MDKDescribeTraceValue(snapshot[@"videoSharedRegionMappedSize"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionQueueOffset=%@", MDKDescribeTraceValue(snapshot[@"videoSharedRegionQueueOffset"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionInspectionSize=%@", MDKDescribeTraceValue(snapshot[@"videoSharedRegionInspectionSize"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionChangeEventCount=%@", MDKDescribeTraceValue(videoSharedRegionCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionDeltaCount=%@", MDKDescribeTraceValue(videoSharedRegionCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionDeltaHistogram=%@", MDKDescribeTraceValue(videoSharedRegionCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(videoSharedRegionCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionCadenceClassification=%@", MDKDescribeTraceValue(videoSharedRegionCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"videoSharedRegionChangedOffsetHistogram=%@", MDKDescribeTraceValue(snapshot[@"videoSharedRegionChangedOffsetHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDPollCount=%@", MDKDescribeTraceValue(snapshot[@"videoRemoteQueueRecvFDPollCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDSignalEventCount=%@", MDKDescribeTraceValue(videoRecvFDCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDDeltaCount=%@", MDKDescribeTraceValue(videoRecvFDCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDDeltaHistogram=%@", MDKDescribeTraceValue(videoRecvFDCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(videoRecvFDCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDCadenceClassification=%@", MDKDescribeTraceValue(videoRecvFDCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDAvailableBytesHistogram=%@", MDKDescribeTraceValue(snapshot[@"videoRemoteQueueRecvFDAvailableBytesHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"videoRemoteQueueRecvFDAvailableBytesMax=%@", MDKDescribeTraceValue(snapshot[@"videoRemoteQueueRecvFDAvailableBytesMax"])]];
    [notes addObject:[NSString stringWithFormat:@"fifoWriteInterposeEventCount=%@", MDKDescribeTraceValue(snapshot[@"fifoWriteInterposeEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"fifoWriteEventCount=%@", MDKDescribeTraceValue(snapshot[@"fifoWriteEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"fifoWriteNoCancelEventCount=%@", MDKDescribeTraceValue(snapshot[@"fifoWriteNoCancelEventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"fifoWriteDeltaCount=%@", MDKDescribeTraceValue(fifoWriteCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"fifoWriteDeltaHistogram=%@", MDKDescribeTraceValue(fifoWriteCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"fifoWrite120HzEquivalentCount=%@", MDKDescribeTraceValue(fifoWriteCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"fifoWriteCadenceClassification=%@", MDKDescribeTraceValue(fifoWriteCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"pipeInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"pipeInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"pipeInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"pipeInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"pipeInterposeInstalledImageCount=%@", MDKDescribeTraceValue(snapshot[@"pipeInterposeInstalledImageCount"])]];
    [notes addObject:[NSString stringWithFormat:@"pipeCreateEventCount=%@", MDKDescribeTraceValue(pipeCreateCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"pipeCreateDeltaHistogram=%@", MDKDescribeTraceValue(pipeCreateCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"pipeCreateCadenceClassification=%@", MDKDescribeTraceValue(pipeCreateCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceMachInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"ioSurfaceMachInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceMachInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"ioSurfaceMachInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceMachInterposeInstalledImageCount=%@", MDKDescribeTraceValue(snapshot[@"ioSurfaceMachInterposeInstalledImageCount"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceLookupFromMachPortEventCount=%@", MDKDescribeTraceValue(ioSurfaceLookupCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceLookupFromMachPortDeltaHistogram=%@", MDKDescribeTraceValue(ioSurfaceLookupCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceLookupFromMachPortCadenceClassification=%@", MDKDescribeTraceValue(ioSurfaceLookupCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceCreateMachPortEventCount=%@", MDKDescribeTraceValue(ioSurfaceCreateCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceCreateMachPortDeltaHistogram=%@", MDKDescribeTraceValue(ioSurfaceCreateCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"ioSurfaceCreateMachPortCadenceClassification=%@", MDKDescribeTraceValue(ioSurfaceCreateCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"xpcPipeInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"xpcPipeInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeInterposeInstalledImageCount=%@", MDKDescribeTraceValue(snapshot[@"xpcPipeInterposeInstalledImageCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeInterposeInstalledSymbolCount=%@", MDKDescribeTraceValue(snapshot[@"xpcPipeInterposeInstalledSymbolCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeCreateEventCount=%@", MDKDescribeTraceValue(xpcPipeCreateCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeCreateDeltaHistogram=%@", MDKDescribeTraceValue(xpcPipeCreateCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeCreateCadenceClassification=%@", MDKDescribeTraceValue(xpcPipeCreateCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeSimpleRoutineEventCount=%@", MDKDescribeTraceValue(xpcPipeSimpleRoutineCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeSimpleRoutineDeltaHistogram=%@", MDKDescribeTraceValue(xpcPipeSimpleRoutineCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcPipeSimpleRoutineCadenceClassification=%@", MDKDescribeTraceValue(xpcPipeSimpleRoutineCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"xpcFDInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"xpcFDInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDInterposeInstalledImageCount=%@", MDKDescribeTraceValue(snapshot[@"xpcFDInterposeInstalledImageCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDInterposeInstalledSymbolCount=%@", MDKDescribeTraceValue(snapshot[@"xpcFDInterposeInstalledSymbolCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDDupEventCount=%@", MDKDescribeTraceValue(xpcFDDupCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDDupDeltaCount=%@", MDKDescribeTraceValue(xpcFDDupCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDDupDeltaHistogram=%@", MDKDescribeTraceValue(xpcFDDupCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcFDDupCadenceClassification=%@", MDKDescribeTraceValue(xpcFDDupCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcDictionaryDupFDEventCount=%@", MDKDescribeTraceValue(xpcDictionaryDupFDCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcDictionaryDupFDDeltaCount=%@", MDKDescribeTraceValue(xpcDictionaryDupFDCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcDictionaryDupFDDeltaHistogram=%@", MDKDescribeTraceValue(xpcDictionaryDupFDCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"xpcDictionaryDupFDCadenceClassification=%@", MDKDescribeTraceValue(xpcDictionaryDupFDCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceHandlerInstalledCount=%@", MDKDescribeTraceValue(dispatchSourceHandlerInstallSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceHandlerCallbackEventCount=%@", MDKDescribeTraceValue(dispatchSourceHandlerCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceHandlerCallbackDeltaCount=%@", MDKDescribeTraceValue(dispatchSourceHandlerCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceHandlerCallbackDeltaHistogram=%@", MDKDescribeTraceValue(dispatchSourceHandlerCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceHandlerCallback120HzEquivalentCount=%@", MDKDescribeTraceValue(dispatchSourceHandlerCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"dispatchSourceHandlerCallbackCadenceClassification=%@", MDKDescribeTraceValue(dispatchSourceHandlerCadenceSummary[@"cadenceClassification"])]];
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
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperPointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperPointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperMallocSize=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperMallocSize)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperCandidateBlockOffsets=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperCandidateBlockOffsets)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32Pointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32Pointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeObjectClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeObjectClassName)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeObjectDescription=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeObjectDescription)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6Pointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6Pointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6ObjectClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6ObjectClassName)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6ObjectDescription=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6ObjectDescription)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandle=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandle)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleFileType=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleFileType)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleMode=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandleMode)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandlePath=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceHandlePath)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObjectClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeObjectClassName)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0Symbol=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceContextPointeeWord0Symbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueClassName=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueClassName)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueDescription=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTargetQueueDescription)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTypeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceTypeSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceMask=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceMask)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceData=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceData)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceCancelled=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord6DispatchSourceCancelled)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord7Pointer=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord7Pointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueueWrapperSlot32PointeeWord7BlockInvokeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueueWrapperSlot32PointeeWord7BlockInvokeSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperCallbackEventCount=%@", MDKDescribeTraceValue(videoQueueWrapperCadenceSummary[@"eventCount"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeEntryEventCount=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeEntryCadenceSummary[@"eventCount"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeEntryCadenceClassification=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeEntryCadenceSummary[@"cadenceClassification"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueWrapperInvokeEntryFirstInterestingFrame=%@", MDKDescribeTraceValue(firstVideoQueueWrapperInvokeEntryFirstInterestingFrame)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeExitEventCount=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeExitCadenceSummary[@"eventCount"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperInvokeExitCadenceClassification=%@", MDKDescribeTraceValue(videoQueueWrapperInvokeExitCadenceSummary[@"cadenceClassification"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueWrapperInvokeExitFirstInterestingFrame=%@", MDKDescribeTraceValue(firstVideoQueueWrapperInvokeExitFirstInterestingFrame)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"rqReceiverSetSourceInterposeAttempted"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"rqReceiverSetSourceInterposeInstalled"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInterposeSymbolAddress=%@", MDKDescribeTraceValue(snapshot[@"rqReceiverSetSourceInterposeSymbolAddress"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeEntryEventCount=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeEntryCadenceSummary[@"eventCount"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeEntryCadenceClassification=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeEntryCadenceSummary[@"cadenceClassification"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstRQReceiverSetSourceInvokeEntryFirstInterestingFrame=%@", MDKDescribeTraceValue(firstRQReceiverSetSourceInvokeEntryFirstInterestingFrame)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeExitEventCount=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeExitCadenceSummary[@"eventCount"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"rqReceiverSetSourceInvokeExitCadenceClassification=%@", MDKDescribeTraceValue(rqReceiverSetSourceInvokeExitCadenceSummary[@"cadenceClassification"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstRQReceiverSetSourceInvokeExitFirstInterestingFrame=%@", MDKDescribeTraceValue(firstRQReceiverSetSourceInvokeExitFirstInterestingFrame)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockCallbackEventCount=%@", MDKDescribeTraceValue(videoQueueNestedBlockCadenceSummary[@"eventCount"])]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedAttributedCallbackCount=%@", MDKDescribeTraceValue(@(videoQueueNestedAttributedCallbackCount))]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedUnattributedCallbackCount=%@", MDKDescribeTraceValue(@(videoQueueNestedUnattributedCallbackCount))]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedInsideWrapperSequenceCount=%@", MDKDescribeTraceValue(@(videoQueueNestedInsideWrapperSequenceCount))]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadPairCount=%@", MDKDescribeTraceValue(@(videoQueueWrapperToNestedLeadPairCount))]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadHistogram=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLeadHistogram)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLead120HzEquivalentCount)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadMinMilliseconds=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLeadMinMillisecondsNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperToNestedLeadMaxMilliseconds=%@", MDKDescribeTraceValue(videoQueueWrapperToNestedLeadMaxMillisecondsNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadPairCount=%@", MDKDescribeTraceValue(@(videoQueueInvokeEntryToExitLeadPairCount))]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadHistogram=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLeadHistogram)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLead120HzEquivalentCount)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadMinMilliseconds=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLeadMinMillisecondsNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToExitLeadMaxMilliseconds=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToExitLeadMaxMillisecondsNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToNestedLeadHistogram=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToNestedLeadHistogram)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueInvokeEntryToNestedLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueInvokeEntryToNestedLead120HzEquivalentCount)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedToInvokeExitLeadHistogram=%@", MDKDescribeTraceValue(videoQueueNestedToInvokeExitLeadHistogram)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedToInvokeExitLead120HzEquivalentCount=%@", MDKDescribeTraceValue(videoQueueNestedToInvokeExitLead120HzEquivalentCount)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperInstalledOffset=%@", MDKDescribeTraceValue(videoQueueWrapperInstalledOffset)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperOriginalInvokeSymbol=%@", MDKDescribeTraceValue(videoQueueWrapperOriginalInvokeSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperOriginalInvokeImagePath=%@", MDKDescribeTraceValue(videoQueueWrapperOriginalInvokeImagePath)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueWrapperOriginalInvokeImageOffset=%@", MDKDescribeTraceValue(videoQueueWrapperOriginalInvokeImageOffset)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockOriginalInvokeSymbol=%@", MDKDescribeTraceValue(videoQueueNestedBlockOriginalInvokeSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockOriginalInvokeImagePath=%@", MDKDescribeTraceValue(videoQueueNestedBlockOriginalInvokeImagePath)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoQueueNestedBlockOriginalInvokeImageOffset=%@", MDKDescribeTraceValue(videoQueueNestedBlockOriginalInvokeImageOffset)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockInvokeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockInvokeSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockInvokeImageOffset=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockInvokeImageOffset)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlots=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlots)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32Pointer=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32Pointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerSymbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32CodePointerImagePath)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeMallocSize=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeMallocSize)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0Symbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0Symbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord0ImagePath)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1Symbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1Symbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1ImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeWord1ImagePath)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeSymbol=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockInvokeImagePath)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockCaptureSlots=%@", MDKDescribeTraceValue(videoReceiveQueuePrimaryBlockCaptureSlot32PointeeBlockCaptureSlots)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueCallbackTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockCallbackTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockCallbackTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstSuccessfulVideoQueueNestedBlockRescanReason=%@", MDKDescribeTraceValue(firstSuccessfulVideoQueueNestedBlockRescanReason)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstSuccessfulVideoQueueNestedBlockRescanTimestampNanos=%@", MDKDescribeTraceValue(firstSuccessfulVideoQueueNestedBlockRescanTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstSuccessfulVideoQueueNestedBlockRescanLeadMilliseconds=%@", MDKDescribeTraceValue(firstSuccessfulVideoQueueNestedBlockRescanLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackSurfacePointer=%@", MDKDescribeTraceValue(firstVideoQueueCallbackSurfacePointer)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventIndex=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventIndexNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventKind=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventKind)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventSelector=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventSelector)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventSymbol=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackPrecedingEventStreamState=%@", MDKDescribeTraceValue(firstVideoQueueCallbackPrecedingEventStreamState)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockPrecedingEventKind=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockPrecedingEventKind)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockPrecedingEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockPrecedingEventLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockWrapperSequenceID=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockWrapperSequenceID)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockWrapperDepth=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockWrapperDepth)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueNestedBlockInsideWrapperOriginalInvoke=%@", MDKDescribeTraceValue(firstVideoQueueNestedBlockInsideWrapperOriginalInvoke)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventIndex=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventIndexNumber)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventKind=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventKind)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventSelector=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventSelector)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventSymbol=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventSymbol)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventTimestampNanos=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventTimestampNanos)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackLastSetupEventLeadMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueCallbackLastSetupEventLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCrossQueueSetupTailMilliseconds=%@", MDKDescribeTraceValue(firstVideoQueueCrossQueueSetupTailMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"firstVideoQueueCallbackInterveningEventKinds=%@", MDKDescribeTraceValue(firstVideoQueueCallbackInterveningEventKinds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"lastCollectStreamDataEnterBeforeVideoQueueCallback=%@", MDKDescribeTraceValue(lastCollectStreamDataEnterBeforeVideoQueueCallback)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"lastCollectStreamDataEnterLeadMilliseconds=%@", MDKDescribeTraceValue(lastCollectStreamDataEnterLeadMilliseconds)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"lastCollectStreamDataExitBeforeVideoQueueCallback=%@", MDKDescribeTraceValue(lastCollectStreamDataExitBeforeVideoQueueCallback)]];
    [deliveryComparisonNotes addObject:[NSString stringWithFormat:@"lastCollectStreamDataExitLeadMilliseconds=%@", MDKDescribeTraceValue(lastCollectStreamDataExitLeadMilliseconds)]];
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
        @"first-video-queue-callback-predecessor",
        firstVideoQueueCallbackPrecedingEventSelector,
        firstVideoQueueCallbackPrecedingEventSymbol,
        nil,
        @([firstVideoQueueCallbackTimestampNanos isKindOfClass:[NSNumber class]]),
        deliveryComparisonNotes
    )];
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
        @"videoReceiveQueueWrapper": videoReceiveQueueWrapper,
        @"selectors": [[selectors allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"symbols": [[symbols allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"steps": steps,
        @"notes": notes,
    } mutableCopy];

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
        MDKActiveSCKAllowVideoQueueWrapperProbe = YES;
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

    @synchronized(MDKActiveSCKTraceLock) {
        MDKActiveSCKTraceState = nil;
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
    NSDictionary<NSString *, id> *frameSenderCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"frame-sender-client-send-xcp-sample-buffer",
            @"frame-sender-service-send-frame",
            @"frame-sender-service-new-sample-buffer",
        ]]
    );
    NSDictionary<NSString *, NSNumber *> *frameSenderKindHistogram = MDKCopyTraceEventKindHistogram(
        traceEvents,
        [NSSet setWithArray:@[
            @"frame-sender-client-send-xcp-sample-buffer",
            @"frame-sender-service-send-frame",
            @"frame-sender-service-new-sample-buffer",
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
            @"bw-remote-queue-init",
            @"bw-remote-queue-render",
            @"bw-remote-queue-drop",
            @"bw-remote-queue-register-surfaces",
            @"bw-remote-queue-set-discards-late-sample-buffers",
            @"bw-remote-queue-set-frame-sender-support-enabled",
            @"bw-remote-queue-set-video-hdr-image-statistics-enabled",
            @"bw-remote-queue-set-client-video-retained-buffer-count",
            @"bw-image-queue-sink-render",
            @"bw-image-queue-sink-register-surfaces",
            @"bw-node-connection-consume-message",
            @"bw-node-handle-message",
            @"fig-remote-queue-set-sink",
        ]]
    );
    NSDictionary<NSString *, NSNumber *> *remoteQueueSinkKindHistogram = MDKCopyTraceEventKindHistogram(
        traceEvents,
        [NSSet setWithArray:@[
            @"bw-remote-queue-init",
            @"bw-remote-queue-render",
            @"bw-remote-queue-drop",
            @"bw-remote-queue-register-surfaces",
            @"bw-remote-queue-set-discards-late-sample-buffers",
            @"bw-remote-queue-set-frame-sender-support-enabled",
            @"bw-remote-queue-set-video-hdr-image-statistics-enabled",
            @"bw-remote-queue-set-client-video-retained-buffer-count",
            @"bw-image-queue-sink-render",
            @"bw-image-queue-sink-register-surfaces",
            @"bw-node-connection-consume-message",
            @"bw-node-handle-message",
            @"fig-remote-queue-set-sink",
        ]]
    );
    NSDictionary<NSString *, id> *surfaceTransportHandleMessageCadenceSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"iosurface-remote-handle-message",
        ]]
    );
    NSDictionary<NSString *, id> *figRemoteQueueReceiverSetHandlerSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-set-handler",
        ]]
    );
    NSDictionary<NSString *, id> *figRemoteQueueReceiverHandlerCallbackSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-handler-callback",
        ]]
    );
    NSDictionary<NSString *, id> *figRemoteQueueReceiverDequeueSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-dequeue",
        ]]
    );
    NSDictionary<NSString *, id> *figRemoteQueueReceiverUnsetHandlerSummary = MDKCopyTraceEventCadenceSummary(
        traceEvents,
        [NSSet setWithArray:@[
            @"fig-remote-queue-receiver-unset-handler",
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
    [notes addObject:[NSString stringWithFormat:@"frameSenderEventCount=%@", MDKDescribeTraceValue(frameSenderCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"frameSenderDeltaCount=%@", MDKDescribeTraceValue(frameSenderCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"frameSenderDeltaHistogram=%@", MDKDescribeTraceValue(frameSenderCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"frameSenderDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(frameSenderCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"frameSenderCadenceClassification=%@", MDKDescribeTraceValue(frameSenderCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"frameSenderKindHistogram=%@", MDKDescribeTraceValue(frameSenderKindHistogram)]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamEventCount=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamDeltaCount=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamDeltaHistogram=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"contentStreamCadenceClassification=%@", MDKDescribeTraceValue(contentStreamCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageEventCount=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageDeltaCount=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageDeltaHistogram=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"surfaceTransportHandleMessageCadenceClassification=%@", MDKDescribeTraceValue(surfaceTransportHandleMessageCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeAttempted=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeAttempted"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeDyldAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeDyldAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeSetHandlerSymbolAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeSetHandlerSymbolAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeDequeueSymbolAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeDequeueSymbolAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeUnsetHandlerSymbolAvailable=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeUnsetHandlerSymbolAvailable"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeScreenCaptureKitImagePresent=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeScreenCaptureKitImagePresent"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeCMCaptureImagePresent=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeCMCaptureImagePresent"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeInstalledImageCount=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeInstalledImageCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverInterposeInstalled=%@", MDKDescribeTraceValue(snapshot[@"figRemoteQueueReceiverInterposeInstalled"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverSetHandlerEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverSetHandlerSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackDeltaCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackDeltaHistogram=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverHandlerCallbackCadenceClassification=%@", MDKDescribeTraceValue(figRemoteQueueReceiverHandlerCallbackSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueDeltaCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueDeltaHistogram=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverDequeueCadenceClassification=%@", MDKDescribeTraceValue(figRemoteQueueReceiverDequeueSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"figRemoteQueueReceiverUnsetHandlerEventCount=%@", MDKDescribeTraceValue(figRemoteQueueReceiverUnsetHandlerSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkEventCount=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"eventCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkDeltaCount=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"deltaCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkDeltaHistogram=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"deltaHistogram"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkDelta120HzEquivalentCount=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"delta120HzEquivalentCount"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkCadenceClassification=%@", MDKDescribeTraceValue(remoteQueueSinkCadenceSummary[@"cadenceClassification"])]];
    [notes addObject:[NSString stringWithFormat:@"remoteQueueSinkKindHistogram=%@", MDKDescribeTraceValue(remoteQueueSinkKindHistogram)]];
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
        @"BWImageQueueSinkNode",
        @"BWNode",
        @"BWNodeConnection",
        @"FigCaptureRemoteQueueSinkPipeline",
        @"FigRemoteQueueReceiver",
        @"RPIOSurfaceObject",
        @"IOSurfaceRemoteRemoteClient",
        @"CMCaptureFrameReceiver",
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

    NSMutableOrderedSet<NSString *> *runtimeClassNames = [NSMutableOrderedSet orderedSetWithArray:classNames];
    [runtimeClassNames addObjectsFromArray:MDKDynamicRuntimeClassNamesMatchingKeywords()];

    NSMutableArray<NSDictionary<NSString *, id> *> *classes = [NSMutableArray arrayWithCapacity:runtimeClassNames.count];
    for (NSString *className in runtimeClassNames) {
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
            @"Lists the presence of guessed private queue symbols so host-only experiments can pick likely next entry points.",
            [NSString stringWithFormat:@"Dynamic runtime scan added %lu class name(s) beyond the hard-coded ScreenCaptureKit inventory.", (unsigned long)(runtimeClassNames.count - classNames.count)]
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
