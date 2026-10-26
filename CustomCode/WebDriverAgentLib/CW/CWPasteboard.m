#import "CWPasteboard.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import <WebDriverAgentLib/FBAlert.h>
#import <WebDriverAgentLib/FBSession.h>
#import <WebDriverAgentLib/XCUIApplication+FBHelpers.h>

#import "CWError.h"
#import "CWGeometry.h"
#import "CWKeyboard.h"
#import "CWSessionManager.h"
#import "XCUIApplication+FBTouchAction.h"

static void CWPasteboardOnMain(dispatch_block_t block)
{
  if (NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_sync(dispatch_get_main_queue(), block);
}

static NSArray *CWLongPressActions(CGPoint point, NSInteger durationMs)
{
  return @[
    @{
      @"id" : @"finger",
      @"type" : @"pointer",
      @"parameters" : @{@"pointerType" : @"touch"},
      @"actions" : @[
        @{@"type" : @"pointerMove", @"x" : @((NSInteger)point.x), @"y" : @((NSInteger)point.y)},
        @{@"type" : @"pointerDown", @"button" : @0},
        @{@"type" : @"pause", @"duration" : @(durationMs)},
        @{@"type" : @"pointerUp", @"button" : @0},
      ],
    },
  ];
}

static BOOL CWIsASCIIString(NSString *text)
{
  for (NSUInteger index = 0; index < text.length; index++) {
    unichar character = [text characterAtIndex:index];
    if (character < 0x20 || character > 0x7E) {
      return NO;
    }
  }
  return YES;
}

@implementation CWPasteboard

+ (nullable XCUIElement *)pasteMenuItemForApplication:(XCUIApplication *)application
                                             timeout:(NSTimeInterval)timeout
{
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label IN %@",
                            @[ @"Paste", @"粘贴", @"PASTE" ]];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([deadline timeIntervalSinceNow] > 0) {
    XCUIElement *item = [[application descendantsMatchingType:XCUIElementTypeAny]
                         matchingPredicate:predicate].firstMatch;
    if (item.exists) {
      return item;
    }
    XCUIApplication *systemApplication = XCUIApplication.fb_systemApplication;
    if (nil != systemApplication) {
      item = [[systemApplication descendantsMatchingType:XCUIElementTypeAny]
              matchingPredicate:predicate].firstMatch;
      if (item.exists) {
        return item;
      }
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  return nil;
}

+ (void)acceptPastePermissionForApplication:(XCUIApplication *)application
{
  NSArray<XCUIApplication *> *hosts = @[ application ];
  XCUIApplication *systemApplication = XCUIApplication.fb_systemApplication;
  if (nil != systemApplication) {
    hosts = [hosts arrayByAddingObject:systemApplication];
  }
  for (XCUIApplication *host in hosts) {
    @try {
      FBAlert *alert = [FBAlert alertWithApplication:host];
      if (![alert isPresent]) {
        continue;
      }
      for (NSString *label in alert.buttonLabels) {
        NSString *lowercaseLabel = label.lowercaseString;
        if ([lowercaseLabel containsString:@"don't"]
            || [lowercaseLabel containsString:@"don’t"]
            || [label containsString:@"不允许"]) {
          continue;
        }
        if ([lowercaseLabel containsString:@"allow"] || [label containsString:@"允许"]) {
          [alert clickAlertButton:label];
          return;
        }
      }
    } @catch (NSException *exception) {
    }
  }
}

+ (BOOL)pasteText:(NSString *)text
           submit:(BOOL)submit
        errorCode:(NSString *_Nonnull *_Nonnull)errorCode
          message:(NSString *_Nonnull *_Nonnull)message
{
  __block NSString *failure = nil;
  __block BOOL didPaste = NO;
  __block XCUIApplication *targetApplication = nil;

  CWPasteboardOnMain(^{
    UIPasteboard.generalPasteboard.string = text;
    NSError *sessionError = nil;
    XCUIApplication *application = [CWSessionManager.shared applicationWithError:&sessionError];
    if (nil == application) {
      failure = sessionError.localizedDescription ?: @"XCTest session lost";
      return;
    }
    targetApplication = application;
    XCUIElement *focused = [application fb_activeElement];
    if (nil == focused) {
      failure = @"No focused text input was found";
      return;
    }
    CGRect frame = focused.frame;
    if (CGRectIsEmpty(frame)) {
      failure = @"The focused text input has an empty frame";
      return;
    }
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    FBSession *session = FBSession.activeSession;
    NSError *eventError = nil;
    if (![application fb_performW3CActions:CWLongPressActions(center, 800)
                              elementCache:session.elementCache
                                     error:&eventError]) {
      failure = eventError.localizedDescription ?: @"Unable to open the paste menu";
      return;
    }
    XCUIElement *pasteItem = [self pasteMenuItemForApplication:application timeout:5.0];
    if (nil == pasteItem) {
      if (CWIsASCIIString(text)) {
        NSString *typeErrorCode = nil;
        NSString *typeMessage = nil;
        if ([CWKeyboard typeText:text errorCode:&typeErrorCode message:&typeMessage]) {
          didPaste = YES;
          return;
        }
        failure = typeMessage ?: @"Unable to type the pasteboard text";
        return;
      }
      failure = @"The paste menu item was not found";
      return;
    }
    @try {
      [pasteItem tap];
    } @catch (NSException *exception) {
      failure = exception.reason ?: @"Unable to tap the paste menu item";
      return;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    [self acceptPastePermissionForApplication:application];
    didPaste = YES;
  });

  if (!didPaste) {
    *errorCode = CWErrorInternal;
    *message = failure ?: @"Unable to paste text";
    return NO;
  }

  if (submit) {
    NSString *keyErrorCode = nil;
    NSString *keyMessage = nil;
    if (![CWKeyboard pressKey:@"return"
                  application:targetApplication
                    errorCode:&keyErrorCode
                      message:&keyMessage]) {
      *errorCode = keyErrorCode ?: CWErrorInternal;
      *message = keyMessage ?: @"Unable to submit the pasted text";
      return NO;
    }
  }

  *errorCode = CWErrorOK;
  *message = @"";
  return YES;
}

@end
