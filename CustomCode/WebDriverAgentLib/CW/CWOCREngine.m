#import "CWOCREngine.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <math.h>

#import "CWError.h"
#import "CWGeometry.h"

@implementation CWOCRResult
@end

@interface CWOCREngine ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) NSUInteger lastKey;
@property (nonatomic, assign) NSTimeInterval lastTime;
@property (nonatomic, strong, nullable) CWOCRResult *lastResult;
@end

@implementation CWOCREngine

+ (instancetype)shared
{
  static CWOCREngine *engine;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    engine = [CWOCREngine new];
  });
  return engine;
}

- (instancetype)init
{
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.catpaws.ocr", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (CGSize)imageSizeForData:(NSData *)data
{
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (NULL == source) {
    return CGSizeZero;
  }
  NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
  CFRelease(source);
  return CGSizeMake([properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue],
                    [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue]);
}

- (nullable CWOCRResult *)recognizeImageData:(NSData *)data
                                     region:(nullable NSArray<NSNumber *> *)region
                                  languages:(nullable NSArray<NSString *> *)languages
                                  errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                    message:(NSString *_Nonnull *_Nonnull)message
{
  __block CWOCRResult *result = nil;
  __block NSString *failure = nil;
  __block NSString *failureCode = nil;
  dispatch_sync(self.queue, ^{
    if (nil == NSClassFromString(@"VNRecognizeTextRequest")) {
      failureCode = CWErrorUnsupported;
      failure = @"Vision OCR is not available";
      return;
    }
    CGSize imageSize = [self imageSizeForData:data];
    if (imageSize.width <= 0 || imageSize.height <= 0) {
      failureCode = CWErrorInternal;
      failure = @"Unable to decode the screenshot";
      return;
    }

    CGRect crop = CGRectMake(0, 0, imageSize.width, imageSize.height);
    if (nil != region) {
      if (region.count != 4) {
        failureCode = CWErrorBadRequest;
        failure = @"region must be [x, y, w, h]";
        return;
      }
      crop = CGRectMake(region[0].doubleValue,
                        region[1].doubleValue,
                        region[2].doubleValue,
                        region[3].doubleValue);
    }
    if (![CWGeometry isValidPixelRect:crop]) {
      failureCode = CWErrorOutOfRange;
      failure = @"The OCR region is outside the screen";
      return;
    }

    NSUInteger key = data.hash;
    key = key * 31 + (NSUInteger)CGRectGetMinX(crop);
    key = key * 31 + (NSUInteger)CGRectGetMinY(crop);
    key = key * 31 + (NSUInteger)CGRectGetWidth(crop);
    key = key * 31 + (NSUInteger)CGRectGetHeight(crop);
    key = key * 31 + languages.hash;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (key == self.lastKey && nil != self.lastResult && now - self.lastTime < 0.3) {
      result = self.lastResult;
      return;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (NULL == source) {
      failureCode = CWErrorInternal;
      failure = @"Unable to decode the screenshot";
      return;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (NULL == image) {
      failureCode = CWErrorInternal;
      failure = @"Unable to decode the screenshot";
      return;
    }
    CGImageRef cropped = CGImageCreateWithImageInRect(image, crop);
    CGImageRelease(image);
    if (NULL == cropped) {
      failureCode = CWErrorInternal;
      failure = @"Unable to crop the screenshot";
      return;
    }

    VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.recognitionLanguages = languages.count > 0 ? languages : @[ @"zh-Hans", @"en-US" ];
    request.usesLanguageCorrection = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cropped
                                                                       orientation:kCGImagePropertyOrientationUp
                                                                           options:@{}];
    NSError *error = nil;
    BOOL performed = [handler performRequests:@[ request ] error:&error];
    CGImageRelease(cropped);
    if (!performed) {
      failureCode = CWErrorInternal;
      failure = error.localizedDescription ?: @"Vision OCR failed";
      return;
    }

    NSMutableArray<NSDictionary *> *texts = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
      VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
      if (nil == candidate || candidate.string.length == 0) {
        continue;
      }
      CGRect box = observation.boundingBox;
      CGFloat x = box.origin.x * crop.size.width + crop.origin.x;
      CGFloat y = (1.0 - box.origin.y - box.size.height) * crop.size.height + crop.origin.y;
      CGFloat width = box.size.width * crop.size.width;
      CGFloat height = box.size.height * crop.size.height;
      [texts addObject:@{
        @"text" : candidate.string,
        @"box" : @[ @((NSInteger)llround(x)), @((NSInteger)llround(y)),
                    @((NSInteger)llround(width)), @((NSInteger)llround(height)) ],
        @"confidence" : @(candidate.confidence),
      }];
    }

    CWOCRResult *ocrResult = [CWOCRResult new];
    ocrResult.imageSize = @[ @((NSInteger)llround(imageSize.width)),
                             @((NSInteger)llround(imageSize.height)) ];
    ocrResult.texts = texts.copy;
    result = ocrResult;
    self.lastKey = key;
    self.lastTime = now;
    self.lastResult = ocrResult;
  });

  if (nil == result) {
    *errorCode = failureCode ?: CWErrorInternal;
    *message = failure ?: @"Vision OCR failed";
    return nil;
  }
  *errorCode = CWErrorOK;
  *message = @"";
  return result;
}

@end
