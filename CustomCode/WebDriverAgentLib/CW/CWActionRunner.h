#import <Foundation/Foundation.h>

#import "CWActionStep.h"

NS_ASSUME_NONNULL_BEGIN

@interface CWActionResult : NSObject

@property (nonatomic, assign) BOOL ok;
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, assign) NSInteger executed;
@property (nonatomic, copy) NSArray<NSDictionary *> *results;

@end

@interface CWActionRunner : NSObject

+ (instancetype)shared;
- (CWActionResult *)performSteps:(NSArray<CWActionStep *> *)steps delayMs:(NSInteger)delayMs;
- (CWActionResult *)performSteps:(NSArray<CWActionStep *> *)steps
                         delayMs:(NSInteger)delayMs
                        waitIdle:(BOOL)waitIdle;
- (BOOL)requestStop;
- (BOOL)isRunning;
- (NSInteger)remainingSteps;

@end

NS_ASSUME_NONNULL_END
