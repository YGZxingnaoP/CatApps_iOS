#import "CWConfig.h"

@implementation CWConfig

+ (nullable id)plistValueForKey:(NSString *)key
{
  id value = [NSBundle.mainBundle objectForInfoDictionaryKey:key];
  if (nil != value) {
    return value;
  }
  Class testClass = NSClassFromString(@"UITestingUITests");
  if (nil != testClass) {
    value = [[NSBundle bundleForClass:testClass] objectForInfoDictionaryKey:key];
    if (nil != value) {
      return value;
    }
  }
  value = [[NSBundle bundleForClass:self.class] objectForInfoDictionaryKey:key];
  if (nil != value) {
    return value;
  }
  NSArray<NSBundle *> *bundles = [NSBundle.allBundles arrayByAddingObjectsFromArray:NSBundle.allFrameworks];
  for (NSBundle *bundle in bundles) {
    value = [bundle objectForInfoDictionaryKey:key];
    if (nil != value) {
      return value;
    }
  }
  return nil;
}

+ (nullable NSDictionary *)fileConfig
{
  NSArray<NSString *> *directories = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                         NSUserDomainMask,
                                                                         YES);
  NSString *documents = directories.firstObject;
  if (nil == documents) {
    return nil;
  }
  NSString *path = [documents stringByAppendingPathComponent:@"cw_config.plist"];
  return [NSDictionary dictionaryWithContentsOfFile:path];
}

+ (nullable id)configValueForKey:(NSString *)key
{
  id value = [self plistValueForKey:key];
  if ([value isKindOfClass:NSString.class]) {
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
      value = nil;
    }
  }
  if (nil != value) {
    return value;
  }
  return [self fileConfig][key];
}

+ (BOOL)boolValueForKey:(NSString *)key
{
  id value = [self configValueForKey:key];
  if ([value isKindOfClass:NSNumber.class]) {
    return [(NSNumber *)value boolValue];
  }
  if ([value isKindOfClass:NSString.class]) {
    return [(NSString *)value boolValue];
  }
  return NO;
}

+ (nullable NSString *)stringValueForKey:(NSString *)key
{
  id value = [self configValueForKey:key];
  if (![value isKindOfClass:NSString.class]) {
    return nil;
  }
  NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return string.length > 0 ? string : nil;
}

+ (nullable NSString *)token
{
  NSString *value = NSProcessInfo.processInfo.environment[@"CW_TOKEN"];
  if (nil != value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? trimmed : nil;
  }
  return [self stringValueForKey:@"CWToken"];
}

+ (BOOL)cwOnly
{
  NSString *value = NSProcessInfo.processInfo.environment[@"CW_ONLY"];
  if (nil != value && value.length > 0) {
    return value.boolValue;
  }
  return [self boolValueForKey:@"CWOnly"];
}

+ (BOOL)ocrDisabled
{
  NSString *value = NSProcessInfo.processInfo.environment[@"CW_OCR_DISABLED"];
  if (nil != value && value.length > 0) {
    return value.boolValue;
  }
  return [self boolValueForKey:@"CWOCRDisabled"];
}

+ (NSInteger)tapGapMs
{
  NSString *value = NSProcessInfo.processInfo.environment[@"CW_TAP_GAP_MS"];
  if (nil == value || value.length == 0) {
    value = [self stringValueForKey:@"CWTapGapMs"];
  }
  if (nil == value || value.length == 0) {
    return 90;
  }
  NSInteger gap = value.integerValue;
  return (NSInteger)MAX(30, MIN(1000, gap));
}

+ (NSString *)runnerVersion
{
  id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  return [value isKindOfClass:NSString.class] ? (NSString *)value : @"1.0.0";
}

+ (NSString *)runnerBuild
{
  id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
  return [value isKindOfClass:NSString.class] ? (NSString *)value : @"1";
}

+ (NSString *)appName
{
  return @"CatPawRunner";
}

@end
