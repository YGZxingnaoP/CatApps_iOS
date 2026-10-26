#import "CWActionRunner.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <math.h>

#import <WebDriverAgentLib/FBConfiguration.h>
#import <WebDriverAgentLib/FBLogger.h>
#import <WebDriverAgentLib/FBSession.h>
#import <WebDriverAgentLib/FBXCTestDaemonsProxy.h>
#import <WebDriverAgentLib/XCUIApplication+FBHelpers.h>
#import <WebDriverAgentLib/XCUIApplication+FBQuiescence.h>
#import <WebDriverAgentLib/XCUIDevice+FBHelpers.h>

#import "CWConfig.h"
#import "CWError.h"
#import "CWGeometry.h"
#import "CWKeyboard.h"
#import "CWPasteboard.h"
#import "CWSessionManager.h"
#import "XCUIApplication+FBTouchAction.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"

@interface CWActionRunner ()
@property (atomic, assign) BOOL running;
@property (atomic, assign) BOOL cancelRequested;
@property (atomic, assign) NSInteger totalSteps;
@property (atomic, assign) NSInteger completedSteps;
@property (atomic, assign) BOOL fastGestures;

- (BOOL)performDirectDragFromPixel:(CGPoint)fromPixel
                           toPixel:(CGPoint)toPixel
                        durationMs:(NSInteger)durationMs
                            holdMs:(NSInteger)holdMs
                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                           message:(NSString *_Nonnull *_Nonnull)message;

- (BOOL)performDirectTapAt:(CGPoint)point
                     count:(NSInteger)count
                 errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                   message:(NSString *_Nonnull *_Nonnull)message;

- (BOOL)performDirectTouchAt:(CGPoint)point
                  durationMs:(NSInteger)durationMs
                   errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                     message:(NSString *_Nonnull *_Nonnull)message;

- (BOOL)performDirectPinchAt:(CGPoint)center
                       scale:(double)scale
                  durationMs:(NSInteger)durationMs
                   errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                     message:(NSString *_Nonnull *_Nonnull)message;

- (BOOL)synthesizeRecord:(XCSynthesizedEventRecord *)record
               errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                 message:(NSString *_Nonnull *_Nonnull)message;

- (BOOL)performStep:(CWActionStep *)step
        application:(XCUIApplication *)application
          errorCode:(NSString *_Nonnull *_Nonnull)errorCode
            message:(NSString *_Nonnull *_Nonnull)message;

- (nullable NSArray *)pinchActionsForStep:(CWActionStep *)step
                                errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                  message:(NSString *_Nonnull *_Nonnull)message;

- (BOOL)performW3CActions:(NSArray *)actions
               application:(XCUIApplication *)application
                 errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                   message:(NSString *_Nonnull *_Nonnull)message;

- (BOOL)performAppAction:(NSString *)mode
                bundleId:(NSString *)bundleId
               errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                 message:(NSString *_Nonnull *_Nonnull)message;

- (void)finishWithResult:(CWActionResult *)result results:(NSArray<NSDictionary *> *)results;

- (CWActionResult *)runSteps:(NSArray<CWActionStep *> *)steps
                     delayMs:(NSInteger)delayMs
                    waitIdle:(BOOL)waitIdle;
@end

static void CWActionOnMain(dispatch_block_t block)
{
  if (NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_sync(dispatch_get_main_queue(), block);
}

static NSDictionary *CWMove(CGFloat x, CGFloat y, NSInteger durationMs)
{
  return @{
    @"type" : @"pointerMove",
    @"x" : @(x),
    @"y" : @(y),
    @"duration" : @(durationMs),
  };
}

static NSDictionary *CWPause(NSInteger durationMs)
{
  return @{@"type" : @"pause", @"duration" : @(durationMs)};
}

static NSDictionary *CWDown(void)
{
  return @{@"type" : @"pointerDown", @"button" : @0};
}

static NSDictionary *CWUp(void)
{
  return @{@"type" : @"pointerUp", @"button" : @0};
}

static NSDictionary *CWPointerWithID(NSString *identifier, NSArray *actions)
{
  return @{
    @"id" : identifier,
    @"type" : @"pointer",
    @"parameters" : @{@"pointerType" : @"touch"},
    @"actions" : actions,
  };
}

static BOOL CWInterruptibleSleep(NSTimeInterval seconds, CWActionRunner *runner)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([deadline timeIntervalSinceNow] > 0) {
    if (runner.cancelRequested) {
      return NO;
    }
    NSTimeInterval slice = MIN(0.05, [deadline timeIntervalSinceNow]);
    [NSThread sleepForTimeInterval:slice];
  }
  return !runner.cancelRequested;
}

@implementation CWActionResult

- (instancetype)init
{
  if ((self = [super init])) {
    _code = CWErrorOK;
    _message = @"";
    _results = @[];
  }
  return self;
}

@end

@implementation CWActionRunner

+ (instancetype)shared
{
  static CWActionRunner *runner;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    runner = [CWActionRunner new];
  });
  return runner;
}

- (CWActionResult *)busyResult
{
  CWActionResult *result = [CWActionResult new];
  result.ok = NO;
  result.code = CWErrorBusy;
  result.message = @"Another action sequence is already running";
  return result;
}

- (CWActionResult *)performSteps:(NSArray<CWActionStep *> *)steps delayMs:(NSInteger)delayMs
{
  return [self performSteps:steps delayMs:delayMs waitIdle:NO];
}

- (CWActionResult *)performSteps:(NSArray<CWActionStep *> *)steps
                         delayMs:(NSInteger)delayMs
                        waitIdle:(BOOL)waitIdle
{
  FBConfiguration *configuration = [FBConfiguration sharedInstance];
  NSTimeInterval previousIdleTimeout = configuration.waitForIdleTimeout;
  NSTimeInterval previousCoolOff = configuration.animationCoolOffTimeout;
  if (!waitIdle) {
    configuration.waitForIdleTimeout = 0.0;
    configuration.animationCoolOffTimeout = 0.0;
  }
  [FBLogger logFmt:@"[CW] gesture mode fast=%d idleTimeout=%.1f animationCoolOff=%.1f",
   waitIdle ? 0 : 1,
   configuration.waitForIdleTimeout,
   configuration.animationCoolOffTimeout];
  CWActionResult *result = [self runSteps:steps delayMs:delayMs waitIdle:waitIdle];
  configuration.waitForIdleTimeout = previousIdleTimeout;
  configuration.animationCoolOffTimeout = previousCoolOff;
  return result;
}

- (CWActionResult *)runSteps:(NSArray<CWActionStep *> *)steps
                     delayMs:(NSInteger)delayMs
                    waitIdle:(BOOL)waitIdle
{
  @synchronized (self) {
    if (self.running) {
      return [self busyResult];
    }
    self.running = YES;
    self.cancelRequested = NO;
    self.totalSteps = steps.count;
    self.completedSteps = 0;
  }

  CWActionResult *result = [CWActionResult new];
  NSMutableArray<NSDictionary *> *stepResults = [NSMutableArray array];
  self.fastGestures = !waitIdle;

  if ([XCUIDevice.sharedDevice fb_isScreenLocked]) {
    result.ok = NO;
    result.code = CWErrorDeviceLocked;
    result.message = @"The device screen is locked";
    [self finishWithResult:result results:stepResults];
    return result;
  }

  NSError *sessionError = nil;
  if (![CWSessionManager.shared ensureSessionWithError:&sessionError]) {
    result.ok = NO;
    result.code = CWErrorSessionLost;
    result.message = sessionError.localizedDescription ?: @"XCTest session lost";
    [self finishWithResult:result results:stepResults];
    return result;
  }

  for (CWActionStep *step in steps) {
    if (self.cancelRequested) {
      result.code = CWErrorCancelled;
      result.message = @"Cancelled";
      break;
    }
    if (step.index > 0) {
      if (!CWInterruptibleSleep(delayMs / 1000.0, self)) {
        result.code = CWErrorCancelled;
        result.message = @"Cancelled";
        break;
      }
    }
    if (self.cancelRequested) {
      result.code = CWErrorCancelled;
      result.message = @"Cancelled";
      break;
    }

    NSError *stepSessionError = nil;
    XCUIApplication *application = [CWSessionManager.shared applicationWithError:&stepSessionError];
    if (nil == application) {
      result.ok = NO;
      result.code = CWErrorSessionLost;
      result.message = stepSessionError.localizedDescription ?: @"XCTest session lost";
      break;
    }
    application.fb_shouldWaitForQuiescence = waitIdle;

    CFTimeInterval stepStart = CFAbsoluteTimeGetCurrent();
    NSString *stepCode = CWErrorOK;
    NSString *stepMessage = @"";
    BOOL stepOK = [self performStep:step
                        application:application
                          errorCode:&stepCode
                            message:&stepMessage];
    NSInteger stepElapsed = (NSInteger)llround((CFAbsoluteTimeGetCurrent() - stepStart) * 1000.0);
    NSMutableDictionary *entry = [@{
      @"index" : @(step.index),
      @"action" : step.action,
      @"ok" : @(stepOK),
      @"code" : stepCode ?: CWErrorInternal,
      @"elapsed_ms" : @(stepElapsed),
    } mutableCopy];
    [stepResults addObject:entry.copy];

    if (!stepOK) {
      result.ok = NO;
      result.code = stepCode ?: CWErrorInternal;
      result.message = stepMessage ?: @"Action failed";
      break;
    }

    result.executed++;
    @synchronized (self) {
      self.completedSteps = result.executed;
    }
    if (self.cancelRequested) {
      result.code = CWErrorCancelled;
      result.message = @"Cancelled";
      break;
    }
  }

  if (nil == result.code || [result.code isEqualToString:CWErrorOK]) {
    result.ok = YES;
    result.code = CWErrorOK;
    result.message = @"";
  } else {
    result.ok = NO;
  }
  [self finishWithResult:result results:stepResults];
  return result;
}

- (void)finishWithResult:(CWActionResult *)result results:(NSArray<NSDictionary *> *)results
{
  result.results = results.copy;
  @synchronized (self) {
    self.running = NO;
    self.cancelRequested = NO;
    self.completedSteps = 0;
    self.totalSteps = 0;
  }
}

- (BOOL)requestStop
{
  @synchronized (self) {
    if (!self.running) {
      return NO;
    }
    self.cancelRequested = YES;
    return YES;
  }
}

- (BOOL)isRunning
{
  @synchronized (self) {
    return self.running;
  }
}

- (NSInteger)remainingSteps
{
  @synchronized (self) {
    return MAX(0, self.totalSteps - self.completedSteps);
  }
}

- (BOOL)performStep:(CWActionStep *)step
        application:(XCUIApplication *)application
          errorCode:(NSString *_Nonnull *_Nonnull)errorCode
            message:(NSString *_Nonnull *_Nonnull)message
{
  NSString *action = step.action;
  if ([action isEqualToString:@"tap"]) {
    if (self.fastGestures) {
      CGPoint fastPoint = [CWGeometry pointFromPixelX:step.x y:step.y];
      return [self performDirectTapAt:fastPoint
                                count:step.count
                            errorCode:errorCode
                              message:message];
    }
    CGPoint point = [CWGeometry pointFromPixelX:step.x y:step.y];
    NSInteger gapMs = [CWConfig tapGapMs];
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:CWMove(point.x, point.y, 0)];
    for (NSInteger index = 0; index < step.count; index++) {
      [items addObject:CWDown()];
      [items addObject:CWUp()];
      if (index + 1 < step.count) {
        [items addObject:CWPause(gapMs)];
      }
    }
    return [self performW3CActions:@[ CWPointerWithID(@"finger", items) ]
                       application:application
                         errorCode:errorCode
                           message:message];
  }

  if ([action isEqualToString:@"long_press"]) {
    if (self.fastGestures) {
      CGPoint fastPoint = [CWGeometry pointFromPixelX:step.x y:step.y];
      return [self performDirectTouchAt:fastPoint
                             durationMs:step.durationMs
                              errorCode:errorCode
                                message:message];
    }
    CGPoint point = [CWGeometry pointFromPixelX:step.x y:step.y];
    NSArray *items = @[
      CWMove(point.x, point.y, 0),
      CWDown(),
      CWPause(step.durationMs),
      CWUp(),
    ];
    return [self performW3CActions:@[ CWPointerWithID(@"finger", items) ]
                       application:application
                         errorCode:errorCode
                           message:message];
  }

  if ([action isEqualToString:@"swipe"]) {
    if (self.fastGestures) {
      return [self performDirectDragFromPixel:step.fromPixel
                                     toPixel:step.toPixel
                                  durationMs:step.durationMs
                                      holdMs:0
                                   errorCode:errorCode
                                     message:message];
    }
    CGPoint from = [CWGeometry pointFromPixelPoint:step.fromPixel];
    CGPoint to = [CWGeometry pointFromPixelPoint:step.toPixel];
    NSInteger samples = MAX(2, (NSInteger)llround(step.durationMs / 1000.0 * 60.0));
    CGFloat sampleDuration = step.durationMs / (CGFloat)samples;
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:CWMove(from.x, from.y, 0)];
    [items addObject:CWDown()];
    for (NSInteger index = 1; index <= samples; index++) {
      CGFloat progress = (CGFloat)index / (CGFloat)samples;
      CGFloat x = from.x + (to.x - from.x) * progress;
      CGFloat y = from.y + (to.y - from.y) * progress;
      [items addObject:CWMove(x, y, (NSInteger)llround(sampleDuration))];
    }
    [items addObject:CWUp()];
    return [self performW3CActions:@[ CWPointerWithID(@"finger", items) ]
                       application:application
                         errorCode:errorCode
                           message:message];
  }

  if ([action isEqualToString:@"drag"]) {
    if (self.fastGestures) {
      return [self performDirectDragFromPixel:step.fromPixel
                                     toPixel:step.toPixel
                                  durationMs:step.durationMs
                                      holdMs:step.holdMs
                                   errorCode:errorCode
                                     message:message];
    }
    CGPoint from = [CWGeometry pointFromPixelPoint:step.fromPixel];
    CGPoint to = [CWGeometry pointFromPixelPoint:step.toPixel];
    NSInteger samples = MAX(2, (NSInteger)llround(step.durationMs / 1000.0 * 60.0));
    CGFloat sampleDuration = step.durationMs / (CGFloat)samples;
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:CWMove(from.x, from.y, 0)];
    [items addObject:CWDown()];
    if (step.holdMs > 0) {
      [items addObject:CWPause(step.holdMs)];
    }
    for (NSInteger index = 1; index <= samples; index++) {
      CGFloat progress = (CGFloat)index / (CGFloat)samples;
      CGFloat x = from.x + (to.x - from.x) * progress;
      CGFloat y = from.y + (to.y - from.y) * progress;
      [items addObject:CWMove(x, y, (NSInteger)llround(sampleDuration))];
    }
    [items addObject:CWUp()];
    return [self performW3CActions:@[ CWPointerWithID(@"finger", items) ]
                       application:application
                         errorCode:errorCode
                           message:message];
  }
  if ([action isEqualToString:@"pinch"]) {
    if (self.fastGestures) {
      CGPoint fastCenter = [CWGeometry pointFromPixelX:step.x y:step.y];
      return [self performDirectPinchAt:fastCenter
                                  scale:step.scale
                             durationMs:step.durationMs
                              errorCode:errorCode
                                message:message];
    }
    NSArray *actions = [self pinchActionsForStep:step errorCode:errorCode message:message];
    if (nil == actions) {
      return NO;
    }
    return [self performW3CActions:actions
                       application:application
                         errorCode:errorCode
                           message:message];
  }

  if ([action isEqualToString:@"type_text"]) {
    return [CWKeyboard typeText:step.text errorCode:errorCode message:message];
  }

  if ([action isEqualToString:@"paste_text"]) {
    return [CWPasteboard pasteText:step.text submit:NO errorCode:errorCode message:message];
  }

  if ([action isEqualToString:@"press_key"]) {
    return [CWKeyboard pressKey:step.key
                    application:application
                      errorCode:errorCode
                        message:message];
  }

  if ([action isEqualToString:@"launch_app"]
      || [action isEqualToString:@"activate_app"]
      || [action isEqualToString:@"terminate_app"]) {
    NSString *mode = [action stringByReplacingOccurrencesOfString:@"_app" withString:@""];
    return [self performAppAction:mode
                        bundleId:step.bundleId
                       errorCode:errorCode
                         message:message];
  }

  if ([action isEqualToString:@"wait"]) {
    if (!CWInterruptibleSleep(step.durationMs / 1000.0, self)) {
      *errorCode = CWErrorCancelled;
      *message = @"Cancelled";
      return NO;
    }
    *errorCode = CWErrorOK;
    *message = @"";
    return YES;
  }

  *errorCode = CWErrorBadRequest;
  *message = [NSString stringWithFormat:@"Unsupported action %@", action];
  return NO;
}

- (BOOL)synthesizeRecord:(XCSynthesizedEventRecord *)record
               errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                 message:(NSString *_Nonnull *_Nonnull)message
{
  if (nil == record) {
    *errorCode = CWErrorInternal;
    *message = @"Unable to build the gesture event";
    return NO;
  }
  __block BOOL success = NO;
  __block NSString *failure = nil;
  CWActionOnMain(^{
    NSError *error = nil;
    success = [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error];
    if (!success) {
      failure = error.localizedDescription ?: @"Gesture synthesis failed";
    }
  });
  if (!success) {
    *errorCode = CWErrorInternal;
    *message = failure ?: @"Gesture synthesis failed";
    return NO;
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

- (BOOL)performDirectTapAt:(CGPoint)point
                     count:(NSInteger)count
                 errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                   message:(NSString *_Nonnull *_Nonnull)message
{
  NSInteger total = MAX(1, count);
  NSInteger gapMs = [CWConfig tapGapMs];
  for (NSInteger index = 0; index < total; index++) {
    __block XCSynthesizedEventRecord *record = nil;
    CWActionOnMain(^{
      XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
      [path liftUpAtOffset:0.03];
      record = [[XCSynthesizedEventRecord alloc] initWithName:@"CW Tap"
                                        interfaceOrientation:UIInterfaceOrientationPortrait];
      [record addPointerEventPath:path];
    });
    if (![self synthesizeRecord:record errorCode:errorCode message:message]) {
      return NO;
    }
    if (index + 1 < total) {
      [NSThread sleepForTimeInterval:gapMs / 1000.0];
    }
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

- (BOOL)performDirectTouchAt:(CGPoint)point
                  durationMs:(NSInteger)durationMs
                   errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                     message:(NSString *_Nonnull *_Nonnull)message
{
  CGFloat seconds = MAX(0.05, durationMs / 1000.0);
  __block XCSynthesizedEventRecord *record = nil;
  CWActionOnMain(^{
    XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
    [path liftUpAtOffset:seconds];
    record = [[XCSynthesizedEventRecord alloc] initWithName:@"CW Touch"
                                      interfaceOrientation:UIInterfaceOrientationPortrait];
    [record addPointerEventPath:path];
  });
  return [self synthesizeRecord:record errorCode:errorCode message:message];
}

- (BOOL)performDirectPinchAt:(CGPoint)center
                       scale:(double)scale
                  durationMs:(NSInteger)durationMs
                   errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                     message:(NSString *_Nonnull *_Nonnull)message
{
  CGFloat startOffset = 60.0;
  CGFloat clampedScale = MAX(0.2, MIN(5.0, scale));
  CGFloat endOffset = MAX(10.0, startOffset * clampedScale);
  CGFloat seconds = MAX(0.05, durationMs / 1000.0);
  __block XCSynthesizedEventRecord *record = nil;
  CWActionOnMain(^{
    XCPointerEventPath *first = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(center.x - startOffset, center.y)
                                                                         offset:0];
    [first moveToPoint:CGPointMake(center.x - endOffset, center.y) atOffset:seconds];
    [first liftUpAtOffset:seconds + 0.02];
    XCPointerEventPath *second = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(center.x + startOffset, center.y)
                                                                          offset:0];
    [second moveToPoint:CGPointMake(center.x + endOffset, center.y) atOffset:seconds];
    [second liftUpAtOffset:seconds + 0.02];
    record = [[XCSynthesizedEventRecord alloc] initWithName:@"CW Pinch"
                                      interfaceOrientation:UIInterfaceOrientationPortrait];
    [record addPointerEventPath:first];
    [record addPointerEventPath:second];
  });
  return [self synthesizeRecord:record errorCode:errorCode message:message];
}

- (BOOL)performDirectDragFromPixel:(CGPoint)fromPixel
                           toPixel:(CGPoint)toPixel
                        durationMs:(NSInteger)durationMs
                            holdMs:(NSInteger)holdMs
                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                           message:(NSString *_Nonnull *_Nonnull)message
{
  CGPoint from = [CWGeometry pointFromPixelPoint:fromPixel];
  CGPoint to = [CWGeometry pointFromPixelPoint:toPixel];
  CGFloat distance = hypot(to.x - from.x, to.y - from.y);
  CGFloat seconds = MAX(0.05, durationMs / 1000.0);
  CGFloat pointsPerSecond = MAX(1.0, distance / seconds);
  __block XCSynthesizedEventRecord *record = nil;
  CWActionOnMain(^{
    record = [XCUIApplication fb_pressDragEventFromPoint:from
                                             forDuration:holdMs / 1000.0
                                                 toPoint:to
                                         pointsPerSecond:pointsPerSecond
                                     thenHoldForDuration:0
                                               displayID:0
                                    interfaceOrientation:UIInterfaceOrientationPortrait];
  });
  if (nil == record) {
    *errorCode = CWErrorInternal;
    *message = @"Unable to build the gesture event";
    return NO;
  }
  __block BOOL success = NO;
  __block NSString *failure = nil;
  CWActionOnMain(^{
    NSError *error = nil;
    success = [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error];
    if (!success) {
      failure = error.localizedDescription ?: @"Gesture synthesis failed";
    }
  });
  if (!success) {
    *errorCode = CWErrorInternal;
    *message = failure ?: @"Gesture synthesis failed";
    return NO;
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

- (nullable NSArray *)pinchActionsForStep:(CWActionStep *)step
                                errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                  message:(NSString *_Nonnull *_Nonnull)message
{
  CGPoint center = [CWGeometry pointFromPixelX:step.x y:step.y];
  CGSize screen = [CWGeometry pointSize];
  CGFloat maxOffset = MIN(MIN(center.x, center.y), MIN(screen.width - center.x, screen.height - center.y));
  CGFloat base = MIN(40.0, maxOffset / MAX(1.0, step.scale));
  if (base < 1.0) {
    *errorCode = CWErrorOutOfRange;
    *message = @"The pinch center is too close to the screen edge";
    return nil;
  }
  CGFloat target = MAX(1.0, base * step.scale);
  if (target > maxOffset) {
    target = maxOffset;
  }
  NSInteger samples = MAX(2, (NSInteger)llround(step.durationMs / 1000.0 * 60.0));
  CGFloat sampleDuration = step.durationMs / (CGFloat)samples;

  NSMutableArray *first = [NSMutableArray array];
  NSMutableArray *second = [NSMutableArray array];
  [first addObject:CWMove(center.x - base, center.y - base, 0)];
  [first addObject:CWDown()];
  [second addObject:CWMove(center.x + base, center.y + base, 0)];
  [second addObject:CWDown()];
  for (NSInteger index = 1; index <= samples; index++) {
    CGFloat progress = (CGFloat)index / (CGFloat)samples;
    CGFloat offset = base + (target - base) * progress;
    [first addObject:CWMove(center.x - offset, center.y - offset, (NSInteger)llround(sampleDuration))];
    [second addObject:CWMove(center.x + offset, center.y + offset, (NSInteger)llround(sampleDuration))];
  }
  [first addObject:CWUp()];
  [second addObject:CWUp()];

  return @[
    CWPointerWithID(@"finger1", first),
    CWPointerWithID(@"finger2", second),
  ];
}

- (BOOL)performW3CActions:(NSArray *)actions
               application:(XCUIApplication *)application
                 errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                   message:(NSString *_Nonnull *_Nonnull)message
{
  __block BOOL success = NO;
  __block NSString *failure = nil;
  CWActionOnMain(^{
    FBSession *session = FBSession.activeSession;
    if (nil == session) {
      failure = @"XCTest session lost";
      return;
    }
    NSError *error = nil;
    @try {
      success = [application fb_performW3CActions:actions
                                     elementCache:session.elementCache
                                            error:&error];
    } @catch (NSException *exception) {
      failure = exception.reason ?: @"Gesture execution failed";
      return;
    }
    if (!success) {
      failure = error.localizedDescription ?: @"Gesture execution failed";
    }
  });
  if (!success) {
    *errorCode = ([failure isEqualToString:@"XCTest session lost"]) ? CWErrorSessionLost : CWErrorInternal;
    *message = failure ?: @"Gesture execution failed";
    return NO;
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

- (BOOL)performAppAction:(NSString *)mode
                bundleId:(NSString *)bundleId
               errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                 message:(NSString *_Nonnull *_Nonnull)message
{
  __block BOOL success = NO;
  __block NSString *failure = nil;
  CWActionOnMain(^{
    @try {
      XCUIApplication *application = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
      application.fb_shouldWaitForQuiescence = NO;
      if ([mode isEqualToString:@"terminate"]) {
        [application terminate];
        success = YES;
        return;
      }
      if ([mode isEqualToString:@"activate"]) {
        [application activate];
      } else {
        [application launch];
      }
      success = application.state >= XCUIApplicationStateRunningBackground;
      if (!success) {
        failure = [NSString stringWithFormat:@"Application %@ is not running", bundleId];
      }
    } @catch (NSException *exception) {
      failure = exception.reason ?: [NSString stringWithFormat:@"Unable to %@ %@", mode, bundleId];
    }
  });
  if (!success) {
    *errorCode = CWErrorNotFound;
    *message = failure ?: [NSString stringWithFormat:@"Unable to %@ %@", mode, bundleId];
    return NO;
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

@end
