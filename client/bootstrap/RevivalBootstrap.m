#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Entry point for the revival trading client.
@interface PBRRevivalBootstrap : NSObject
@property(nonatomic, strong) UIButton *button;
+ (instancetype)shared;
- (void)attach;
- (void)showStatus;
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
    // The original game predates scene-based app lifecycles.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow && window.rootViewController) return window;
    }
#pragma clang diagnostic pop
    return nil;
}
- (void)attach {
    UIWindow *window = [self gameWindow];
    if (!window || self.button.superview == window) return;
    [self.button removeFromSuperview];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button = button;
    [button setTitle:@"Trading" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithRed:0.16 green:0.22 blue:0.55 alpha:0.95];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    button.layer.cornerRadius = 12;
    button.accessibilityLabel = @"Open revival trading";
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:@selector(showStatus) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [button.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:8],
        [button.widthAnchor constraintEqualToConstant:108],
        [button.heightAnchor constraintEqualToConstant:36]
    ]];
}
- (void)showStatus {
    UIViewController *presenter = [self gameWindow].rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter || [presenter isKindOfClass:UIAlertController.class] ||
        [NSStringFromClass(presenter.class) isEqualToString:@"PBRTradingController"] ||
        ([presenter isKindOfClass:UINavigationController.class] &&
         [NSStringFromClass(((UINavigationController *)presenter).topViewController.class) isEqualToString:@"PBRTradingController"])) return;
    Class controller = NSClassFromString(@"PBRTradingController");
    SEL open = NSSelectorFromString(@"openFrom:");
    if ([controller respondsToSelector:open]) {
        ((void (*)(id, SEL, UIViewController *))objc_msgSend)(controller, open, presenter);
    }
}

@end

static void PBRTradeMenuTap(id receiver, SEL selector, id gesture) {
    [[PBRRevivalBootstrap shared] showStatus];
}

__attribute__((constructor)) static void PBRStartRevivalProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class menu = NSClassFromString(@"_TtC13PACYBITSFUT2025TradingMenuViewController");
        SEL tap = NSSelectorFromString(@"buttonTapHandlerWithGesture:");
        Method method = class_getInstanceMethod(menu, tap);
        if (method && method_getNumberOfArguments(method) == 3) {
            class_replaceMethod(menu, tap, (IMP)PBRTradeMenuTap, method_getTypeEncoding(method));
        }
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                [[PBRRevivalBootstrap shared] attach];
            }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                [[PBRRevivalBootstrap shared] attach];
            }];
        [[PBRRevivalBootstrap shared] attach];
    });
}

NSString *PBRCardLabel(NSString *identifier) {
    @try {
        Class player = NSClassFromString(@"_TtC13PACYBITSFUT206Player");
        SEL lookup = NSSelectorFromString(@"objectForPrimaryKey:");
        if (![player respondsToSelector:lookup]) return nil;
        id object = ((id (*)(id, SEL, id))objc_msgSend)(player, lookup, identifier);
        if (!object) return nil;
        NSString *name = [object valueForKey:@"name"];
        NSNumber *rating = [object valueForKey:@"rating"];
        if (![name isKindOfClass:NSString.class]) return nil;
        return [NSString stringWithFormat:@"%@ %@", rating ?: @"", name];
    } @catch (NSException *exception) { return nil; }
}
