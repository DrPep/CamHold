#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C `NSException` it raises into an
/// `NSError` (domain `CamHoldObjCException`). Returns `nil` when the block ran
/// without raising.
///
/// Swift's `do/catch` cannot catch `NSException`, so AVFoundation setters that
/// raise — notably `-[AVCaptureDevice setActiveVideoMinFrameDuration:]`, which
/// some external/virtual devices (`AVCaptureDevice_Tundra`) reject as
/// "Not Supported" — would otherwise crash the app. Wrap those calls in this
/// shim and handle the returned error instead.
NSError * _Nullable CamHoldRunCatching(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
