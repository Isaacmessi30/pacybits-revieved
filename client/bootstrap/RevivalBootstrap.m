#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// A launch probe only. It does not change saves, trading, authentication or networking.
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
    [button setTitle:@"Revival test" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithRed:0.16 green:0.22 blue:0.55 alpha:0.95];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    button.layer.cornerRadius = 12;
    button.accessibilityLabel = @"Open revival test status";
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
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    NSString *message = [NSString stringWithFormat:
        @"The revival module loaded inside the game.\n\niOS %@\nBundle: %@\n\nThis is a launch test. Google login and restored trading are not connected yet.\n\nThis separate test app does not import your original collection.",
        UIDevice.currentDevice.systemVersion, NSBundle.mainBundle.bundleIdentifier];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Revival launch test 1"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void PBRStartRevivalProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
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
