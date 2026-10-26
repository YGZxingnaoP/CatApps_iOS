#import "CWActionStep.h"

#import "CWError.h"
#import "CWGeometry.h"

@interface CWActionStep ()
@property (nonatomic, copy, readwrite) NSString *action;
@property (nonatomic, assign, readwrite) NSInteger index;
@property (nonatomic, assign, readwrite) NSInteger x;
@property (nonatomic, assign, readwrite) NSInteger y;
@property (nonatomic, assign, readwrite) NSInteger count;
@property (nonatomic, assign, readwrite) NSInteger durationMs;
@property (nonatomic, assign, readwrite) NSInteger holdMs;
@property (nonatomic, assign, readwrite) CGPoint fromPixel;
@property (nonatomic, assign, readwrite) CGPoint toPixel;
@property (nonatomic, assign, readwrite) double scale;
@property (nonatomic, copy, readwrite) NSString *text;
@property (nonatomic, copy, readwrite) NSString *key;
@property (nonatomic, copy, readwrite) NSString *bundleId;

+ (BOOL)readPointFrom:(NSDictionary *)dictionary
                  key:(NSString *)firstKey
            secondKey:(NSString *)secondKey
                 step:(CWActionStep *)step
              message:(NSString *_Nonnull *_Nonnull)message
            errorCode:(NSString *_Nonnull *_Nonnull)errorCode;

+ (BOOL)readOptionalDurationFrom:(NSDictionary *)dictionary
                            step:(CWActionStep *)step
                      defaultValue:(NSInteger)defaultValue
                          minValue:(NSInteger)minValue
                          maxValue:(NSInteger)maxValue
                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                           message:(NSString *_Nonnull *_Nonnull)message;

@end

static BOOL CWIntegerFromValue(id value, NSInteger *result, NSString **message)
{
  if (![value isKindOfClass:NSNumber.class]) {
    *message = @"Expected an integer";
    return NO;
  }
  double number = [(NSNumber *)value doubleValue];
  if (!isfinite(number) || number != floor(number)) {
    *message = @"Expected an integer";
    return NO;
  }
  *result = (NSInteger)number;
  return YES;
}

static BOOL CWDoubleFromValue(id value, double *result, NSString **message)
{
  if (![value isKindOfClass:NSNumber.class]) {
    *message = @"Expected a number";
    return NO;
  }
  double number = [(NSNumber *)value doubleValue];
  if (!isfinite(number)) {
    *message = @"Expected a finite number";
    return NO;
  }
  *result = number;
  return YES;
}

static BOOL CWPointFromValue(id value, CGPoint *result, NSString **message)
{
  if (![value isKindOfClass:NSArray.class] || [(NSArray *)value count] != 2) {
    *message = @"Expected [x, y]";
    return NO;
  }
  NSInteger x = 0;
  NSInteger y = 0;
  if (!CWIntegerFromValue(((NSArray *)value)[0], &x, message)
      || !CWIntegerFromValue(((NSArray *)value)[1], &y, message)) {
    return NO;
  }
  *result = CGPointMake(x, y);
  return YES;
}

static BOOL CWIsASCII(NSString *text)
{
  for (NSUInteger index = 0; index < text.length; index++) {
    unichar character = [text characterAtIndex:index];
    if (character < 0x20 || character > 0x7E) {
      return NO;
    }
  }
  return YES;
}

@implementation CWActionStep

+ (nullable instancetype)stepWithDictionary:(NSDictionary *)dictionary
                                     index:(NSInteger)index
                                 errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                   message:(NSString *_Nonnull *_Nonnull)message
{
  if (![dictionary isKindOfClass:NSDictionary.class]) {
    *errorCode = CWErrorBadRequest;
    *message = [NSString stringWithFormat:@"steps[%ld] must be an object", (long)index];
    return nil;
  }

  id actionValue = dictionary[@"action"];
  if (![actionValue isKindOfClass:NSString.class] || [(NSString *)actionValue length] == 0) {
    *errorCode = CWErrorBadRequest;
    *message = [NSString stringWithFormat:@"steps[%ld].action is required", (long)index];
    return nil;
  }

  CWActionStep *step = [CWActionStep new];
  step.index = index;
  step.action = [(NSString *)actionValue lowercaseString];
  step.count = 1;
  step.durationMs = 0;
  step.holdMs = 0;
  step.text = @"";
  step.key = @"";
  step.bundleId = @"";

  NSString *action = step.action;
  if ([action isEqualToString:@"tap"]) {
    if (![self readPointFrom:dictionary key:@"x" secondKey:@"y" step:step message:message errorCode:errorCode]) {
      return nil;
    }
    id countValue = dictionary[@"count"];
    if (nil != countValue) {
      NSInteger count = 0;
      if (!CWIntegerFromValue(countValue, &count, message)) {
        *errorCode = CWErrorBadRequest;
        *message = [NSString stringWithFormat:@"steps[%ld].count must be an integer", (long)index];
        return nil;
      }
      if (count < 1 || count > 3) {
        *errorCode = CWErrorBadRequest;
        *message = [NSString stringWithFormat:@"steps[%ld].count must be in 1..3", (long)index];
        return nil;
      }
      step.count = count;
    }
    return step;
  }

  if ([action isEqualToString:@"long_press"]) {
    if (![self readPointFrom:dictionary key:@"x" secondKey:@"y" step:step message:message errorCode:errorCode]) {
      return nil;
    }
    if (![self readOptionalDurationFrom:dictionary
                                   step:step
                             defaultValue:800
                                 minValue:200
                                 maxValue:5000
                                errorCode:errorCode
                                  message:message]) {
      return nil;
    }
    return step;
  }

  if ([action isEqualToString:@"swipe"]) {
    CGPoint from = CGPointZero;
    CGPoint to = CGPointZero;
    if (!CWPointFromValue(dictionary[@"from"], &from, message)) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].from must be [x, y]", (long)index];
      return nil;
    }
    if (!CWPointFromValue(dictionary[@"to"], &to, message)) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].to must be [x, y]", (long)index];
      return nil;
    }
    if (![CWGeometry isValidPixelX:(NSInteger)from.x y:(NSInteger)from.y]
        || ![CWGeometry isValidPixelX:(NSInteger)to.x y:(NSInteger)to.y]) {
      *errorCode = CWErrorOutOfRange;
      *message = [NSString stringWithFormat:@"steps[%ld] coordinates are outside the screen", (long)index];
      return nil;
    }
    step.fromPixel = from;
    step.toPixel = to;
    if (![self readOptionalDurationFrom:dictionary
                                   step:step
                             defaultValue:300
                                 minValue:100
                                 maxValue:2000
                                errorCode:errorCode
                                  message:message]) {
      return nil;
    }
    return step;
  }

  if ([action isEqualToString:@"pinch"]) {
    if (![self readPointFrom:dictionary key:@"x" secondKey:@"y" step:step message:message errorCode:errorCode]) {
      return nil;
    }
    double scale = 0;
    if (!CWDoubleFromValue(dictionary[@"scale"], &scale, message)) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].scale must be a number", (long)index];
      return nil;
    }
    step.scale = scale;
    if (step.scale < 0.2 || step.scale > 5.0) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].scale must be in 0.2..5.0", (long)index];
      return nil;
    }
    if (![self readOptionalDurationFrom:dictionary
                                   step:step
                             defaultValue:400
                                 minValue:100
                                 maxValue:2000
                                errorCode:errorCode
                                  message:message]) {
      return nil;
    }
    return step;
  }

  if ([action isEqualToString:@"type_text"]) {
    id textValue = dictionary[@"text"];
    if (![textValue isKindOfClass:NSString.class]) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].text is required", (long)index];
      return nil;
    }
    NSString *text = (NSString *)textValue;
    if (text.length > 4096 || !CWIsASCII(text)) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].text must be ASCII and at most 4096 characters", (long)index];
      return nil;
    }
    step.text = text;
    return step;
  }

  if ([action isEqualToString:@"paste_text"]) {
    id textValue = dictionary[@"text"];
    if (![textValue isKindOfClass:NSString.class]) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].text is required", (long)index];
      return nil;
    }
    NSString *text = (NSString *)textValue;
    if (text.length > 16384) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].text is too long", (long)index];
      return nil;
    }
    step.text = text;
    return step;
  }

  if ([action isEqualToString:@"press_key"]) {
    id keyValue = dictionary[@"key"];
    if (![keyValue isKindOfClass:NSString.class]) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].key is required", (long)index];
      return nil;
    }
    NSString *key = [(NSString *)keyValue lowercaseString];
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[ @"home", @"volume_up", @"volume_down", @"delete", @"return" ]];
    if (![allowed containsObject:key]) {
      *errorCode = CWErrorUnsupported;
      *message = [NSString stringWithFormat:@"steps[%ld].key %@ is unsupported", (long)index, key];
      return nil;
    }
    step.key = key;
    return step;
  }

  if ([action isEqualToString:@"launch_app"]
      || [action isEqualToString:@"activate_app"]
      || [action isEqualToString:@"terminate_app"]) {
    id bundleValue = dictionary[@"bundle_id"];
    if (![bundleValue isKindOfClass:NSString.class] || [(NSString *)bundleValue length] == 0) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].bundle_id is required", (long)index];
      return nil;
    }
    NSString *bundleId = (NSString *)bundleValue;
    if (bundleId.length > 255) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].bundle_id is too long", (long)index];
      return nil;
    }
    step.bundleId = bundleId;
    return step;
  }

  if ([action isEqualToString:@"drag"]) {
    CGPoint from = CGPointZero;
    CGPoint to = CGPointZero;
    if (!CWPointFromValue(dictionary[@"from"], &from, message)) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].from must be [x, y]", (long)index];
      return nil;
    }
    if (!CWPointFromValue(dictionary[@"to"], &to, message)) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].to must be [x, y]", (long)index];
      return nil;
    }
    if (![CWGeometry isValidPixelX:(NSInteger)from.x y:(NSInteger)from.y]
        || ![CWGeometry isValidPixelX:(NSInteger)to.x y:(NSInteger)to.y]) {
      *errorCode = CWErrorOutOfRange;
      *message = [NSString stringWithFormat:@"steps[%ld] coordinates are outside the screen", (long)index];
      return nil;
    }
    step.fromPixel = from;
    step.toPixel = to;
    if (![self readOptionalDurationFrom:dictionary
                                   step:step
                             defaultValue:400
                                 minValue:100
                                 maxValue:5000
                                errorCode:errorCode
                                  message:message]) {
      return nil;
    }
    id holdValue = dictionary[@"hold_ms"];
    NSInteger hold = 300;
    if (nil != holdValue && !CWIntegerFromValue(holdValue, &hold, message)) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].hold_ms must be an integer", (long)index];
      return nil;
    }
    if (hold < 0 || hold > 5000) {
      *errorCode = CWErrorBadRequest;
      *message = [NSString stringWithFormat:@"steps[%ld].hold_ms must be in 0..5000", (long)index];
      return nil;
    }
    step.holdMs = hold;
    return step;
  }
  if ([action isEqualToString:@"wait"]) {
    if (![self readOptionalDurationFrom:dictionary
                                   step:step
                             defaultValue:0
                                 minValue:0
                                 maxValue:10000
                                errorCode:errorCode
                                  message:message]) {
      return nil;
    }
    return step;
  }

  *errorCode = CWErrorBadRequest;
  *message = [NSString stringWithFormat:@"steps[%ld].action %@ is unsupported", (long)index, action];
  return nil;
}

+ (BOOL)readPointFrom:(NSDictionary *)dictionary
                  key:(NSString *)firstKey
            secondKey:(NSString *)secondKey
                 step:(CWActionStep *)step
              message:(NSString *_Nonnull *_Nonnull)message
            errorCode:(NSString *_Nonnull *_Nonnull)errorCode
{
  NSInteger x = 0;
  NSInteger y = 0;
  if (!CWIntegerFromValue(dictionary[firstKey], &x, message)) {
    *errorCode = CWErrorBadRequest;
    *message = [NSString stringWithFormat:@"steps[%ld].%@ must be an integer", (long)step.index, firstKey];
    return NO;
  }
  if (!CWIntegerFromValue(dictionary[secondKey], &y, message)) {
    *errorCode = CWErrorBadRequest;
    *message = [NSString stringWithFormat:@"steps[%ld].%@ must be an integer", (long)step.index, secondKey];
    return NO;
  }
  if (![CWGeometry isValidPixelX:x y:y]) {
    *errorCode = CWErrorOutOfRange;
    CGSize pixel = [CWGeometry pixelSize];
    *message = [NSString stringWithFormat:@"steps[%ld] x=%ld,y=%ld is outside %ldx%ld",
                (long)step.index, (long)x, (long)y, (long)pixel.width, (long)pixel.height];
    return NO;
  }
  step.x = x;
  step.y = y;
  return YES;
}

+ (BOOL)readOptionalDurationFrom:(NSDictionary *)dictionary
                            step:(CWActionStep *)step
                      defaultValue:(NSInteger)defaultValue
                          minValue:(NSInteger)minValue
                          maxValue:(NSInteger)maxValue
                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                           message:(NSString *_Nonnull *_Nonnull)message
{
  id durationValue = dictionary[@"duration_ms"];
  NSInteger duration = defaultValue;
  if (nil != durationValue && !CWIntegerFromValue(durationValue, &duration, message)) {
    *errorCode = CWErrorBadRequest;
    *message = [NSString stringWithFormat:@"steps[%ld].duration_ms must be an integer", (long)step.index];
    return NO;
  }
  if (duration < minValue || duration > maxValue) {
    *errorCode = CWErrorBadRequest;
    *message = [NSString stringWithFormat:@"steps[%ld].duration_ms must be in %ld..%ld",
                (long)step.index, (long)minValue, (long)maxValue];
    return NO;
  }
  step.durationMs = duration;
  return YES;
}

@end
