#import "CWResponse.h"

#import <WebDriverAgentLib/FBResponseJSONPayload.h>

#import "CWApiPaths.h"
#import "RouteResponse.h"

@interface CWRawPayload : NSObject <FBResponsePayload>
@property (nonatomic, copy) NSData *data;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, assign) HTTPStatusCode statusCode;
@end

@implementation CWRawPayload

- (void)dispatchWithResponse:(RouteResponse *)response
{
  response.statusCode = self.statusCode;
  [response setHeader:@"Content-Type" value:self.contentType];
  [response setHeader:@"Cache-Control" value:@"no-store"];
  [self.headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
    [response setHeader:field value:value];
  }];
  [response respondWithData:self.data];
}

@end

@implementation CWResponse

+ (NSDictionary *)envelopeWithOK:(BOOL)ok
                            code:(NSString *)code
                         message:(nullable NSString *)message
                       elapsedMs:(NSInteger)elapsedMs
                            data:(nullable id)data
{
  return @{
    @"protocol" : CWProtocolVersion,
    @"ok" : @(ok),
    @"code" : code,
    @"message" : message ?: @"",
    @"elapsed_ms" : @(elapsedMs),
    @"data" : data ?: @{},
  };
}

+ (id<FBResponsePayload>)successWithData:(nullable id)data elapsedMs:(NSInteger)elapsedMs
{
  return [[FBResponseJSONPayload alloc] initWithDictionary:[self envelopeWithOK:YES
                                                                          code:CWErrorOK
                                                                       message:@""
                                                                     elapsedMs:elapsedMs
                                                                          data:data]
                                            httpStatusCode:kHTTPStatusCodeOK];
}

+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs
{
  return [self failureWithCode:code
                       message:message
                     elapsedMs:elapsedMs
                          data:@{}
                    statusCode:kHTTPStatusCodeOK];
}

+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs
                                   data:(nullable id)data
{
  return [self failureWithCode:code
                       message:message
                     elapsedMs:elapsedMs
                          data:data
                    statusCode:kHTTPStatusCodeOK];
}

+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs
                             statusCode:(HTTPStatusCode)statusCode
{
  return [self failureWithCode:code
                       message:message
                     elapsedMs:elapsedMs
                          data:@{}
                    statusCode:statusCode];
}

+ (id<FBResponsePayload>)failureWithCode:(NSString *)code
                                message:(nullable NSString *)message
                              elapsedMs:(NSInteger)elapsedMs
                                   data:(nullable id)data
                             statusCode:(HTTPStatusCode)statusCode
{
  return [[FBResponseJSONPayload alloc] initWithDictionary:[self envelopeWithOK:NO
                                                                          code:code
                                                                       message:message
                                                                     elapsedMs:elapsedMs
                                                                          data:data]
                                            httpStatusCode:statusCode];
}

+ (id<FBResponsePayload>)rawData:(NSData *)data
                    contentType:(NSString *)contentType
                        headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                     statusCode:(HTTPStatusCode)statusCode
{
  CWRawPayload *payload = [CWRawPayload new];
  payload.data = data;
  payload.contentType = contentType;
  payload.headers = headers;
  payload.statusCode = statusCode;
  return payload;
}

+ (NSInteger)elapsedMsSince:(CFAbsoluteTime)start
{
  return (NSInteger)llround((CFAbsoluteTimeGetCurrent() - start) * 1000.0);
}

@end
