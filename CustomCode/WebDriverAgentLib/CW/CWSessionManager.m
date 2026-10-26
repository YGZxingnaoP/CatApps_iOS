#import "CWSessionManager.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import <WebDriverAgentLib/FBSession.h>

static NSString *const CWSessionErrorDomain = @"com.catpaws.session";

static void CWRunOnMainSync(dispatch_block_t block)
{
  if (NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_sync(dispatch_get_main_queue(), block);
}

static NSError *CWSessionError(NSString *message)
{
  return [NSError errorWithDomain:CWSessionErrorDomain
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : message ?: @"Session error"}];
}

@implementation CWSessionManager

+ (instancetype)shared
{
  static CWSessionManager *manager;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    manager = [CWSessionManager new];
  });
  return manager;
}

- (BOOL)hasSession
{
  return nil != FBSession.activeSession;
}

- (BOOL)ensureSessionWithError:(NSError **)error
{
  if (nil != FBSession.activeSession) {
    return YES;
  }
  __block NSError *innerError = nil;
  CWRunOnMainSync(^{
    @try {
      [FBSession initWithApplication:nil];
    } @catch (NSException *exception) {
      innerError = CWSessionError(exception.reason ?: @"Unable to create XCTest session");
    }
  });
  if (nil == FBSession.activeSession) {
    if (error) {
      *error = innerError ?: CWSessionError(@"Unable to create XCTest session");
    }
    return NO;
  }
  return YES;
}

- (BOOL)recreateSessionWithError:(NSError **)error
{
  __block NSError *innerError = nil;
  CWRunOnMainSync(^{
    FBSession *session = FBSession.activeSession;
    if (nil != session) {
      @try {
        [session kill];
      } @catch (NSException *exception) {
        innerError = CWSessionError(exception.reason ?: @"Unable to release XCTest session");
      }
    }
  });
  if (nil != innerError) {
    if (error) {
      *error = innerError;
    }
    return NO;
  }
  return [self ensureSessionWithError:error];
}

- (void)releaseSession
{
  CWRunOnMainSync(^{
    FBSession *session = FBSession.activeSession;
    if (nil == session) {
      return;
    }
    @try {
      [session kill];
    } @catch (NSException *exception) {
    }
  });
}

- (nullable XCUIApplication *)activeApplication
{
  FBSession *session = FBSession.activeSession;
  if (nil == session) {
    return nil;
  }
  __block XCUIApplication *application = nil;
  CWRunOnMainSync(^{
    @try {
      application = session.activeApplication;
    } @catch (NSException *exception) {
      application = nil;
    }
  });
  return application;
}

- (nullable XCUIApplication *)applicationWithError:(NSError **)error
{
  NSError *innerError = nil;
  if (![self ensureSessionWithError:&innerError]) {
    if (error) {
      *error = innerError;
    }
    return nil;
  }
  XCUIApplication *application = [self activeApplication];
  if (nil != application) {
    return application;
  }
  if (![self recreateSessionWithError:&innerError]) {
    if (error) {
      *error = innerError;
    }
    return nil;
  }
  application = [self activeApplication];
  if (nil == application && error) {
    *error = CWSessionError(@"XCTest session lost");
  }
  return application;
}

@end
