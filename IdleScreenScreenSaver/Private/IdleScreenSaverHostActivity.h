#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, IdleScreenSaverHostActivityRawValue) {
    IdleScreenSaverHostActivityUnavailable = 0,
    IdleScreenSaverHostActivityInactive = 1,
    IdleScreenSaverHostActivityRunningForeground = 2,
    IdleScreenSaverHostActivityRunningBackground = 3,
    IdleScreenSaverHostActivityInconsistent = 4,
};

/// Reads only Tahoe's private global screen-saver activity selectors. Every
/// missing symbol, invalid return, or Objective-C exception fails closed.
FOUNDATION_EXPORT NSInteger IdleScreenReadGlobalHostActivity(void);

NS_ASSUME_NONNULL_END
