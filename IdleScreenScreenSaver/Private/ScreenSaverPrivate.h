// Modern screen-saver App Extension declarations are still absent from the
// public ScreenSaver SDK. These minimal declarations follow the MIT-licensed
// AerialScreensaver/AppexSaverMinimal reference and stay isolated in this file.

#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import "IdleScreenSaverHostActivity.h"

NS_ASSUME_NONNULL_BEGIN

@interface ScreenSaverExtension : NSObject
- (instancetype)init;
@end

@interface ScreenSaverViewController : NSViewController
- (void)startAnimation;
- (void)stopAnimation;
- (void)invalidate;
@end

@interface ScreenSaverConfigurationViewController : NSViewController
- (void)configureSheetDidEnd;
@end

NS_ASSUME_NONNULL_END
