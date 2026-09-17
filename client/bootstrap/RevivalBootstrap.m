#import <UIKit/UIKit.h>
#import "RevivalRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface PBRRevivalBootstrap : NSObject
+ (instancetype)shared;
- (void)openMode:(NSString *)mode;
- (void)handleTradingTile:(UITapGestureRecognizer *)gesture;
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
- (void)handleTradingTile:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    NSString *mode = objc_getAssociatedObject(gesture, @selector(handleTradingTile:));
    if (![mode isKindOfClass:NSString.class] || !mode.length) return;
    [self openMode:mode];
}
@end

static NSString *PBRModeForText(NSString *raw) {
    if (![raw isKindOfClass:NSString.class] || !raw.length) return nil;
    NSString *text = [raw.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text containsString:@"use a code"] || [text isEqualToString:@"code"] || [text containsString:@"invite code"]) return @"code";
    if ([text containsString:@"friend"]) return @"friends";
    if ([text containsString:@"channel"]) return @"channels";
    if ([text containsString:@"random"]) return @"random";
    return nil;
}

static NSString *PBROwnModeForView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UIButton.class]) {
        NSString *mode = PBRModeForText([(UIButton *)view titleForState:UIControlStateNormal]);
        if (mode) return mode;
    }
    if ([view isKindOfClass:UILabel.class]) {
        NSString *mode = PBRModeForText(((UILabel *)view).text);
        if (mode) return mode;
    }
    return PBRModeForText(view.accessibilityLabel);
}

static UIView *PBRClickableTileForLabel(UIView *label, UIView *menuRoot) {
    UIView *candidate = label;
    UIView *fallback = label.superview ?: label;
    for (NSInteger depth = 0; candidate && candidate != menuRoot && depth < 6; depth++, candidate = candidate.superview) {
        if (candidate.gestureRecognizers.count > 0 || [candidate isKindOfClass:UIControl.class]) return candidate;
        if (candidate.superview && candidate.superview != menuRoot) fallback = candidate.superview;
    }
    return fallback;
}

static const void *PBRWiredModeKey = &PBRWiredModeKey;

static void PBRWireTradingMenuView(UIView *view, UIView *root) {
    NSString *mode = PBROwnModeForView(view);
    if (mode) {
        UIView *tile = PBRClickableTileForLabel(view, root);
        NSString *already = objc_getAssociatedObject(tile, PBRWiredModeKey);
        if (![already isEqualToString:mode]) {
            // The original recognizers lead into discontinued Game Center paths.
            // Remove only the recognizers on the identified tile, not on the whole menu.
            for (UIGestureRecognizer *old in [tile.gestureRecognizers copy]) {
                [tile removeGestureRecognizer:old];
            }
            tile.userInteractionEnabled = YES;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[PBRRevivalBootstrap shared]
                                                                                   action:@selector(handleTradingTile:)];
            tap.cancelsTouchesInView = YES;
            objc_setAssociatedObject(tap, @selector(handleTradingTile:), mode, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(tile, PBRWiredModeKey, mode, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [tile addGestureRecognizer:tap];
        }
    }
    for (UIView *child in view.subviews) PBRWireTradingMenuView(child, root);
}

static IMP PBROriginalTradingMenuViewDidAppear = NULL;
static void PBRTradingMenuViewDidAppear(id receiver, SEL selector, BOOL animated) {
    if (PBROriginalTradingMenuViewDidAppear) {
        ((void (*)(id, SEL, BOOL))PBROriginalTradingMenuViewDidAppear)(receiver, selector, animated);
    }
    if (![receiver isKindOfClass:UIViewController.class]) return;
    UIViewController *controller = (UIViewController *)receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (controller.view.window) PBRWireTradingMenuView(controller.view, controller.view);
    });
}

__attribute__((constructor)) static void PBRStartRevivalProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class menu = NSClassFromString(@"_TtC13PACYBITSFUT2025TradingMenuViewController");
        SEL appear = @selector(viewDidAppear:);
        Method method = class_getInstanceMethod(menu, appear);
        if (method) {
            PBROriginalTradingMenuViewDidAppear = method_getImplementation(method);
            method_setImplementation(method, (IMP)PBRTradingMenuViewDidAppear);
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
