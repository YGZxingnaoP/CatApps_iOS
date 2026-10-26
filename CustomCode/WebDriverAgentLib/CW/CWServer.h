#import <Foundation/Foundation.h>
#import <WebDriverAgentLib/FBCommandHandler.h>

NS_ASSUME_NONNULL_BEGIN

@interface CWServer : NSObject <FBCommandHandler>

+ (void)bootstrap;

@end

NS_ASSUME_NONNULL_END
