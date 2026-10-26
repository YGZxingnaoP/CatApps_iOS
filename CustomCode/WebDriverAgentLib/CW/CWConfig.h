#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWConfig : NSObject

+ (nullable NSString *)token;
+ (BOOL)cwOnly;
+ (BOOL)ocrDisabled;
+ (NSInteger)tapGapMs;
+ (NSString *)runnerVersion;
+ (NSString *)runnerBuild;
+ (NSString *)appName;

@end

NS_ASSUME_NONNULL_END
