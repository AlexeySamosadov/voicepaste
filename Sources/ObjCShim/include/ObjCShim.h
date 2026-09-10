#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain used for NSExceptions converted by `ObjCShimTry`.
extern NSString *const ObjCShimExceptionErrorDomain;

/// Runs `block` inside an Objective-C @try. If the block raises an
/// NSException, the exception is swallowed, `error` (if non-NULL) is filled
/// with a descriptive NSError, and NO is returned. Swift cannot catch
/// NSExceptions on its own; AVFAudio raises them for a whole family of
/// runtime conditions (tap format mismatch, tap already installed, device
/// gone) that would otherwise abort the process.
BOOL ObjCShimTry(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
