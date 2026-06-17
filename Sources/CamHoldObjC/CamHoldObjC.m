#import "CamHoldObjC.h"

NSError * _Nullable CamHoldRunCatching(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name ?: @"Objective-C exception";
        return [NSError errorWithDomain:@"CamHoldObjCException"
                                   code:1
                               userInfo:@{
                                   NSLocalizedDescriptionKey: reason,
                                   @"ExceptionName": exception.name ?: @""
                               }];
    }
}
