#import <Foundation/Foundation.h>

@class XCUIApplication;

NS_ASSUME_NONNULL_BEGIN

@interface CWSessionManager : NSObject

+ (instancetype)shared;
- (BOOL)hasSession;
- (BOOL)ensureSessionWithError:(NSError **)error;
- (BOOL)recreateSessionWithError:(NSError **)error;
- (void)releaseSession;
- (nullable XCUIApplication *)activeApplication;
- (nullable XCUIApplication *)applicationWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
