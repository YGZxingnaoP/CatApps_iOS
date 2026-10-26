#import "CWScreenshot.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <XCTest/XCTest.h>
#import <math.h>

#import <WebDriverAgentLib/XCUIDevice+FBHelpers.h>

#import "CWError.h"
#import "FBImageProcessor.h"
#import "FBImageUtils.h"

static CGSize CWLastPixelSize;

static void CWScreenshotOnMain(dispatch_block_t block)
{
  if (NSThread.isMainThread) {
    block();
    return;
  }
  dispatch_sync(dispatch_get_main_queue(), block);
}

@implementation CWScreenshotResult
@end

@implementation CWScreenshot

+ (CGSize)imageSizeForData:(NSData *)data
{
  if (data.length == 0) {
    return CGSizeZero;
  }
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (NULL == source) {
    return CGSizeZero;
  }
  NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
  CFRelease(source);
  CGFloat width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
  CGFloat height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
  return CGSizeMake(width, height);
}

+ (CGSize)lastPixelSize
{
  @synchronized (self) {
    return CWLastPixelSize;
  }
}

+ (nullable NSData *)croppedData:(NSData *)data
                          region:(CGRect)region
                          isJPEG:(BOOL)isJPEG
                         quality:(CGFloat)quality
{
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (NULL == source) {
    return nil;
  }
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  if (NULL == image) {
    return nil;
  }
  CGImageRef cropped = CGImageCreateWithImageInRect(image, region);
  CGImageRelease(image);
  if (NULL == cropped) {
    return nil;
  }
  NSMutableData *output = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output,
                                                                      (__bridge CFStringRef)(isJPEG ? UTTypeJPEG.identifier : UTTypePNG.identifier),
                                                                      1,
                                                                      NULL);
  if (NULL == destination) {
    CGImageRelease(cropped);
    return nil;
  }
  NSDictionary *options = isJPEG
    ? @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality) }
    : @{};
  CGImageDestinationAddImage(destination, cropped, (__bridge CFDictionaryRef)options);
  BOOL finished = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(cropped);
  return finished ? output.copy : nil;
}

+ (nullable CWScreenshotResult *)captureWithFormat:(NSString *)format
                                           maxEdge:(nullable NSNumber *)maxEdge
                                           quality:(NSInteger)quality
                                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                           message:(NSString *_Nonnull *_Nonnull)message
{
  return [self captureWithFormat:format
                         maxEdge:maxEdge
                         quality:quality
                          region:nil
                       errorCode:errorCode
                         message:message];
}

+ (nullable CWScreenshotResult *)captureWithFormat:(NSString *)format
                                           maxEdge:(nullable NSNumber *)maxEdge
                                           quality:(NSInteger)quality
                                            region:(nullable NSArray<NSNumber *> *)region
                                         errorCode:(NSString *_Nonnull *_Nonnull)errorCode
                                           message:(NSString *_Nonnull *_Nonnull)message
{
  NSString *normalizedFormat = format.lowercaseString;
  if (normalizedFormat.length == 0) {
    normalizedFormat = @"png";
  }
  if (![normalizedFormat isEqualToString:@"png"] && ![normalizedFormat isEqualToString:@"jpeg"]) {
    *errorCode = CWErrorBadRequest;
    *message = @"format must be png or jpeg";
    return nil;
  }
  if (quality < 1 || quality > 100) {
    quality = 85;
  }
  BOOL isJPEG = [normalizedFormat isEqualToString:@"jpeg"];

  __block NSData *screenshotData = nil;
  __block NSString *captureFailure = nil;
  CWScreenshotOnMain(^{
    NSError *error = nil;
    screenshotData = [XCUIDevice.sharedDevice fb_screenshotWithError:&error];
    if (nil == screenshotData) {
      captureFailure = error.localizedDescription ?: @"Unable to capture the screen";
    }
  });
  if (nil == screenshotData) {
    *errorCode = [XCUIDevice.sharedDevice fb_isScreenLocked] ? CWErrorDeviceLocked : CWErrorInternal;
    *message = captureFailure ?: @"Unable to capture the screen";
    return nil;
  }

  CGSize originalSize = [self imageSizeForData:screenshotData];
  if (originalSize.width <= 0 || originalSize.height <= 0) {
    *errorCode = CWErrorInternal;
    *message = @"Unable to decode the screenshot";
    return nil;
  }
  @synchronized (self) {
    CWLastPixelSize = originalSize;
  }

  NSData *sourceData = screenshotData;
  CGSize workingSize = originalSize;
  if (nil != region && region.count == 4) {
    CGRect crop = CGRectMake(region[0].doubleValue,
                             region[1].doubleValue,
                             region[2].doubleValue,
                             region[3].doubleValue);
    NSData *cropped = [self croppedData:screenshotData
                                 region:crop
                                 isJPEG:isJPEG
                                quality:quality / 100.0];
    if (nil == cropped) {
      *errorCode = CWErrorInternal;
      *message = @"Unable to crop the screenshot";
      return nil;
    }
    sourceData = cropped;
    workingSize = crop.size;
  }

  CGFloat longestEdge = MAX(workingSize.width, workingSize.height);
  CGFloat scalingFactor = 1.0;
  if (nil != maxEdge && maxEdge.doubleValue > 0 && longestEdge > maxEdge.doubleValue) {
    scalingFactor = maxEdge.doubleValue / longestEdge;
  }

  NSData *outputData = nil;
  if (scalingFactor < 1.0) {
    FBImageProcessor *processor = [FBImageProcessor new];
    NSError *error = nil;
    outputData = [processor scaledImageWithData:sourceData
                                            uti:isJPEG ? UTTypeJPEG : UTTypePNG
                                  scalingFactor:scalingFactor
                             compressionQuality:isJPEG ? quality / 100.0 : 1.0
                                          error:&error];
    if (nil == outputData) {
      *errorCode = CWErrorInternal;
      *message = error.localizedDescription ?: @"Unable to scale the screenshot";
      return nil;
    }
  } else {
    outputData = isJPEG ? FBToJpegData(sourceData, quality / 100.0) : FBToPngData(sourceData);
    if (nil == outputData) {
      *errorCode = CWErrorInternal;
      *message = @"Unable to encode the screenshot";
      return nil;
    }
  }

  CGSize outputSize = [self imageSizeForData:outputData];
  CWScreenshotResult *result = [CWScreenshotResult new];
  result.data = outputData;
  result.width = (NSInteger)llround(outputSize.width);
  result.height = (NSInteger)llround(outputSize.height);
  result.contentType = isJPEG ? @"image/jpeg" : @"image/png";
  *errorCode = CWErrorOK;
  *message = @"";
  return result;
}

@end
