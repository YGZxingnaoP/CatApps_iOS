#import <Foundation/Foundation.h>
#import <WebDriverAgentLib/FBResponsePayload.h>
#import <WebDriverAgentLib/FBHTTPStatusCodes.h>

#import "CWError.h"

NS_ASSUME_NONNULL_BEGIN

@interface CWResponse : NSObject

+ (id<FBResponsePayload>)successWithData:(nullable id)data elapsedMs:(NSInteger)elapsedMs;
+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs;
+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs
                                   data:(nullable id)data;
+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs
                             statusCode:(HTTPStatusCode)statusCode;
+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs
                                   data:(nullable id)data
                             statusCode:(HTTPStatusCode)statusCode;
+ (id<FBResponsePayload>)rawData:(NSData *)data
                    contentType:(NSString *)contentType
                        headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                     statusCode:(HTTPStatusCode)statusCode;
+ (NSInteger)elapsedMsSince:(CFAbsoluteTime)start;

@end

NS_ASSUME_NONNULL_END
