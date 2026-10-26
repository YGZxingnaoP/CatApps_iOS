#import <Foundation/Foundation.h>

@class XCUIApplication;

NS_ASSUME_NONNULL_BEGIN

@interface CWKeyboard : NSObject

+ (BOOL)typeText:(NSString *)text
       errorCode:(NSString *_Nonnull *_Nonnull)errorCode
         message:(NSString *_Nonnull *_Nonnull)message;

+ (BOOL)pressKey:(NSString *)key
     application:(nullable XCUIApplication *)application
       errorCode:(NSString *_Nonnull *_Nonnull)errorCode
         message:(NSString *_Nonnull *_Nonnull)message;

@end

NS_ASSUME_NONNULL_END
