#import "CWAuth.h"

#import "CWConfig.h"

static BOOL CWConstantTimeEqual(NSString *left, NSString *right)
{
  NSData *leftData = [left dataUsingEncoding:NSUTF8StringEncoding];
  NSData *rightData = [right dataUsingEncoding:NSUTF8StringEncoding];
  if (leftData.length != rightData.length) {
    return NO;
  }
  const uint8_t *leftBytes = leftData.bytes;
  const uint8_t *rightBytes = rightData.bytes;
  uint8_t difference = 0;
  for (NSUInteger index = 0; index < leftData.length; index++) {
    difference |= (uint8_t)(leftBytes[index] ^ rightBytes[index]);
  }
  return difference == 0;
}

@implementation CWAuth

+ (BOOL)isAuthorizedForHeaders:(nullable NSDictionary<NSString *, NSString *> *)headers
{
  NSString *expected = [CWConfig token];
  if (nil == expected || expected.length == 0) {
    return YES;
  }
  NSString *authorization = headers[@"authorization"];
  if (![authorization isKindOfClass:NSString.class]) {
    return NO;
  }
  NSRange space = [authorization rangeOfString:@" "];
  if (space.location == NSNotFound) {
    return NO;
  }
  NSString *scheme = [authorization substringToIndex:space.location];
  if ([scheme caseInsensitiveCompare:@"Bearer"] != NSOrderedSame) {
    return NO;
  }
  NSString *token = [[authorization substringFromIndex:space.location + 1]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return CWConstantTimeEqual(token, expected);
}

@end
