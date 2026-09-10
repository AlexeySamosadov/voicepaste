#import "ObjCShim.h"

NSString *const ObjCShimExceptionErrorDomain = @"ObjCShim.NSException";

BOOL ObjCShimTry(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"";
            NSString *description = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
            *error = [NSError errorWithDomain:ObjCShimExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: description,
                                         @"exceptionName": exception.name,
                                         @"exceptionReason": reason,
                                     }];
        }
        return NO;
    }
}
