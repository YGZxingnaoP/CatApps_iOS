#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWScreenshotResult : NSObject

@property (nonatomic, copy) NSData *data;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, copy) NSString *contentType;

@end

@interface CWScreenshot : NSObject

+ (nullable CWScreenshotResult *)captureWithFormat:(NSString *)format
                                           maxEdge:(nullable NSNumber *)maxEdge
                                           quality:(NSInteger)quality
                                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                           message:(NSString *_Nonnull *_Nonnull)message;

+ (nullable CWScreenshotResult *)captureWithFormat:(NSString *)format
                                           maxEdge:(nullable NSNumber *)maxEdge
                                           quality:(NSInteger)quality
                                            region:(nullable NSArray<NSNumber *> *)region
                                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                           message:(NSString *_Nonnull *_Nonnull)message;

+ (CGSize)lastPixelSize;
+ (CGSize)imageSizeForData:(nullable NSData *)data;

@end

NS_ASSUME_NONNULL_END
