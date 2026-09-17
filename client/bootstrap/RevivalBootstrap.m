#import <UIKit/UIKit.h>
#import "RevivalRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface PBRRevivalBootstrap : NSObject
+ (instancetype)shared;
- (void)openMode:(NSString *)mode;
@end

@implementation PBRRevivalBootstrap
+ (instancetype)shared {
    static PBRRevivalBootstrap *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [PBRRevivalBootstrap new]; });
    return instance;
}
- (UIWindow *)gameWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.rootViewController) return window;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow && window.rootViewController) return window;
    }
#pragma clang diagnostic pop
    return nil;
}
- (void)openMode:(NSString *)mode {
    UIViewController *presenter = [self gameWindow].rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL open = NSSelectorFromString(@"openFrom:mode:");
    if ([launcher respondsToSelector:open]) {
        ((void (*)(id, SEL, UIViewController *, NSString *))objc_msgSend)(launcher, open, presenter, mode ?: @"random");
    }
}
@end

static NSString *PBRVisibleText(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UIButton.class]) {
        NSString *title = [(UIButton *)view titleForState:UIControlStateNormal];
        if (title.length) return title;
    }
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) return ((UILabel *)view).text;
    if (view.accessibilityLabel.length) return view.accessibilityLabel;
    for (UIView *child in view.subviews) {
        NSString *text = PBRVisibleText(child);
        if (text.length) return text;
    }
    return nil;
}

static NSString *PBRModeForGesture(id gesture) {
    UIView *view = nil;
    if ([gesture respondsToSelector:NSSelectorFromString(@"view")]) {
        view = ((id (*)(id, SEL))objc_msgSend)(gesture, NSSelectorFromString(@"view"));
    }
    NSString *text = [PBRVisibleText(view).lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text containsString:@"code"] || [text containsString:@"invite"]) return @"code";
    if ([text containsString:@"friend"] || [text containsString:@"friendly"]) return @"friends";
    if ([text containsString:@"channel"]) return @"channels";
    if ([text containsString:@"random"] || [text containsString:@"online"]) return @"random";
    // The original menu has historically used random trading as its primary path.
    // Unknown labels use that path rather than falling through to dead GameKit.
    return @"random";
}

static void PBRTradeMenuTap(id receiver, SEL selector, id gesture) {
    [[PBRRevivalBootstrap shared] openMode:PBRModeForGesture(gesture)];
}

__attribute__((constructor)) static void PBRStartRevivalProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class menu = NSClassFromString(@"_TtC13PACYBITSFUT2025TradingMenuViewController");
        SEL tap = NSSelectorFromString(@"buttonTapHandlerWithGesture:");
        Method method = class_getInstanceMethod(menu, tap);
        if (method && method_getNumberOfArguments(method) == 3) {
            class_replaceMethod(menu, tap, (IMP)PBRTradeMenuTap, method_getTypeEncoding(method));
        }
    });
}

NSString *PBRCardLabel(NSString *identifier) {
    @try {
        id object = PBRPlayerForIdentifier(identifier);
        if (!object) return nil;
        NSString *name = [object valueForKey:@"name"];
        NSNumber *rating = [object valueForKey:@"rating"];
        if (![name isKindOfClass:NSString.class]) return nil;
        return [NSString stringWithFormat:@"%@ %@", rating ?: @"", name];
    } @catch (NSException *exception) { return nil; }
}

NSString *PBRPlayerIdentifier(id player) {
    @try {
        if (!player) return nil;
        Class cls = [player class];
        NSString *key = nil;
        SEL primary = NSSelectorFromString(@"primaryKey");
        if ([cls respondsToSelector:primary]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(cls, primary);
            if ([value isKindOfClass:NSString.class]) key = value;
        }
        NSArray<NSString *> *keys = key.length ? @[key, @"playerId", @"identifier", @"id"] : @[@"playerId", @"identifier", @"id"];
        for (NSString *candidate in keys) {
            @try {
                id value = [player valueForKey:candidate];
                if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
                if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
            } @catch (NSException *ignored) {}
        }
        return nil;
    } @catch (NSException *exception) { return nil; }
}

id PBRPlayerForIdentifier(NSString *identifier) {
    @try {
        Class player = NSClassFromString(@"_TtC13PACYBITSFUT206Player");
        SEL lookup = NSSelectorFromString(@"objectForPrimaryKey:");
        if (![player respondsToSelector:lookup]) return nil;
        id object = ((id (*)(id, SEL, id))objc_msgSend)(player, lookup, identifier);
        return [object isKindOfClass:player] ? object : nil;
    } @catch (NSException *exception) { return nil; }
}

UIViewController *PBRInstantiateOriginalTrading(void) {
    @try {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Trading" bundle:NSBundle.mainBundle];
        UIViewController *controller = [storyboard instantiateViewControllerWithIdentifier:@"TradingViewController"];
        Class expected = NSClassFromString(@"_TtC13PACYBITSFUT2021TradingViewController");
        return expected && [controller isKindOfClass:expected] ? controller : nil;
    } @catch (NSException *exception) { return nil; }
}
