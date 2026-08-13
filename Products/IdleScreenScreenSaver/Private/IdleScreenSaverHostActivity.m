#import "IdleScreenSaverHostActivity.h"

NSInteger IdleScreenReadGlobalHostActivity(void) {
    @try {
        Class controllerClass = NSClassFromString(@"ScreenSaverController");
        SEL controllerSelector = NSSelectorFromString(@"controller");
        SEL runningSelector = NSSelectorFromString(@"screenSaverIsRunning");
        SEL backgroundSelector =
            NSSelectorFromString(@"screenSaverIsRunningInBackground");
        if (controllerClass == Nil ||
            ![controllerClass respondsToSelector:controllerSelector]) {
            return IdleScreenSaverHostActivityUnavailable;
        }

        id (*controllerGetter)(id, SEL) =
            (id (*)(id, SEL))[controllerClass methodForSelector:controllerSelector];
        id controller = controllerGetter(controllerClass, controllerSelector);
        if (controller == nil ||
            ![controller respondsToSelector:runningSelector] ||
            ![controller respondsToSelector:backgroundSelector]) {
            return IdleScreenSaverHostActivityUnavailable;
        }

        BOOL (*boolGetter)(id, SEL) =
            (BOOL (*)(id, SEL))[controller methodForSelector:runningSelector];
        BOOL isRunning = boolGetter(controller, runningSelector);
        boolGetter =
            (BOOL (*)(id, SEL))[controller methodForSelector:backgroundSelector];
        BOOL isRunningInBackground = boolGetter(controller, backgroundSelector);

        if (!isRunning && !isRunningInBackground) {
            return IdleScreenSaverHostActivityInactive;
        }
        if (isRunning && !isRunningInBackground) {
            return IdleScreenSaverHostActivityRunningForeground;
        }
        if (isRunning && isRunningInBackground) {
            return IdleScreenSaverHostActivityRunningBackground;
        }
        return IdleScreenSaverHostActivityInconsistent;
    } @catch (__unused NSException *exception) {
        return IdleScreenSaverHostActivityUnavailable;
    }
}
