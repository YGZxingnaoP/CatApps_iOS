#import "CWServer.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <math.h>

#import <WebDriverAgentLib/FBHTTPStatusCodes.h>
#import <WebDriverAgentLib/FBLogger.h>
#import <WebDriverAgentLib/FBRoute.h>
#import <WebDriverAgentLib/FBRouteRequest.h>

#import "CWActionRunner.h"
#import "CWActionStep.h"
#import "CWApiPaths.h"
#import "CWAuth.h"
#import "CWConfig.h"
#import "CWError.h"
#import "CWGeometry.h"
#import "CWOCREngine.h"
#import "CWPasteboard.h"
#import "CWResponse.h"
#import "CWScreenshot.h"
#import "CWSessionManager.h"

static BOOL CWParseDigits(NSString *string, NSInteger *value)
{
  if (string.length == 0) {
    return NO;
  }
  NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
  if ([string rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
    return NO;
  }
  *value = string.integerValue;
  return YES;
}

static NSString *CWTimestamp(void)
{
  return [NSString stringWithFormat:@"%lld", (long long)llround(NSDate.date.timeIntervalSince1970 * 1000.0)];
}

@interface CWServer ()

+ (id<FBResponsePayload>)dispatchRequest:(FBRouteRequest *)request
                                  block:(id<FBResponsePayload> (^)(CFTimeInterval start))block;
+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                 message:(nullable NSString *)message
                                   start:(CFTimeInterval)start;
+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                 message:(nullable NSString *)message
                                    data:(nullable id)data
                                   start:(CFTimeInterval)start;
+ (NSArray<NSString *> *)capabilities;
+ (id<FBResponsePayload>)handlePingWithStart:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleDeviceWithStart:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleCreateSessionWithStart:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleDeleteSessionWithStart:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleActions:(FBRouteRequest *)request start:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleStopWithStart:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleScreenshot:(FBRouteRequest *)request start:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleOCR:(FBRouteRequest *)request start:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handlePaste:(FBRouteRequest *)request start:(CFTimeInterval)start;
+ (id<FBResponsePayload>)handleSourceWithStart:(CFTimeInterval)start;
+ (id<FBResponsePayload>)notFoundWithStart:(CFTimeInterval)start;

@end

@implementation CWServer

+ (NSArray *)routes
{
  return @[
    [[[[FBRoute GET:CWApiPing] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handlePingWithStart:start];
      }];
    }],
    [[[[FBRoute GET:CWApiDevice] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleDeviceWithStart:start];
      }];
    }],
    [[[[FBRoute POST:CWApiSession] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleCreateSessionWithStart:start];
      }];
    }],
    [[[[FBRoute DELETE:CWApiSession] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleDeleteSessionWithStart:start];
      }];
    }],
    [[[[FBRoute POST:CWApiActions] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleActions:request start:start];
      }];
    }],
    [[[[FBRoute POST:CWApiStop] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleStopWithStart:start];
      }];
    }],
    [[[[FBRoute GET:CWApiScreenshot] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleScreenshot:request start:start];
      }];
    }],
    [[[[FBRoute POST:CWApiOCR] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleOCR:request start:start];
      }];
    }],
    [[[[FBRoute POST:CWApiPaste] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handlePaste:request start:start];
      }];
    }],
    [[[[FBRoute GET:CWApiSource] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self handleSourceWithStart:start];
      }];
    }],
    [[[[FBRoute GET:CWApiWildcard] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self notFoundWithStart:start];
      }];
    }],
    [[[[FBRoute POST:CWApiWildcard] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self notFoundWithStart:start];
      }];
    }],
    [[[[FBRoute PUT:CWApiWildcard] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self notFoundWithStart:start];
      }];
    }],
    [[[[FBRoute DELETE:CWApiWildcard] withoutSession] dedicated] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
      return [self dispatchRequest:request block:^id<FBResponsePayload>(CFTimeInterval start) {
        return [self notFoundWithStart:start];
      }];
    }],
  ];
}

+ (void)bootstrap
{
  dispatch_async(dispatch_get_main_queue(), ^{
    NSError *error = nil;
    if (![CWSessionManager.shared ensureSessionWithError:&error]) {
      [FBLogger logFmt:@"CW session bootstrap failed: %@", error.localizedDescription];
    }
  });
}

+ (id<FBResponsePayload>)dispatchRequest:(FBRouteRequest *)request
                                  block:(id<FBResponsePayload> (^)(CFTimeInterval start))block
{
  if (![CWAuth isAuthorizedForHeaders:request.headers]) {
    return [CWResponse failureWithCode:CWErrorUnauthorized
                              message:@"Invalid or missing bearer token"
                            elapsedMs:0
                           statusCode:kHTTPStatusCodeUnauthorized];
  }
  CFTimeInterval start = CFAbsoluteTimeGetCurrent();
  @try {
    return block(start);
  } @catch (NSException *exception) {
    return [CWResponse failureWithCode:CWErrorInternal
                              message:exception.reason ?: @"Internal CW error"
                            elapsedMs:[CWResponse elapsedMsSince:start]];
  }
}

+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                 message:(nullable NSString *)message
                                   start:(CFTimeInterval)start
{
  return [CWResponse failureWithCode:code
                             message:message
                           elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                 message:(nullable NSString *)message
                                    data:(nullable id)data
                                   start:(CFTimeInterval)start
{
  return [CWResponse failureWithCode:code
                             message:message
                           elapsedMs:[CWResponse elapsedMsSince:start]
                                data:data];
}

+ (NSArray<NSString *> *)capabilities
{
  NSMutableArray<NSString *> *capabilities = [@[
    @"tap",
    @"long_press",
    @"swipe",
    @"drag",
    @"pinch",
    @"type_text",
    @"paste_text",
    @"press_key",
    @"launch_app",
    @"activate_app",
    @"terminate_app",
    @"screenshot",
  ] mutableCopy];
  if (![CWConfig ocrDisabled] && nil != NSClassFromString(@"VNRecognizeTextRequest")) {
    [capabilities addObject:@"ocr"];
  }
  return capabilities.copy;
}

+ (id<FBResponsePayload>)handlePingWithStart:(CFTimeInterval)start
{
  return [CWResponse successWithData:@{
    @"app" : [CWConfig appName],
    @"version" : [CWConfig runnerVersion],
    @"build" : [CWConfig runnerBuild],
    @"session" : @([CWSessionManager.shared hasSession]),
  } elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)handleDeviceWithStart:(CFTimeInterval)start
{
  if (![CWGeometry isPortrait]) {
    return [self failureWithCode:CWErrorUnsupported
                         message:@"Landscape orientation is not supported"
                           start:start];
  }
  NSMutableDictionary *data = [[CWGeometry deviceDictionary] mutableCopy];
  data[@"capabilities"] = [self capabilities];
  data[@"session"] = @([CWSessionManager.shared hasSession]);
  NSArray<NSString *> *warnings = [CWGeometry warnings];
  if (warnings.count > 0) {
    data[@"warnings"] = warnings;
  }
  return [CWResponse successWithData:data elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)handleCreateSessionWithStart:(CFTimeInterval)start
{
  NSError *error = nil;
  if (![CWSessionManager.shared recreateSessionWithError:&error]) {
    return [self failureWithCode:CWErrorSessionLost
                         message:error.localizedDescription
                           start:start];
  }
  return [CWResponse successWithData:@{@"session" : @YES}
                           elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)handleDeleteSessionWithStart:(CFTimeInterval)start
{
  [CWSessionManager.shared releaseSession];
  return [CWResponse successWithData:@{@"session" : @NO}
                           elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)handleActions:(FBRouteRequest *)request start:(CFTimeInterval)start
{
  id stepsValue = request.arguments[@"steps"];
  if (![stepsValue isKindOfClass:NSArray.class]) {
    return [self failureWithCode:CWErrorBadRequest message:@"steps must be an array" start:start];
  }
  NSArray *rawSteps = (NSArray *)stepsValue;
  if (rawSteps.count < 1 || rawSteps.count > 64) {
    return [self failureWithCode:CWErrorBadRequest message:@"steps must contain 1..64 items" start:start];
  }

  NSInteger delayMs = 90;
  id delayValue = request.arguments[@"delay_ms"];
  if (nil != delayValue) {
    if (![delayValue isKindOfClass:NSNumber.class]) {
      return [self failureWithCode:CWErrorBadRequest message:@"delay_ms must be an integer" start:start];
    }
    double delay = [(NSNumber *)delayValue doubleValue];
    if (!isfinite(delay) || delay != floor(delay)) {
      return [self failureWithCode:CWErrorBadRequest message:@"delay_ms must be an integer" start:start];
    }
    delayMs = MAX(90, MIN(2000, (NSInteger)delay));
  }

  NSMutableArray<CWActionStep *> *steps = [NSMutableArray array];
  for (NSUInteger index = 0; index < rawSteps.count; index++) {
    NSString *errorCode = nil;
    NSString *message = nil;
    CWActionStep *step = [CWActionStep stepWithDictionary:rawSteps[index]
                                                   index:(NSInteger)index
                                               errorCode:&errorCode
                                                 message:&message];
    if (nil == step) {
      return [self failureWithCode:errorCode ?: CWErrorBadRequest
                           message:message
                             start:start];
    }
    [steps addObject:step];
  }

  BOOL waitIdle = NO;
  id waitIdleValue = request.arguments[@"wait_idle"];
  if (nil != waitIdleValue) {
    if (![waitIdleValue isKindOfClass:NSNumber.class]) {
      return [self failureWithCode:CWErrorBadRequest message:@"wait_idle must be a boolean" start:start];
    }
    waitIdle = [(NSNumber *)waitIdleValue boolValue];
  }

  CWActionResult *result = [CWActionRunner.shared performSteps:steps delayMs:delayMs waitIdle:waitIdle];
  NSDictionary *data = @{
    @"executed" : @(result.executed),
    @"results" : result.results ?: @[],
  };
  if (result.ok) {
    return [CWResponse successWithData:data elapsedMs:[CWResponse elapsedMsSince:start]];
  }
  return [self failureWithCode:result.code
                       message:result.message
                          data:data
                         start:start];
}

+ (id<FBResponsePayload>)handleStopWithStart:(CFTimeInterval)start
{
  BOOL cancelled = [CWActionRunner.shared requestStop];
  NSInteger remaining = [CWActionRunner.shared remainingSteps];
  return [CWResponse successWithData:@{
    @"cancelled" : @(cancelled),
    @"remaining_steps" : @(remaining),
  } elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)handleScreenshot:(FBRouteRequest *)request start:(CFTimeInterval)start
{
  NSString *format = request.parameters[@"format"] ?: @"png";
  NSNumber *maxEdge = nil;
  NSString *maxEdgeString = request.parameters[@"max_edge"];
  if (maxEdgeString.length > 0) {
    NSInteger value = 0;
    if (!CWParseDigits(maxEdgeString, &value)) {
      return [self failureWithCode:CWErrorBadRequest message:@"max_edge must be an integer" start:start];
    }
    if (value > 0) {
      maxEdge = @(value);
    }
  }
  NSInteger quality = 85;
  NSString *qualityString = request.parameters[@"quality"];
  if (qualityString.length > 0) {
    NSInteger value = 0;
    if (!CWParseDigits(qualityString, &value)) {
      return [self failureWithCode:CWErrorBadRequest message:@"quality must be an integer" start:start];
    }
    quality = MAX(1, MIN(100, value));
  }

  NSArray<NSNumber *> *region = nil;
  NSString *regionString = request.parameters[@"region"];
  if (regionString.length > 0) {
    NSArray<NSString *> *parts = [regionString componentsSeparatedByString:@","];
    if (parts.count != 4) {
      return [self failureWithCode:CWErrorBadRequest message:@"region must be x,y,w,h" start:start];
    }
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    for (NSString *part in parts) {
      NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      NSInteger value = 0;
      if (trimmed.length == 0 || !CWParseDigits(trimmed, &value)) {
        return [self failureWithCode:CWErrorBadRequest message:@"region must contain integers" start:start];
      }
      [values addObject:@(value)];
    }
    CGRect rect = CGRectMake(values[0].doubleValue,
                             values[1].doubleValue,
                             values[2].doubleValue,
                             values[3].doubleValue);
    if (rect.size.width < 1 || rect.size.height < 1) {
      return [self failureWithCode:CWErrorBadRequest message:@"region width and height must be positive" start:start];
    }
    if (![CWGeometry isValidPixelRect:rect]) {
      return [self failureWithCode:CWErrorOutOfRange message:@"The region is outside the screen" start:start];
    }
    region = values.copy;
  }

  NSString *errorCode = nil;
  NSString *message = nil;
  CWScreenshotResult *result = [CWScreenshot captureWithFormat:format
                                                       maxEdge:maxEdge
                                                       quality:quality
                                                        region:region
                                                     errorCode:&errorCode
                                                       message:&message];
  if (nil == result) {
    return [self failureWithCode:errorCode ?: CWErrorInternal message:message start:start];
  }

  NSMutableDictionary *headers = [@{
    @"X-CW-Size" : [NSString stringWithFormat:@"%ldx%ld", (long)result.width, (long)result.height],
    @"X-CW-Scale" : [NSString stringWithFormat:@"%.1f", [CWGeometry scale]],
    @"X-CW-Ts" : CWTimestamp(),
  } mutableCopy];
  if (nil != regionString && regionString.length > 0) {
    headers[@"X-CW-Crop"] = regionString;
  }
  return [CWResponse rawData:result.data
                contentType:result.contentType
                    headers:headers.copy
                 statusCode:kHTTPStatusCodeOK];
}

+ (id<FBResponsePayload>)handleOCR:(FBRouteRequest *)request start:(CFTimeInterval)start
{
  if ([CWConfig ocrDisabled] || nil == NSClassFromString(@"VNRecognizeTextRequest")) {
    return [self failureWithCode:CWErrorUnsupported message:@"OCR is not available" start:start];
  }

  NSArray<NSNumber *> *region = nil;
  id regionValue = request.arguments[@"region"];
  if (nil != regionValue) {
    if (![regionValue isKindOfClass:NSArray.class] || [(NSArray *)regionValue count] != 4) {
      return [self failureWithCode:CWErrorBadRequest message:@"region must be [x, y, w, h]" start:start];
    }
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    for (id item in (NSArray *)regionValue) {
      if (![item isKindOfClass:NSNumber.class]) {
        return [self failureWithCode:CWErrorBadRequest message:@"region must contain integers" start:start];
      }
      double number = [(NSNumber *)item doubleValue];
      if (!isfinite(number) || number != floor(number)) {
        return [self failureWithCode:CWErrorBadRequest message:@"region must contain integers" start:start];
      }
      [values addObject:@((NSInteger)number)];
    }
    CGRect rect = CGRectMake(values[0].doubleValue,
                             values[1].doubleValue,
                             values[2].doubleValue,
                             values[3].doubleValue);
    if (![CWGeometry isValidPixelRect:rect]) {
      return [self failureWithCode:CWErrorOutOfRange message:@"The OCR region is outside the screen" start:start];
    }
    region = values.copy;
  }

  NSArray<NSString *> *languages = nil;
  id languagesValue = request.arguments[@"languages"];
  if (nil != languagesValue) {
    if (![languagesValue isKindOfClass:NSArray.class]) {
      return [self failureWithCode:CWErrorBadRequest message:@"languages must be an array" start:start];
    }
    NSArray *rawLanguages = (NSArray *)languagesValue;
    if (rawLanguages.count < 1 || rawLanguages.count > 4) {
      return [self failureWithCode:CWErrorBadRequest message:@"languages must contain 1..4 items" start:start];
    }
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (id item in rawLanguages) {
      if (![item isKindOfClass:NSString.class] || [(NSString *)item length] == 0) {
        return [self failureWithCode:CWErrorBadRequest message:@"languages must contain strings" start:start];
      }
      [values addObject:(NSString *)item];
    }
    languages = values.copy;
  }

  NSString *errorCode = nil;
  NSString *message = nil;
  CWScreenshotResult *screenshot = [CWScreenshot captureWithFormat:@"png"
                                                             maxEdge:nil
                                                             quality:85
                                                           errorCode:&errorCode
                                                             message:&message];
  if (nil == screenshot) {
    return [self failureWithCode:errorCode ?: CWErrorInternal message:message start:start];
  }

  CWOCRResult *result = [CWOCREngine.shared recognizeImageData:screenshot.data
                                                       region:region
                                                    languages:languages
                                                    errorCode:&errorCode
                                                      message:&message];
  if (nil == result) {
    return [self failureWithCode:errorCode ?: CWErrorInternal message:message start:start];
  }
  return [CWResponse successWithData:@{
    @"image_size" : result.imageSize,
    @"texts" : result.texts,
  } elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)handlePaste:(FBRouteRequest *)request start:(CFTimeInterval)start
{
  id textValue = request.arguments[@"text"];
  if (![textValue isKindOfClass:NSString.class]) {
    return [self failureWithCode:CWErrorBadRequest message:@"text is required" start:start];
  }
  NSString *text = (NSString *)textValue;
  if (text.length > 16384) {
    return [self failureWithCode:CWErrorBadRequest message:@"text is too long" start:start];
  }
  BOOL submit = NO;
  id submitValue = request.arguments[@"submit"];
  if (nil != submitValue) {
    if (![submitValue isKindOfClass:NSNumber.class]) {
      return [self failureWithCode:CWErrorBadRequest message:@"submit must be a boolean" start:start];
    }
    submit = [submitValue boolValue];
  }

  NSString *errorCode = nil;
  NSString *message = nil;
  if (![CWPasteboard pasteText:text submit:submit errorCode:&errorCode message:&message]) {
    return [self failureWithCode:errorCode ?: CWErrorInternal message:message start:start];
  }
  return [CWResponse successWithData:@{
    @"pasted" : @YES,
    @"submitted" : @(submit),
  } elapsedMs:[CWResponse elapsedMsSince:start]];
}

+ (id<FBResponsePayload>)handleSourceWithStart:(CFTimeInterval)start
{
  return [self failureWithCode:CWErrorUnsupported
                       message:@"source is not implemented"
                         start:start];
}

+ (id<FBResponsePayload>)notFoundWithStart:(CFTimeInterval)start
{
  return [CWResponse failureWithCode:CWErrorNotFound
                             message:@"Unknown CW endpoint"
                           elapsedMs:[CWResponse elapsedMsSince:start]
                          statusCode:kHTTPStatusCodeNotFound];
}

@end
