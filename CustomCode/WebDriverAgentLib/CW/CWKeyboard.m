#import "CWKeyboard.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import <WebDriverAgentLib/FBConfiguration.h>
#import <WebDriverAgentLib/XCUIDevice+FBHelpers.h>

#import "CWError.h"
#import "CWSessionManager.h"
#import "XCUIElement+FBTyping.h"

static void CWKeyboardOnMain(dispatch_block_t block)
{
  if (NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_sync(dispatch_get_main_queue(), block);
}

@implementation CWKeyboard

+ (BOOL)typeText:(NSString *)text
       errorCode:(NSString *_Nonnull *_Nonnull)errorCode
         message:(NSString *_Nonnull *_Nonnull)message
{
  __block BOOL success = NO;
  __block NSError *error = nil;
  CWKeyboardOnMain(^{
    success = FBTypeText(text, FBConfiguration.sharedInstance.maxTypingFrequency, &error);
  });
  if (!success) {
    *errorCode = CWErrorInternal;
    *message = error.localizedDescription ?: @"Unable to type text";
    return NO;
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

+ (BOOL)pressKey:(NSString *)key
     application:(nullable XCUIApplication *)application
       errorCode:(NSString *_Nonnull *_Nonnull)errorCode
         message:(NSString *_Nonnull *_Nonnull)message
{
  NSString *normalized = key.lowercaseString;
  if ([normalized isEqualToString:@"home"]
      || [normalized isEqualToString:@"volume_up"]
      || [normalized isEqualToString:@"volume_down"]) {
    NSString *button = normalized;
    if ([button isEqualToString:@"volume_up"]) {
      button = @"volumeup";
    } else if ([button isEqualToString:@"volume_down"]) {
      button = @"volumedown";
    }
    __block BOOL success = NO;
    __block NSError *error = nil;
    CWKeyboardOnMain(^{
      success = [XCUIDevice.sharedDevice fb_pressButton:button forDuration:nil error:&error];
    });
    if (!success) {
      *errorCode = CWErrorUnsupported;
      *message = error.localizedDescription ?: [NSString stringWithFormat:@"Unsupported key %@", key];
      return NO;
    }
    *errorCode = CWErrorOK;
    *message = @"";
    return YES;
  }

  if (![normalized isEqualToString:@"delete"] && ![normalized isEqualToString:@"return"]) {
    *errorCode = CWErrorUnsupported;
    *message = [NSString stringWithFormat:@"Unsupported key %@", key];
    return NO;
  }

  XCUIApplication *target = application;
  if (nil == target) {
    NSError *error = nil;
    target = [CWSessionManager.shared applicationWithError:&error];
    if (nil == target) {
      *errorCode = CWErrorSessionLost;
      *message = error.localizedDescription ?: @"XCTest session lost";
      return NO;
    }
  }

  NSString *keyValue = [normalized isEqualToString:@"delete"]
    ? XCUIKeyboardKeyDelete
    : XCUIKeyboardKeyReturn;
  if ([target respondsToSelector:@selector(typeKey:modifierFlags:)]) {
    CWKeyboardOnMain(^{
      [target typeKey:keyValue modifierFlags:XCUIKeyModifierNone];
    });
    *errorCode = CWErrorOK;
    *message = @"";
    return YES;
  }

  __block BOOL success = NO;
  __block NSError *error = nil;
  CWKeyboardOnMain(^{
    success = FBTypeText(keyValue, FBConfiguration.sharedInstance.maxTypingFrequency, &error);
  });
  if (!success) {
    *errorCode = CWErrorUnsupported;
    *message = error.localizedDescription ?: [NSString stringWithFormat:@"Unsupported key %@", key];
    return NO;
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

@end
