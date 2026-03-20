#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *TypeEncodingForMethod(Method method) {
  const char *encoding = method_getTypeEncoding(method);
  return encoding ? [NSString stringWithUTF8String:encoding] : @"<null>";
}

static void DumpClassInfo(Class cls) {
  if (!cls) {
    return;
  }
  printf("\n=== %s ===\n", class_getName(cls));

  unsigned int ivarCount = 0;
  Ivar *ivars = class_copyIvarList(cls, &ivarCount);
  printf("ivars (%u):\n", ivarCount);
  for (unsigned int i = 0; i < ivarCount; ++i) {
    const char *name = ivar_getName(ivars[i]);
    const char *type = ivar_getTypeEncoding(ivars[i]);
    printf("  %s : %s\n", name ?: "<null>", type ?: "<null>");
  }
  free(ivars);

  unsigned int propCount = 0;
  objc_property_t *props = class_copyPropertyList(cls, &propCount);
  printf("properties (%u):\n", propCount);
  for (unsigned int i = 0; i < propCount; ++i) {
    const char *name = property_getName(props[i]);
    const char *attrs = property_getAttributes(props[i]);
    printf("  %s [%s]\n", name ?: "<null>", attrs ?: "<null>");
  }
  free(props);

  unsigned int classMethodCount = 0;
  Method *classMethods = class_copyMethodList(object_getClass((id)cls), &classMethodCount);
  printf("class methods (%u):\n", classMethodCount);
  for (unsigned int i = 0; i < classMethodCount; ++i) {
    SEL sel = method_getName(classMethods[i]);
    printf("  +[%s %s]  %s\n",
           class_getName(cls),
           sel_getName(sel),
           TypeEncodingForMethod(classMethods[i]).UTF8String);
  }
  free(classMethods);

  unsigned int instanceMethodCount = 0;
  Method *instanceMethods = class_copyMethodList(cls, &instanceMethodCount);
  printf("instance methods (%u):\n", instanceMethodCount);
  for (unsigned int i = 0; i < instanceMethodCount; ++i) {
    SEL sel = method_getName(instanceMethods[i]);
    printf("  -[%s %s]  %s\n",
           class_getName(cls),
           sel_getName(sel),
           TypeEncodingForMethod(instanceMethods[i]).UTF8String);
  }
  free(instanceMethods);
}

static void LoadImage(NSString *path) {
  void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  printf("dlopen(%s) -> %s\n", path.fileSystemRepresentation, handle ? "ok" : (dlerror() ?: "failed"));
}

int main(void) {
  @autoreleasepool {
    NSArray<NSString *> *paths = @[
      @"/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle/Contents/MacOS/ScreensharingAgent",
      @"/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/MacOS/AppleVNCServer",
      @"/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd"
    ];
    for (NSString *path in paths) {
      LoadImage(path);
    }

    NSArray<NSString *> *targets = @[
      @"SSAgentVirtualDisplay",
      @"SSUDPSender",
      @"SSAgentScreenCapture",
      @"ScreensharingAgent",
      @"AVCScreenCaptureAttributes",
      @"AVCScreenCapture",
      @"AVCVideoStream",
      @"AVCAudioStream",
      @"AVCMediaStreamConfig",
      @"AVCVideoStreamConfig",
      @"AVCAudioStreamConfig",
      @"AVCMediaStreamNegotiator",
      @"VCScreenShare"
    ];
    for (NSString *name in targets) {
      DumpClassInfo(NSClassFromString(name));
    }

    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage("/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle/Contents/MacOS/ScreensharingAgent", &count);
    printf("\n=== image classes: ScreensharingAgent (%u) ===\n", count);
    for (unsigned int i = 0; i < count; ++i) {
      printf("%s\n", names[i]);
    }
    free(names);
  }
  return 0;
}
