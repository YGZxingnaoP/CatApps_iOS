#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWGeometry : NSObject

+ (CGSize)pixelSize;
+ (CGSize)pointSize;
+ (CGFloat)scale;
+ (BOOL)pixelSizeIsMeasured;
+ (NSArray<NSString *> *)warnings;
+ (BOOL)isPortrait;
+ (CGFloat)safeAreaTop;
+ (CGFloat)safeAreaBottom;
+ (NSDictionary *)deviceDictionary;
+ (BOOL)isValidPixelX:(NSInteger)x y:(NSInteger)y;
+ (BOOL)isValidPixelRect:(CGRect)rect;
+ (CGPoint)pointFromPixelX:(NSInteger)x y:(NSInteger)y;
+ (CGPoint)pointFromPixelPoint:(CGPoint)pixelPoint;
+ (CGSize)pointSizeFromPixelSize:(CGSize)pixelSize;

@end

NS_ASSUME_NONNULL_END
