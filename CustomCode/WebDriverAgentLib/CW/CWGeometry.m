#import "CWGeometry.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <math.h>
#import <sys/sysctl.h>

#import <WebDriverAgentLib/XCUIDevice+FBHelpers.h>

#import "CWScreenshot.h"

static CGSize CWMeasuredPixelSize;

static void CWGeometryOnMain(dispatch_block_t block)
{
  if (NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_sync(dispatch_get_main_queue(), block);
}

static CGSize CWNativeBoundsSize(void)
{
  __block CGSize size = CGSizeZero;
  CWGeometryOnMain(^{
    size = UIScreen.mainScreen.nativeBounds.size;
  });
  return size;
}

static CGSize CWScreenBoundsSize(void)
{
  __block CGSize size = CGSizeZero;
  CWGeometryOnMain(^{
    size = UIScreen.mainScreen.bounds.size;
  });
  return size;
}

static CGFloat CWNativeScale(void)
{
  __block CGFloat value = 0;
  CWGeometryOnMain(^{
    value = UIScreen.mainScreen.nativeScale;
    if (value <= 0) {
      value = UIScreen.mainScreen.scale;
    }
    if (value <= 0) {
      value = 1.0;
    }
  });
  return value;
}

@implementation CWGeometry

+ (CGSize)pixelSize
{
  @synchronized (self) {
    if (CWMeasuredPixelSize.width >= 1 && CWMeasuredPixelSize.height >= 1) {
      return CWMeasuredPixelSize;
    }
  }
  CGSize shot = [CWScreenshot lastPixelSize];
  if (shot.width >= 1 && shot.height >= 1) {
    @synchronized (self) {
      CWMeasuredPixelSize = shot;
    }
    return shot;
  }
  CGSize measured = [self measurePixelSize];
  if (measured.width >= 1 && measured.height >= 1) {
    return measured;
  }
  CGSize native = CWNativeBoundsSize();
  if (native.width >= 1 && native.height >= 1) {
    return native;
  }
  CGSize bounds = CWScreenBoundsSize();
  CGFloat nativeScale = CWNativeScale();
  return CGSizeMake(round(bounds.width * nativeScale), round(bounds.height * nativeScale));
}

+ (CGSize)measurePixelSize
{
  __block NSData *data = nil;
  CWGeometryOnMain(^{
    NSError *error = nil;
    data = [XCUIDevice.sharedDevice fb_screenshotWithError:&error];
  });
  if (data.length == 0) {
    return CGSizeZero;
  }
  CGSize size = [CWScreenshot imageSizeForData:data];
  if (size.width >= 1 && size.height >= 1) {
    @synchronized (self) {
      CWMeasuredPixelSize = size;
    }
  }
  return size;
}

+ (BOOL)pixelSizeIsMeasured
{
  @synchronized (self) {
    return CWMeasuredPixelSize.width >= 1 && CWMeasuredPixelSize.height >= 1;
  }
}

+ (CGFloat)scale
{
  return CWNativeScale();
}

+ (CGSize)pointSize
{
  CGSize pixel = [self pixelSize];
  CGFloat scale = [self scale];
  if (scale <= 0) {
    scale = 1.0;
  }
  return CGSizeMake(round(pixel.width / scale), round(pixel.height / scale));
}

+ (UIWindowScene *)activeWindowScene
{
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:UIWindowScene.class]) {
      return (UIWindowScene *)scene;
    }
  }
  return nil;
}

+ (UIWindow *)keyWindow
{
  UIWindowScene *scene = [self activeWindowScene];
  for (UIWindow *window in scene.windows) {
    if (window.isKeyWindow) {
      return window;
    }
  }
  return scene.windows.firstObject;
}

+ (BOOL)readSafeAreaTop:(CGFloat *)top bottom:(CGFloat *)bottom
{
  __block BOOL found = NO;
  __block CGFloat topValue = 0;
  __block CGFloat bottomValue = 0;
  CWGeometryOnMain(^{
    UIWindow *window = [self keyWindow];
    if (nil == window) {
      return;
    }
    found = YES;
    topValue = window.safeAreaInsets.top;
    bottomValue = window.safeAreaInsets.bottom;
  });
  if (found) {
    *top = topValue;
    *bottom = bottomValue;
  }
  return found;
}

+ (BOOL)isPortrait
{
  __block BOOL portrait = YES;
  CWGeometryOnMain(^{
    UIWindowScene *scene = [self activeWindowScene];
    UIInterfaceOrientation orientation = scene.interfaceOrientation;
    if (orientation != UIInterfaceOrientationUnknown) {
      portrait = UIInterfaceOrientationIsPortrait(orientation);
      return;
    }
    CGSize point = [self pointSize];
    portrait = point.height >= point.width;
  });
  return portrait;
}

+ (CGFloat)safeAreaTop
{
  CGFloat top = 0;
  CGFloat bottom = 0;
  if ([self readSafeAreaTop:&top bottom:&bottom]) {
    return top;
  }
  return 0;
}

+ (CGFloat)safeAreaBottom
{
  CGFloat top = 0;
  CGFloat bottom = 0;
  if ([self readSafeAreaTop:&top bottom:&bottom]) {
    return bottom;
  }
  return 0;
}

+ (NSArray<NSString *> *)warnings
{
  NSMutableArray<NSString *> *warnings = [NSMutableArray array];

  CGSize native = CWNativeBoundsSize();
  CGSize pixel = [self pixelSize];
  if (native.width >= 1
      && (llround(native.width) != llround(pixel.width) || llround(native.height) != llround(pixel.height))) {
    [warnings addObject:[NSString stringWithFormat:@"/device 像素尺寸取自截图 %ldx%ld，nativeBounds=%ldx%ld 不一致（疑似兼容模式）",
                         (long)llround(pixel.width), (long)llround(pixel.height),
                         (long)llround(native.width), (long)llround(native.height)]];
  }

  CGFloat top = 0;
  CGFloat bottom = 0;
  if (![self readSafeAreaTop:&top bottom:&bottom]) {
    [warnings addObject:@"无法读取 safe_area（keyWindow 不可用）"];
  }

  return warnings.copy;
}

+ (NSString *)modelIdentifier
{
  size_t size = 0;
  if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) {
    return UIDevice.currentDevice.model ?: @"iPhone";
  }
  char *machine = malloc(size);
  if (NULL == machine) {
    return UIDevice.currentDevice.model ?: @"iPhone";
  }
  NSString *result = nil;
  if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
    result = [NSString stringWithUTF8String:machine];
  }
  free(machine);
  return result.length > 0 ? result : (UIDevice.currentDevice.model ?: @"iPhone");
}

+ (NSDictionary *)deviceDictionary
{
  CGSize pixel = [self pixelSize];
  CGSize point = [self pointSize];
  CGFloat scale = [self scale];

  NSMutableDictionary *screen = [@{
    @"pixel" : @[ @((NSInteger)llround(pixel.width)), @((NSInteger)llround(pixel.height)) ],
    @"point" : @[ @((NSInteger)llround(point.width)), @((NSInteger)llround(point.height)) ],
    @"scale" : @(scale),
    @"orientation" : [self isPortrait] ? @"portrait" : @"landscape",
  } mutableCopy];

  CGFloat top = 0;
  CGFloat bottom = 0;
  if ([self readSafeAreaTop:&top bottom:&bottom]) {
    screen[@"safe_area"] = @{
      @"top" : @(round(top)),
      @"bottom" : @(round(bottom)),
    };
  } else {
    screen[@"safe_area"] = NSNull.null;
  }

  return @{
    @"screen" : screen.copy,
    @"system" : @{
      @"model" : [self modelIdentifier],
      @"ios" : UIDevice.currentDevice.systemVersion ?: @"",
      @"name" : UIDevice.currentDevice.name ?: @"",
    },
  };
}

+ (BOOL)isValidPixelX:(NSInteger)x y:(NSInteger)y
{
  if (x < 0 || y < 0) {
    return NO;
  }
  if (![self pixelSizeIsMeasured]) {
    return YES;
  }
  CGSize pixel = [self pixelSize];
  return x <= (NSInteger)llround(pixel.width) && y <= (NSInteger)llround(pixel.height);
}

+ (BOOL)isValidPixelRect:(CGRect)rect
{
  if (rect.origin.x < 0 || rect.origin.y < 0 || rect.size.width <= 0 || rect.size.height <= 0) {
    return NO;
  }
  if (![self pixelSizeIsMeasured]) {
    return YES;
  }
  CGSize pixel = [self pixelSize];
  return CGRectGetMaxX(rect) <= pixel.width && CGRectGetMaxY(rect) <= pixel.height;
}

+ (CGPoint)pointFromPixelX:(NSInteger)x y:(NSInteger)y
{
  CGFloat scale = [self scale];
  if (scale <= 0) {
    scale = 1.0;
  }
  return CGPointMake(round((CGFloat)x / scale), round((CGFloat)y / scale));
}

+ (CGPoint)pointFromPixelPoint:(CGPoint)pixelPoint
{
  return [self pointFromPixelX:(NSInteger)pixelPoint.x y:(NSInteger)pixelPoint.y];
}

+ (CGSize)pointSizeFromPixelSize:(CGSize)pixelSize
{
  CGFloat scale = [self scale];
  if (scale <= 0) {
    scale = 1.0;
  }
  return CGSizeMake(pixelSize.width / scale, pixelSize.height / scale);
}

@end
