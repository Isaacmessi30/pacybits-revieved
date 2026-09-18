#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>
#import <mach-o/dyld.h>
#import "RevivalRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface PBRRevivalBootstrap : NSObject
+ (instancetype)shared;
- (UIWindow *)gameWindow;
- (UIViewController *)topPresenter;
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
- (UIViewController *)topPresenter {
    UIViewController *presenter = [self gameWindow].rootViewController;
    for (NSUInteger depth = 0; presenter && depth < 32; depth++) {
        UIViewController *next = nil;

        UIViewController *presented = presenter.presentedViewController;
        if (presented && !presented.isBeingDismissed) {
            next = presented;
        } else if ([presenter isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)presenter).visibleViewController;
        } else if ([presenter isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)presenter).selectedViewController;
        } else {
            for (UIViewController *child in presenter.childViewControllers.reverseObjectEnumerator) {
                if (child.isViewLoaded && child.view.window != nil) {
                    next = child;
                    break;
                }
            }
        }

        if (!next || next == presenter) break;
        presenter = next;
    }
    return presenter;
}
@end

@interface PBRRevivalBootstrap (TradingTiles)
- (void)tradingTileTapped:(UITapGestureRecognizer *)gesture;
- (void)codeSearchTapped:(UITapGestureRecognizer *)gesture;
- (void)channelsSearchTapped:(UITapGestureRecognizer *)gesture;
- (void)friendsSearchTapped:(UITapGestureRecognizer *)gesture;
- (void)aboutSignInTapped:(UIButton *)sender;
- (void)aboutSignOutTapped:(UIButton *)sender;
@end

// PACYBITS remains responsible for every visible trading screen. This layer only
// replaces authentication and multiplayer transport with Google/Firebase/Render.
static CFTimeInterval PBRTradingArmedUntil = 0;
static IMP PBROriginalTradingMenuTap = NULL;
static IMP PBROriginalCodeDidMoveToWindow = NULL;
static IMP PBROriginalChannelsDidMoveToWindow = NULL;
static IMP PBROriginalFriendsDidMoveToWindow = NULL;
static IMP PBROriginalCodeSearch = NULL;
static IMP PBROriginalChannelsSearch = NULL;
static IMP PBROriginalFriendsButton = NULL;
static IMP PBROriginalFindMatch = NULL;
static IMP PBROriginalMatchForInvite = NULL;
static IMP PBROriginalMatchmakerCancel = NULL;
static IMP PBROriginalOnlineLoadingCancel = NULL;
static IMP PBROriginalAboutViewDidAppear = NULL;
static IMP PBROriginalTradeReadyPan = NULL;
static IMP PBROriginalTradeAcceptTap = NULL;
static IMP PBROriginalTradeMakeChangesTap = NULL;
static IMP PBROriginalTradeCancelAcceptTap = NULL;
static IMP PBROriginalTradeLeaveTap = NULL;

static BOOL PBRMenuTapHooked = NO;
static BOOL PBRCodeViewHooked = NO;
static BOOL PBRChannelsViewHooked = NO;
static BOOL PBRFriendsViewHooked = NO;
static BOOL PBRFindMatchHooked = NO;
static BOOL PBRInviteHooked = NO;
static BOOL PBRCancelHooked = NO;
static BOOL PBROnlineLoadingCancelHooked = NO;
static BOOL PBRAboutViewHooked = NO;
static BOOL PBRTradeReadyHooked = NO;
static BOOL PBRTradeAcceptHooked = NO;
static BOOL PBRTradeMakeChangesHooked = NO;
static BOOL PBRTradeCancelAcceptHooked = NO;
static BOOL PBRTradeLeaveHooked = NO;

static char PBRButtonWiredKey;
static char PBRGestureControllerKey;
static char PBRGestureModeKey;
static char PBRAboutControlsKey;
static char PBRAboutControllerKey;

static BOOL PBRTradingIsArmed(void) {
    return PBRTradingArmedUntil > CACurrentMediaTime();
}

static BOOL PBRRevivalMatchActive(void) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL active = NSSelectorFromString(@"isMatchActive");
    if (![launcher respondsToSelector:active]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(launcher, active);
}

static BOOL PBRShouldInterceptTrading(void) {
    return PBRTradingIsArmed() || PBRRevivalMatchActive();
}

static id PBRDynamicValue(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static id PBRGameCenterHelper(void) {
    @try {
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        uintptr_t address = (uintptr_t)(0x1012be350ULL + slide);
        void *raw = *(void **)address;
        if (!raw) return nil;
        id helper = (__bridge id)raw;
        Class expected = NSClassFromString(@"_TtC13PACYBITSFUT2016GameCenterHelper");
        return expected && [helper isKindOfClass:expected] ? helper : nil;
    } @catch (NSException *exception) { return nil; }
}

static void PBRExposeTradingAsConnected(void) {
    @try {
        id helper = PBRGameCenterHelper();
        if (!helper) return;
        [helper setValue:@YES forKey:@"isConnected"];
        if (![helper valueForKey:@"connectedPlayer"]) {
            [helper setValue:GKLocalPlayer.localPlayer forKey:@"connectedPlayer"];
        }
    } @catch (NSException *exception) {}
}

static NSString *PBRLocalLegacyID(void) {
    @try {
        id helper = PBRGameCenterHelper();
        id value = [helper valueForKey:@"uniqueId"];
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    } @catch (NSException *exception) {}
    return nil;
}

static NSString *PBRInvitedFriendLegacyID(void) {
    @try {
        id helper = PBRGameCenterHelper();
        id friend = [helper valueForKey:@"invitedFriend"];
        id value = friend ? [friend valueForKey:@"playerID"] : nil;
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    } @catch (NSException *exception) {}
    return nil;
}

static BOOL PBRBeginScopeFromPresenter(UIViewController *presenter, NSString *scope, NSString *target) {
    if (!presenter || !scope.length) return NO;
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL begin = NSSelectorFromString(@"beginOriginalMatchFrom:scope:targetLegacyID:localLegacyID:");
    if (![launcher respondsToSelector:begin]) return NO;
    ((void (*)(id, SEL, UIViewController *, NSString *, NSString *, NSString *))objc_msgSend)(
        launcher, begin, presenter, scope, target, PBRLocalLegacyID());
    return YES;
}

static void PBRBeginScope(NSString *scope, NSString *target) {
    UIViewController *presenter = [[PBRRevivalBootstrap shared] topPresenter];
    (void)PBRBeginScopeFromPresenter(presenter, scope, target);
}

static void PBRPrepareGoogle(UIViewController *presenter, void (^completion)(BOOL)) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL prepare = NSSelectorFromString(@"prepareTradingFrom:completion:");
    if (![launcher respondsToSelector:prepare]) { completion(NO); return; }
    ((void (*)(id, SEL, UIViewController *, id))objc_msgSend)(launcher, prepare, presenter, completion);
}

static NSString *PBRNormalizedCode(id receiver);
static void PBRHealthBeacon(NSString *probe);
extern BOOL PBRBeginRandomTradingDirect(void *presenterOpaque);

static NSString *PBRTradingModeForGesture(id receiver, UIGestureRecognizer *gesture) {
    UIView *source = gesture.view;
    if (!receiver || !source) return nil;

    for (NSString *getter in @[@"channelsButton", @"friendsButton", @"codeButton", @"randomButton"]) {
        id value = PBRDynamicValue(receiver, getter);
        if (![value isKindOfClass:UIView.class]) continue;
        UIView *button = value;

        BOOL sameTree = (button == source) ||
                        [source isDescendantOfView:button] ||
                        [button isDescendantOfView:source];
        CGPoint point = [gesture locationInView:button];
        BOOL pointInside = CGRectContainsPoint(button.bounds, point);
        if (sameTree || pointInside) {
            return [getter stringByReplacingOccurrencesOfString:@"Button" withString:@""];
        }
    }
    return nil;
}

static void PBRTradingMenuTapHook(id receiver, SEL selector, UIGestureRecognizer *gesture) {
    NSString *mode = PBRTradingModeForGesture(receiver, gesture);
    if (!mode.length) {
        if (PBROriginalTradingMenuTap) {
            ((void (*)(id, SEL, id))PBROriginalTradingMenuTap)(receiver, selector, gesture);
        }
        return;
    }

    if ([mode isEqualToString:@"random"]) PBRHealthBeacon(@"random-tap");

    UIViewController *presenter = [receiver isKindOfClass:UIViewController.class]
        ? receiver : [[PBRRevivalBootstrap shared] topPresenter];
    if (!presenter) return;

    PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
    PBRExposeTradingAsConnected();

    // Random must start the real revival coordinator immediately. The
    // coordinator already owns Google/Firebase authentication, so do not gate
    // it behind a second prepare/auth callback that can prevent any network
    // request from ever being made.
    if ([mode isEqualToString:@"random"]) {
        PBRHealthBeacon(@"bridge-direct-call");
        if (!PBRBeginRandomTradingDirect((__bridge void *)presenter)) {
            PBRHealthBeacon(@"bridge-direct-failed");
            PBRTradingArmedUntil = 0;
        } else {
            PBRHealthBeacon(@"bridge-direct-return");
        }
    }

    if (PBROriginalTradingMenuTap) {
        ((void (*)(id, SEL, id))PBROriginalTradingMenuTap)(receiver, selector, gesture);
    }
}

@implementation PBRRevivalBootstrap (TradingTiles)
- (void)tradingTileTapped:(UITapGestureRecognizer *)gesture {
    NSValue *box = objc_getAssociatedObject(gesture, &PBRGestureControllerKey);
    id receiver = [box nonretainedObjectValue];
    if (!receiver || !PBROriginalTradingMenuTap) return;
    UIViewController *presenter = [receiver isKindOfClass:UIViewController.class]
        ? receiver : [self topPresenter];
    PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
    PBRPrepareGoogle(presenter, ^(BOOL ok) {
        if (!ok) { PBRTradingArmedUntil = 0; return; }
        PBRExposeTradingAsConnected();
        NSString *mode = objc_getAssociatedObject(gesture, &PBRGestureModeKey);

        // Start revival matchmaking before PACYBITS enters its legacy GameKit
        // flow. Some versions never reach findMatchForRequest: once Game Center
        // has been retired, so waiting until after the original handler can leave
        // the UI searching forever without ever contacting Render.
        if ([mode isEqualToString:@"random"]) {
            PBRBeginScope(@"g:0:a:0", nil);
        }

        // PACYBITS still owns the visible original menu/search animation.
        ((void (*)(id, SEL, id))PBROriginalTradingMenuTap)(
            receiver, NSSelectorFromString(@"buttonTapHandlerWithGesture:"), gesture);
    });
}
- (void)codeSearchTapped:(UITapGestureRecognizer *)gesture {
    id receiver = [objc_getAssociatedObject(gesture, &PBRGestureControllerKey) nonretainedObjectValue];
    if (!receiver || !PBROriginalCodeSearch) return;
    NSString *code = PBRNormalizedCode(receiver);
    if (code.length) {
        PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
        PBRExposeTradingAsConnected();
        PBRBeginScope([@"code:" stringByAppendingString:code], nil);
    }
    ((void (*)(id, SEL, id))PBROriginalCodeSearch)(
        receiver, NSSelectorFromString(@"searchTapHandlerWithGesture:"), gesture);
}
- (void)channelsSearchTapped:(UITapGestureRecognizer *)gesture {
    id receiver = [objc_getAssociatedObject(gesture, &PBRGestureControllerKey) nonretainedObjectValue];
    if (!receiver || !PBROriginalChannelsSearch) return;
    id collection = PBRDynamicValue(receiver, @"collectionView");
    NSArray *selected = [collection respondsToSelector:@selector(indexPathsForSelectedItems)]
        ? [collection indexPathsForSelectedItems] : nil;
    NSIndexPath *path = selected.firstObject;
    if (path) {
        PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
        PBRExposeTradingAsConnected();
        PBRBeginScope([NSString stringWithFormat:@"channel:%ld:%ld",
                       (long)path.section, (long)path.item], nil);
    }
    ((void (*)(id, SEL, id))PBROriginalChannelsSearch)(
        receiver, NSSelectorFromString(@"searchTapHandlerWithGesture:"), gesture);
}
- (void)friendsSearchTapped:(UITapGestureRecognizer *)gesture {
    id receiver = [objc_getAssociatedObject(gesture, &PBRGestureControllerKey) nonretainedObjectValue];
    if (!receiver || !PBROriginalFriendsButton) return;
    ((void (*)(id, SEL, id))PBROriginalFriendsButton)(
        receiver, NSSelectorFromString(@"buttonTapHandlerWithGesture:"), gesture);
    NSString *target = PBRInvitedFriendLegacyID();
    if (target.length) {
        PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
        PBRExposeTradingAsConnected();
        PBRBeginScope(@"friends", target);
    }
}
- (void)aboutSignInTapped:(UIButton *)sender {
    UIViewController *controller = [objc_getAssociatedObject(sender, &PBRAboutControllerKey) nonretainedObjectValue];
    UIViewController *presenter = controller ?: [self topPresenter];
    Class manager = NSClassFromString(@"PBRAccountManager");
    SEL action = NSSelectorFromString(@"signInOrSwitchFrom:");
    if (presenter && [manager respondsToSelector:action]) {
        ((void (*)(id, SEL, UIViewController *))objc_msgSend)(manager, action, presenter);
    }
}
- (void)aboutSignOutTapped:(UIButton *)sender {
    UIViewController *controller = [objc_getAssociatedObject(sender, &PBRAboutControllerKey) nonretainedObjectValue];
    UIViewController *presenter = controller ?: [self topPresenter];
    Class manager = NSClassFromString(@"PBRAccountManager");
    SEL action = NSSelectorFromString(@"signOutFrom:");
    if (presenter && [manager respondsToSelector:action]) {
        ((void (*)(id, SEL, UIViewController *))objc_msgSend)(manager, action, presenter);
    }
}
@end

static void PBRWireActionButton(id receiver, NSString *getter, SEL action) {
    id value = PBRDynamicValue(receiver, getter);
    if (![value isKindOfClass:UIView.class]) return;
    UIView *button = value;
    if ([objc_getAssociatedObject(button, &PBRButtonWiredKey) boolValue]) return;
    for (UIGestureRecognizer *existing in [button.gestureRecognizers copy]) {
        if ([existing isKindOfClass:UITapGestureRecognizer.class]) [button removeGestureRecognizer:existing];
    }
    button.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[PBRRevivalBootstrap shared]
                                                                          action:action];
    objc_setAssociatedObject(tap, &PBRGestureControllerKey,
                             [NSValue valueWithNonretainedObject:receiver],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [button addGestureRecognizer:tap];
    objc_setAssociatedObject(button, &PBRButtonWiredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void PBRCodeDidMoveToWindow(id receiver, SEL selector) {
    if (PBROriginalCodeDidMoveToWindow) {
        ((void (*)(id, SEL))PBROriginalCodeDidMoveToWindow)(receiver, selector);
    }
    if ([receiver window]) PBRWireActionButton(receiver, @"searchButton", @selector(codeSearchTapped:));
}

static void PBRChannelsDidMoveToWindow(id receiver, SEL selector) {
    if (PBROriginalChannelsDidMoveToWindow) {
        ((void (*)(id, SEL))PBROriginalChannelsDidMoveToWindow)(receiver, selector);
    }
    if ([receiver window]) PBRWireActionButton(receiver, @"button", @selector(channelsSearchTapped:));
}

static void PBRFriendsDidMoveToWindow(id receiver, SEL selector) {
    if (PBROriginalFriendsDidMoveToWindow) {
        ((void (*)(id, SEL))PBROriginalFriendsDidMoveToWindow)(receiver, selector);
    }
    if ([receiver window]) PBRWireActionButton(receiver, @"button", @selector(friendsSearchTapped:));
}

static UIButton *PBRAboutButton(NSString *title, SEL action, UIViewController *controller) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.88];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.layer.cornerRadius = 10.0;
    button.layer.masksToBounds = YES;
    [button addTarget:[PBRRevivalBootstrap shared] action:action forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, &PBRAboutControllerKey,
                             [NSValue valueWithNonretainedObject:controller],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

static void PBRInstallAboutControls(UIViewController *controller) {
    if (!controller || objc_getAssociatedObject(controller, &PBRAboutControlsKey)) return;
    UIView *root = controller.view;
    if (!root) return;

    UIVisualEffectView *panel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 14.0;
    panel.layer.masksToBounds = YES;

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"REVIVAL GOOGLE ACCOUNT";
    label.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    label.textAlignment = NSTextAlignmentCenter;

    UIButton *signIn = PBRAboutButton(@"SIGN IN / SWITCH ACCOUNT", @selector(aboutSignInTapped:), controller);
    UIButton *signOut = PBRAboutButton(@"SIGN OUT", @selector(aboutSignOutTapped:), controller);

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[signIn, signOut]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 8;
    buttons.distribution = UIStackViewDistributionFillEqually;

    [panel.contentView addSubview:label];
    [panel.contentView addSubview:buttons];
    [root addSubview:panel];

    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:16],
        [panel.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [panel.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor constant:-10],
        [panel.heightAnchor constraintEqualToConstant:92],
        [label.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:9],
        [label.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-8],
        [buttons.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:7],
        [buttons.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:10],
        [buttons.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-10],
        [buttons.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-10]
    ]];

    objc_setAssociatedObject(controller, &PBRAboutControlsKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void PBRAboutViewDidAppear(id receiver, SEL selector, BOOL animated) {
    if (PBROriginalAboutViewDidAppear) {
        ((void (*)(id, SEL, BOOL))PBROriginalAboutViewDidAppear)(receiver, selector, animated);
    }
    if ([receiver isKindOfClass:UIViewController.class]) {
        PBRInstallAboutControls((UIViewController *)receiver);
    }
}

static NSString *PBRNormalizedCode(id receiver) {
    id field = PBRDynamicValue(receiver, @"textField");
    if (![field respondsToSelector:@selector(text)]) field = PBRDynamicValue(receiver, @"text_field");
    NSString *text = [field respondsToSelector:@selector(text)] ? [field text] : nil;
    text = [[text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if (text.length < 3 || text.length > 32) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    return [[text stringByTrimmingCharactersInSet:allowed] length] == 0 ? text : nil;
}

static NSString *PBRPlayerIDFromObject(id player) {
    for (NSString *selectorName in @[@"gamePlayerID", @"playerID"]) {
        id value = PBRDynamicValue(player, selectorName);
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }
    return nil;
}

static NSString *PBRTargetLegacyID(GKMatchRequest *request) {
    id recipients = PBRDynamicValue(request, @"recipients");
    if ([recipients isKindOfClass:NSArray.class]) {
        for (id player in (NSArray *)recipients) {
            NSString *identifier = PBRPlayerIDFromObject(player);
            if (identifier.length) return identifier;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    id oldRecipients = PBRDynamicValue(request, @"playersToInvite");
#pragma clang diagnostic pop
    if ([oldRecipients isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)oldRecipients) {
            if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
        }
    }
    return nil;
}

static NSString *PBRInviteSenderLegacyID(GKInvite *invite) {
    if (!invite) return nil;
    id sender = PBRDynamicValue(invite, @"sender");
    return PBRPlayerIDFromObject(sender);
}

static void PBRBeginBackendMatch(GKMatchRequest *request) {
    NSInteger group = request.playerGroup;
    NSUInteger attributes = request.playerAttributes;
    NSString *scope = [NSString stringWithFormat:@"g:%ld:a:%lu", (long)group, (unsigned long)attributes];
    PBRBeginScope(scope, PBRTargetLegacyID(request));
}

static void PBRFindMatch(id receiver, SEL selector, GKMatchRequest *request, id completion) {
    if (!PBRShouldInterceptTrading() || !request) {
        if (PBROriginalFindMatch) ((void (*)(id, SEL, GKMatchRequest *, id))PBROriginalFindMatch)(receiver, selector, request, completion);
        return;
    }
    PBRBeginBackendMatch(request);
}

static void PBRMatchForInvite(id receiver, SEL selector, GKInvite *invite, id completion) {
    if (!PBRShouldInterceptTrading()) {
        if (PBROriginalMatchForInvite) ((void (*)(id, SEL, GKInvite *, id))PBROriginalMatchForInvite)(receiver, selector, invite, completion);
        return;
    }
    NSString *sender = PBRInviteSenderLegacyID(invite);
    if (sender.length) PBRBeginScope(@"friends", sender);
}

static void PBRSubmitNativeFallback(NSString *name) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL submit = NSSelectorFromString(@"submitNativeFallback:");
    if (name.length && [launcher respondsToSelector:submit]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(launcher, submit, name);
    }
}

static void PBRTradingReadyPan(id receiver, SEL selector, id sender) {
    BOOL wasConfirmed = NO;
    @try { wasConfirmed = [[receiver valueForKey:@"isConfirmed"] boolValue]; } @catch (NSException *ignored) {}
    if (PBROriginalTradeReadyPan) {
        ((void (*)(id, SEL, id))PBROriginalTradeReadyPan)(receiver, selector, sender);
    }
    if (!PBRShouldInterceptTrading()) return;
    BOOL isConfirmed = wasConfirmed;
    @try { isConfirmed = [[receiver valueForKey:@"isConfirmed"] boolValue]; } @catch (NSException *ignored) {}
    if (!wasConfirmed && isConfirmed) PBRSubmitNativeFallback(@"ready");
}

static void PBRTradingAcceptTap(id receiver, SEL selector, id gesture) {
    if (PBROriginalTradeAcceptTap) {
        ((void (*)(id, SEL, id))PBROriginalTradeAcceptTap)(receiver, selector, gesture);
    }
    if (PBRShouldInterceptTrading()) PBRSubmitNativeFallback(@"accept");
}

static void PBRTradingMakeChangesTap(id receiver, SEL selector, id gesture) {
    if (PBROriginalTradeMakeChangesTap) {
        ((void (*)(id, SEL, id))PBROriginalTradeMakeChangesTap)(receiver, selector, gesture);
    }
    if (PBRShouldInterceptTrading()) PBRSubmitNativeFallback(@"makeChanges");
}

static void PBRTradingCancelAcceptTap(id receiver, SEL selector, id gesture) {
    if (PBROriginalTradeCancelAcceptTap) {
        ((void (*)(id, SEL, id))PBROriginalTradeCancelAcceptTap)(receiver, selector, gesture);
    }
    if (PBRShouldInterceptTrading()) PBRSubmitNativeFallback(@"cancelAcceptance");
}

static void PBRStopRevivalMatch(id loadingView) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL cancel = NSSelectorFromString(@"cancelOriginalMatch");
    if ([launcher respondsToSelector:cancel]) {
        ((void (*)(id, SEL))objc_msgSend)(launcher, cancel);
    }
    PBRTradingArmedUntil = 0;

    // Keep PACYBITS inside the Trading menu. Its original cancel handler also
    // executes legacy GameKit navigation and can pop the whole screen/app flow.
    SEL hide = NSSelectorFromString(@"hide");
    if (loadingView && [loadingView respondsToSelector:hide]) {
        ((void (*)(id, SEL))objc_msgSend)(loadingView, hide);
    }

    UIViewController *top = [[PBRRevivalBootstrap shared] topPresenter];
    if ([top isKindOfClass:GKMatchmakerViewController.class]) {
        [top dismissViewControllerAnimated:YES completion:nil];
    }
}

static void PBRTradingLeaveTap(id receiver, SEL selector, id gesture) {
    if (!PBRShouldInterceptTrading()) {
        if (PBROriginalTradeLeaveTap) {
            ((void (*)(id, SEL, id))PBROriginalTradeLeaveTap)(receiver, selector, gesture);
        }
        return;
    }

    // Do not call PACYBITS' retired GameKit leave routine for revival sessions.
    // Cancel our authenticated room first, hide the original leave dialog, and
    // return through the visible controller hierarchy without touching GameKit.
    PBRStopRevivalMatch(receiver);
    UIViewController *trade = PBRCurrentOriginalTrading();
    if (trade.presentedViewController) {
        [trade dismissViewControllerAnimated:NO completion:nil];
    }
    UINavigationController *nav = trade.navigationController;
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:NO];
    } else if (trade.presentingViewController) {
        [trade dismissViewControllerAnimated:NO completion:nil];
    }
}

static void PBRMatchmakerCancel(id receiver, SEL selector) {
    if (PBRShouldInterceptTrading()) {
        PBRStopRevivalMatch(nil);
        return;
    }
    if (PBROriginalMatchmakerCancel) {
        ((void (*)(id, SEL))PBROriginalMatchmakerCancel)(receiver, selector);
    }
}

static void PBROnlineLoadingCancel(id receiver, SEL selector, id gesture) {
    if (PBRShouldInterceptTrading()) {
        PBRStopRevivalMatch(receiver);
        return;
    }
    if (PBROriginalOnlineLoadingCancel) {
        ((void (*)(id, SEL, id))PBROriginalOnlineLoadingCancel)(receiver, selector, gesture);
    }
}

static BOOL PBRInstallMethodHookOnce(Class cls, SEL selector, IMP replacement, IMP *original, BOOL *installed) {
    if (*installed || !cls) return *installed;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP previous = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) *original = previous;
    else *original = method_setImplementation(method, replacement);
    *installed = YES;
    return YES;
}

static void PBRInstallRevivalHooks(void) {
    Class menu = NSClassFromString(@"_TtC13PACYBITSFUT2025TradingMenuViewController");
    PBRInstallMethodHookOnce(menu, NSSelectorFromString(@"buttonTapHandlerWithGesture:"),
                             (IMP)PBRTradingMenuTapHook, &PBROriginalTradingMenuTap, &PBRMenuTapHooked);

    Class code = NSClassFromString(@"_TtC13PACYBITSFUT2017DialogTradingCode");
    if (code && !PBROriginalCodeSearch) {
        Method method = class_getInstanceMethod(code, NSSelectorFromString(@"searchTapHandlerWithGesture:"));
        if (method) PBROriginalCodeSearch = method_getImplementation(method);
    }
    PBRInstallMethodHookOnce(code, NSSelectorFromString(@"didMoveToWindow"),
                             (IMP)PBRCodeDidMoveToWindow, &PBROriginalCodeDidMoveToWindow, &PBRCodeViewHooked);

    Class channels = NSClassFromString(@"_TtC13PACYBITSFUT2021DialogTradingChannels");
    if (channels && !PBROriginalChannelsSearch) {
        Method method = class_getInstanceMethod(channels, NSSelectorFromString(@"searchTapHandlerWithGesture:"));
        if (method) PBROriginalChannelsSearch = method_getImplementation(method);
    }
    PBRInstallMethodHookOnce(channels, NSSelectorFromString(@"didMoveToWindow"),
                             (IMP)PBRChannelsDidMoveToWindow, &PBROriginalChannelsDidMoveToWindow, &PBRChannelsViewHooked);

    Class friends = NSClassFromString(@"_TtC13PACYBITSFUT2020DialogTradingFriends");
    if (friends && !PBROriginalFriendsButton) {
        Method method = class_getInstanceMethod(friends, NSSelectorFromString(@"buttonTapHandlerWithGesture:"));
        if (method) PBROriginalFriendsButton = method_getImplementation(method);
    }
    PBRInstallMethodHookOnce(friends, NSSelectorFromString(@"didMoveToWindow"),
                             (IMP)PBRFriendsDidMoveToWindow, &PBROriginalFriendsDidMoveToWindow, &PBRFriendsViewHooked);

    Class confirmButton = NSClassFromString(@"_TtC13PACYBITSFUT2020TradingConfirmButton");
    PBRInstallMethodHookOnce(confirmButton, NSSelectorFromString(@"panDetectedWithSender:"),
                             (IMP)PBRTradingReadyPan, &PBROriginalTradeReadyPan, &PBRTradeReadyHooked);
    PBRInstallMethodHookOnce(confirmButton, NSSelectorFromString(@"makeChangesTapHandlerWithGesture:"),
                             (IMP)PBRTradingMakeChangesTap, &PBROriginalTradeMakeChangesTap, &PBRTradeMakeChangesHooked);

    Class completeTrade = NSClassFromString(@"_TtC13PACYBITSFUT2026DialogTradingCompleteTrade");
    PBRInstallMethodHookOnce(completeTrade, NSSelectorFromString(@"acceptTapHandlerWithGesture:"),
                             (IMP)PBRTradingAcceptTap, &PBROriginalTradeAcceptTap, &PBRTradeAcceptHooked);
    PBRInstallMethodHookOnce(completeTrade, NSSelectorFromString(@"cancelTapHandlerWithGesture:"),
                             (IMP)PBRTradingCancelAcceptTap, &PBROriginalTradeCancelAcceptTap, &PBRTradeCancelAcceptHooked);

    Class leaveTrade = NSClassFromString(@"_TtC13PACYBITSFUT2023DialogTradingLeaveTrade");
    PBRInstallMethodHookOnce(leaveTrade, NSSelectorFromString(@"leaveTapHandlerWithGesture:"),
                             (IMP)PBRTradingLeaveTap, &PBROriginalTradeLeaveTap, &PBRTradeLeaveHooked);

    Class onlineLoading = NSClassFromString(@"_TtC13PACYBITSFUT2013OnlineLoading");
    PBRInstallMethodHookOnce(onlineLoading, NSSelectorFromString(@"cancelTapHandlerWithGesture:"),
                             (IMP)PBROnlineLoadingCancel, &PBROriginalOnlineLoadingCancel, &PBROnlineLoadingCancelHooked);

    Class about = NSClassFromString(@"_TtC13PACYBITSFUT2019AboutViewController");
    PBRInstallMethodHookOnce(about, @selector(viewDidAppear:),
                             (IMP)PBRAboutViewDidAppear, &PBROriginalAboutViewDidAppear, &PBRAboutViewHooked);

    Class matchmaker = GKMatchmaker.class;
    PBRInstallMethodHookOnce(matchmaker, NSSelectorFromString(@"findMatchForRequest:withCompletionHandler:"),
                             (IMP)PBRFindMatch, &PBROriginalFindMatch, &PBRFindMatchHooked);
    PBRInstallMethodHookOnce(matchmaker, NSSelectorFromString(@"matchForInvite:completionHandler:"),
                             (IMP)PBRMatchForInvite, &PBROriginalMatchForInvite, &PBRInviteHooked);
    PBRInstallMethodHookOnce(matchmaker, NSSelectorFromString(@"cancel"),
                             (IMP)PBRMatchmakerCancel, &PBROriginalMatchmakerCancel, &PBRCancelHooked);
}

static void PBRScheduleHookInstallation(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PBRInstallRevivalHooks();
        BOOL criticalHooksReady = PBRMenuTapHooked && PBROnlineLoadingCancelHooked &&
                                  PBRFindMatchHooked && PBRCancelHooked;
        if (!criticalHooksReady) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                PBRScheduleHookInstallation();
            });
        }
    });
}

static void PBRHealthBeacon(NSString *probe) {
    NSURL *url = [NSURL URLWithString:@"https://pacybits-revival-trading.onrender.com/healthz"];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    if (probe.length) [request setValue:probe forHTTPHeaderField:@"X-Revival-Probe"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request];
    [task resume];
}

void PBRNativeEventProbe(NSString *label) {
    if (!label.length) return;
    NSString *probe = nil;
    if ([label isEqualToString:@"tradingReady"]) probe = @"sender-ready";
    else if ([label isEqualToString:@"tradingCompleteTradeAccept"]) probe = @"sender-accept";
    else if ([label isEqualToString:@"tradingDidSetWishlist"]) probe = @"sender-wishlist";
    else if ([label isEqualToString:@"tradingPickedOutline"]) probe = @"sender-picked";
    else probe = @"sender-other";
    PBRHealthBeacon(probe);
}

__attribute__((constructor)) static void PBRStartRevivalProbe(void) {
    PBRScheduleHookInstallation();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PBRHealthBeacon(@"bootstrap");
    });
}


@interface PBRFakeGKMatch : NSObject
@property(nonatomic, copy) NSArray<GKPlayer *> *players;
@property(nonatomic, weak) id delegate;
@end

@implementation PBRFakeGKMatch
- (instancetype)init {
    self = [super init];
    if (self) {
        GKPlayer *player = GKLocalPlayer.localPlayer;
        _players = player ? @[player] : @[];
    }
    return self;
}
- (BOOL)sendDataToAllPlayers:(NSData *)data
                withDataMode:(GKMatchSendDataMode)mode
                       error:(NSError *__autoreleasing *)error {
    (void)data; (void)mode;
    if (error) *error = nil;
    return YES;
}
- (BOOL)sendData:(NSData *)data
       toPlayers:(NSArray<GKPlayer *> *)players
        dataMode:(GKMatchSendDataMode)mode
           error:(NSError *__autoreleasing *)error {
    (void)data; (void)players; (void)mode;
    if (error) *error = nil;
    return YES;
}
- (void)disconnect {}
- (NSUInteger)expectedPlayerCount { return 0; }
@end

BOOL PBRStartOriginalNativeMatch(NSString *peerAlias) {
    (void)peerAlias;
    PBRHealthBeacon(@"native-start");
    @try {
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        void *raw = *(void **)(uintptr_t)(0x1012be350ULL + slide);
        if (!raw) {
            PBRHealthBeacon(@"native-no-helper");
            return NO;
        }
        id helper = (__bridge id)raw;
        Class expected = NSClassFromString(@"_TtC13PACYBITSFUT2016GameCenterHelper");
        if (!expected || ![helper isKindOfClass:expected]) {
            PBRHealthBeacon(@"native-helper-type-failed");
            return NO;
        }
        SEL selector = NSSelectorFromString(@"matchmakerViewController:didFindMatch:");
        if (![helper respondsToSelector:selector]) {
            PBRHealthBeacon(@"native-no-selector");
            return NO;
        }
        PBRFakeGKMatch *match = [PBRFakeGKMatch new];
        PBRHealthBeacon(@"native-callback");
        ((void (*)(id, SEL, id, id))objc_msgSend)(helper, selector, nil, match);
        PBRHealthBeacon(@"native-return");
        return YES;
    } @catch (NSException *exception) {
        PBRHealthBeacon(@"native-exception");
        return NO;
    }
}

static UIViewController *PBRFindTradingControllerInTree(UIViewController *controller, Class expected) {
    if (!controller || !expected) return nil;
    if ([controller isKindOfClass:expected]) return controller;

    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers.reverseObjectEnumerator) {
            UIViewController *found = PBRFindTradingControllerInTree(child, expected);
            if (found) return found;
        }
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        UIViewController *found = PBRFindTradingControllerInTree(selected, expected);
        if (found) return found;
    }
    if (controller.presentedViewController) {
        UIViewController *found = PBRFindTradingControllerInTree(controller.presentedViewController, expected);
        if (found) return found;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = PBRFindTradingControllerInTree(child, expected);
        if (found) return found;
    }
    return nil;
}

static UIViewController *PBRRawOriginalTrading(void) {
    @try {
        Class expected = NSClassFromString(@"_TtC13PACYBITSFUT2021TradingViewController");
        if (!expected) return nil;
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        void *raw = *(void **)(uintptr_t)(0x1012bef00ULL + slide);
        if (!raw) return nil;
        id controller = (__bridge id)raw;
        return [controller isKindOfClass:expected] ? controller : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

static BOOL PBRControllerIsAttached(UIViewController *controller) {
    if (!controller) return NO;
    if (controller.presentingViewController || controller.navigationController) return YES;
    return controller.isViewLoaded && controller.view.window != nil;
}

UIViewController *PBRCurrentOriginalTrading(void) {
    Class expected = NSClassFromString(@"_TtC13PACYBITSFUT2021TradingViewController");
    if (!expected) {
        PBRHealthBeacon(@"screen-missing");
        return nil;
    }

    UIViewController *raw = PBRRawOriginalTrading();
    if (raw && PBRControllerIsAttached(raw)) {
        PBRHealthBeacon(@"screen-found");
        return raw;
    }

    UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
    UIViewController *found = PBRFindTradingControllerInTree(window.rootViewController, expected);
    if (found && PBRControllerIsAttached(found)) {
        PBRHealthBeacon(@"screen-found");
        return found;
    }

    PBRHealthBeacon(@"screen-missing");
    return nil;
}

UIViewController *PBRPresentOriginalTradingFallback(void) {
    UIViewController *existing = PBRCurrentOriginalTrading();
    if (existing) return existing;

    UIViewController *presenter = [[PBRRevivalBootstrap shared] topPresenter];
    if (!presenter || !presenter.isViewLoaded || presenter.view.window == nil) return nil;

    // A PACYBITS match-found callback can leave a configured TradingViewController
    // detached. Reuse it only when UIKit considers it parentless; presenting an
    // instance that still belongs to another controller hierarchy is ignored.
    UIViewController *controller = PBRRawOriginalTrading();
    if (controller.parentViewController != nil ||
        controller.presentingViewController != nil ||
        controller.navigationController != nil) {
        controller = nil;
    }
    if (!controller) controller = PBRInstantiateOriginalTrading();
    if (!controller || presenter == controller) return controller;

    controller.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:controller animated:NO completion:nil];
    return controller;
}

NSArray<NSString *> *PBRCurrentWishlistIdentifiers(void) {
    @try {
        NSMutableArray *candidates = [NSMutableArray array];

        UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
        UIViewController *root = window.rootViewController;
        NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
        if (root) [queue addObject:root];
        Class menuClass = NSClassFromString(@"_TtC13PACYBITSFUT2025TradingMenuViewController");
        while (queue.count) {
            UIViewController *controller = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if (menuClass && [controller isKindOfClass:menuClass]) {
                @try {
                    id cards = [controller valueForKey:@"wishlistCards"];
                    if ([cards isKindOfClass:NSArray.class]) [candidates addObjectsFromArray:cards];
                } @catch (NSException *ignored) {}
            }
            if (controller.presentedViewController) [queue addObject:controller.presentedViewController];
            [queue addObjectsFromArray:controller.childViewControllers ?: @[]];
            if ([controller isKindOfClass:UINavigationController.class]) {
                [queue addObjectsFromArray:((UINavigationController *)controller).viewControllers ?: @[]];
            } else if ([controller isKindOfClass:UITabBarController.class]) {
                [queue addObjectsFromArray:((UITabBarController *)controller).viewControllers ?: @[]];
            }
        }

        // DialogTradingNeeds owns a populated wishlistPlayers array. Search the
        // attached view hierarchy as a secondary source when that dialog exists.
        Class needsClass = NSClassFromString(@"_TtC13PACYBITSFUT2018DialogTradingNeeds");
        NSMutableArray<UIView *> *views = [NSMutableArray array];
        if (window) [views addObject:window];
        while (views.count) {
            UIView *view = views.firstObject;
            [views removeObjectAtIndex:0];
            if (needsClass && [view isKindOfClass:needsClass]) {
                @try {
                    Ivar ivar = class_getInstanceVariable(needsClass, "wishlistPlayers");
                    id players = ivar ? object_getIvar(view, ivar) : nil;
                    if ([players isKindOfClass:NSArray.class]) [candidates addObjectsFromArray:players];
                } @catch (NSException *ignored) {}
            }
            [views addObjectsFromArray:view.subviews ?: @[]];
        }

        NSMutableArray<NSString *> *result = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (id item in candidates) {
            NSString *identifier = nil;
            if ([item isKindOfClass:NSString.class]) identifier = item;
            else if ([item isKindOfClass:NSNumber.class]) identifier = [item stringValue];
            else identifier = PBRPlayerIdentifier(item);
            if (identifier.length && ![seen containsObject:identifier] && PBRPlayerForIdentifier(identifier)) {
                [seen addObject:identifier];
                [result addObject:identifier];
                if (result.count >= 50) break;
            }
        }
        return result;
    } @catch (NSException *exception) {
        return @[];
    }
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
        // Wishlist UI arrays can contain card/view wrappers rather than the
        // underlying Player model. Resolve one level of known wrappers too.
        for (NSString *nestedKey in @[@"player", @"playerObject", @"playerModel", @"cardPlayer"]) {
            @try {
                id nested = [player valueForKey:nestedKey];
                if (nested && nested != player) {
                    NSString *resolved = PBRPlayerIdentifier(nested);
                    if (resolved.length) return resolved;
                }
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
