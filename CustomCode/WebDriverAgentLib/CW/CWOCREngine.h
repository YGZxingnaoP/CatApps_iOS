#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWOCRResult : NSObject

@property (nonatomic, copy) NSArray<NSNumber *> *imageSize;
@property (nonatomic, copy) NSArray<NSDictionary *> *texts;

@end

@interface CWOCREngine : NSObject

+ (instancetype)shared;
- (nullable CWOCRResult *)recognizeImageData:(NSData *)data
                                     region:(nullable NSArray<NSNumber *> *)region
                                  languages:(nullable NSArray<NSString *> *)languages
                                  errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                    message:(NSString *_Nonnull *_Nonnull)message;

@end

NS_ASSUME_NONNULL_END
