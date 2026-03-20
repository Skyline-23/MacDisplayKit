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

static void DumpProtocolInfo(Protocol *protocol) {
  if (!protocol) {
    return;
  }

  printf("\n=== @protocol %s ===\n", protocol_getName(protocol));

  unsigned int propCount = 0;
  objc_property_t *props = protocol_copyPropertyList(protocol, &propCount);
  printf("properties (%u):\n", propCount);
  for (unsigned int i = 0; i < propCount; ++i) {
    const char *name = property_getName(props[i]);
    const char *attrs = property_getAttributes(props[i]);
    printf("  %s [%s]\n", name ?: "<null>", attrs ?: "<null>");
  }
  free(props);

  for (int required = 1; required >= 0; --required) {
    for (int instance = 1; instance >= 0; --instance) {
      unsigned int methodCount = 0;
      struct objc_method_description *methods =
        protocol_copyMethodDescriptionList(protocol, required, instance, &methodCount);
      printf("%s %s methods (%u):\n",
             required ? "required" : "optional",
             instance ? "instance" : "class",
             methodCount);
      for (unsigned int i = 0; i < methodCount; ++i) {
        printf("  %s  %s\n",
               sel_getName(methods[i].name),
               methods[i].types ?: "<null>");
      }
      free(methods);
    }
  }
}

static void LoadFramework(NSString *path) {
  void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  printf("dlopen(%s) -> %s\n", path.fileSystemRepresentation, handle ? "ok" : (dlerror() ?: "failed"));
}

int main(int argc, const char * argv[]) {
  @autoreleasepool {
    NSArray<NSString *> *frameworkPaths = @[
      @"/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/ScreenSharing",
      @"/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/Frameworks/ScreenSharingUI.framework/Versions/A/ScreenSharingUI"
    ];

    for (NSString *path in frameworkPaths) {
      LoadFramework(path);
    }

    NSArray<NSString *> *targets = @[
      @"SSSession",
      @"SSDisplayConfiguration",
      @"SessionControllerManager",
      @"SSSessionView",
      @"SSSessionProxy",
      @"SSVirtualDisplayLocalDisplayMonitor",
      @"SSCompatibilityModeLocalDisplayMonitor",
      @"SSRemoteMacsLocalDisplayMonitor",
      @"SSDisplayDetailsConcretePrimitives",
      @"ScreenSharingUI.DisplayConfigurationViewModel",
      @"ScreenSharingUI.ScreenSharingUIFactoryInternal",
      @"ScreenSharingUIFactory",
      @"CMCaptureLocalSessionController",
      @"AVCMediaStreamNegotiatorSettingsRemoteDesktopScreenSharing",
      @"AVCMediaStreamNegotiatorSettingsNearbyScreenSharing",
      @"AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing",
      @"SSCAMetalLayerSession"
    ];

    for (NSString *name in targets) {
      DumpClassInfo(NSClassFromString(name));
    }

    NSArray<NSString *> *protocolTargets = @[
      @"SSDisplayConfigurationDelegate",
      @"SSLocalDisplayMonitoring",
      @"SSDisplayDetailsPrimitives",
      @"SSSessionDelegate"
    ];
    for (NSString *name in protocolTargets) {
      DumpProtocolInfo(objc_getProtocol(name.UTF8String));
    }

    int classCount = objc_getClassList(NULL, 0);
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);
    NSMutableArray<NSString *> *interesting = [NSMutableArray array];
    for (int i = 0; i < classCount; ++i) {
      NSString *name = NSStringFromClass(classes[i]);
      if ([name hasPrefix:@"SS"] ||
          [name containsString:@"ScreenSharing"] ||
          [name containsString:@"VirtualDisplay"] ||
          [name containsString:@"SessionController"]) {
        [interesting addObject:name];
      }
    }
    free(classes);

    [interesting sortUsingSelector:@selector(compare:)];
    printf("\n=== matching classes (%lu) ===\n", (unsigned long)interesting.count);
    for (NSString *name in interesting) {
      printf("%s\n", name.UTF8String);
    }
  }
  return 0;
}
