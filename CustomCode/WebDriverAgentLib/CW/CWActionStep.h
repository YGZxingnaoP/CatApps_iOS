#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWActionStep : NSObject

@property (nonatomic, copy, readonly) NSString *action;
@property (nonatomic, assign, readonly) NSInteger index;
@property (nonatomic, assign, readonly) NSInteger x;
@property (nonatomic, assign, readonly) NSInteger y;
@property (nonatomic, assign, readonly) NSInteger count;
@property (nonatomic, assign, readonly) NSInteger durationMs;
@property (nonatomic, assign, readonly) NSInteger holdMs;
@property (nonatomic, assign, readonly) CGPoint fromPixel;
@property (nonatomic, assign, readonly) CGPoint toPixel;
@property (nonatomic, assign, readonly) double scale;
@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, copy, readonly) NSString *key;
@property (nonatomic, copy, readonly) NSString *bundleId;

+ (nullable instancetype)stepWithDictionary:(NSDictionary *)dictionary
                                     index:(NSInteger)index
                                 errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                   message:(NSString *_Nonnull *_Nonnull)message;

@end

NS_ASSUME_NONNULL_END
