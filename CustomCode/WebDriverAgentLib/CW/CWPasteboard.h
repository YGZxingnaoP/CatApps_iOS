#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWPasteboard : NSObject

+ (BOOL)pasteText:(NSString *)text
           submit:(BOOL)submit
        errorCode:(NSString *_Nonnull *_Nonnull)errorCode
          message:(NSString *_Nonnull *_Nonnull)message;

@end

NS_ASSUME_NONNULL_END
