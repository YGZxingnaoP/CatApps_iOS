#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWAuth : NSObject

+ (BOOL)isAuthorizedForHeaders:(nullable NSDictionary<NSString *, NSString *> *)headers;

@end

NS_ASSUME_NONNULL_END
