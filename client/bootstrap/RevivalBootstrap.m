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
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}
@end

@interface PBRRevivalBootstrap (TradingTiles)
- (void)tradingTileTapped:(UITapGestureRecognizer *)gesture;
- (void)codeSearchTapped:(UITapGestureRecognizer *)gesture;
- (void)channelsSearchTapped:(UITapGestureRecognizer *)gesture;
- (void)friendsSearchTapped:(UITapGestureRecognizer *)gesture;
@end

// PACYBITS remains responsible for every visible trading screen. This layer only
// replaces authentication and multiplayer transport with Google/Firebase/Render.
static CFTimeInterval PBRTradingArmedUntil = 0;
static IMP PBROriginalTradingMenuTap = NULL;
static IMP PBROriginalTradingMenuViewDidAppear = NULL;
static IMP PBROriginalCodeDidMoveToWindow = NULL;
static IMP PBROriginalChannelsDidMoveToWindow = NULL;
static IMP PBROriginalFriendsDidMoveToWindow = NULL;
static IMP PBROriginalCodeSearch = NULL;
static IMP PBROriginalChannelsSearch = NULL;
static IMP PBROriginalFriendsButton = NULL;
static IMP PBROriginalFindMatch = NULL;
static IMP PBROriginalMatchForInvite = NULL;
static IMP PBROriginalMatchmakerCancel = NULL;

static BOOL PBRMenuViewHooked = NO;
static BOOL PBRCodeViewHooked = NO;
static BOOL PBRChannelsViewHooked = NO;
static BOOL PBRFriendsViewHooked = NO;
static BOOL PBRCodeHooked = NO;
static BOOL PBRChannelsHooked = NO;
static BOOL PBRFriendsHooked = NO;
static BOOL PBRFindMatchHooked = NO;
static BOOL PBRInviteHooked = NO;
static BOOL PBRCancelHooked = NO;

static char PBRButtonWiredKey;
static char PBRGestureControllerKey;
static char PBRGestureModeKey;

static BOOL PBRTradingIsArmed(void) {
    return PBRTradingArmedUntil > CACurrentMediaTime();
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

static void PBRBeginScope(NSString *scope, NSString *target) {
    UIViewController *presenter = [[PBRRevivalBootstrap shared] topPresenter];
    if (!presenter || !scope.length) return;
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL begin = NSSelectorFromString(@"beginOriginalMatchFrom:scope:targetLegacyID:localLegacyID:");
    if (![launcher respondsToSelector:begin]) return;
    ((void (*)(id, SEL, UIViewController *, NSString *, NSString *, NSString *))objc_msgSend)(
        launcher, begin, presenter, scope, target, PBRLocalLegacyID());
}

static void PBRPrepareGoogle(UIViewController *presenter, void (^completion)(BOOL)) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL prepare = NSSelectorFromString(@"prepareTradingFrom:completion:");
    if (![launcher respondsToSelector:prepare]) { completion(NO); return; }
    ((void (*)(id, SEL, UIViewController *, id))objc_msgSend)(launcher, prepare, presenter, completion);
}

static NSString *PBRNormalizedCode(id receiver);

static void PBRWireTradingMenu(id receiver) {
    if (!receiver || !PBROriginalTradingMenuTap) return;
    for (NSString *getter in @[@"channelsButton", @"friendsButton", @"codeButton", @"randomButton"]) {
        id value = PBRDynamicValue(receiver, getter);
        if (![value isKindOfClass:UIView.class]) continue;
        UIView *button = value;
        if ([objc_getAssociatedObject(button, &PBRButtonWiredKey) boolValue]) continue;
        for (UIGestureRecognizer *existing in [button.gestureRecognizers copy]) {
            if ([existing isKindOfClass:UITapGestureRecognizer.class]) [button removeGestureRecognizer:existing];
        }
        button.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[PBRRevivalBootstrap shared]
                                                                              action:@selector(tradingTileTapped:)];
        objc_setAssociatedObject(tap, &PBRGestureControllerKey,
                                 [NSValue valueWithNonretainedObject:receiver],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *mode = [getter stringByReplacingOccurrencesOfString:@"Button" withString:@""];
        objc_setAssociatedObject(tap, &PBRGestureModeKey, mode, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [button addGestureRecognizer:tap];
        objc_setAssociatedObject(button, &PBRButtonWiredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void PBRTradingMenuViewDidAppear(id receiver, SEL selector, BOOL animated) {
    if (PBROriginalTradingMenuViewDidAppear) {
        ((void (*)(id, SEL, BOOL))PBROriginalTradingMenuViewDidAppear)(receiver, selector, animated);
    }
    PBRWireTradingMenu(receiver);
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
        ((void (*)(id, SEL, id))PBROriginalTradingMenuTap)(
            receiver, NSSelectorFromString(@"buttonTapHandlerWithGesture:"), gesture);
        NSString *mode = objc_getAssociatedObject(gesture, &PBRGestureModeKey);
        if ([mode isEqualToString:@"random"]) {
            PBRBeginScope(@"random", nil);
        }
    });
}
- (void)codeSearchTapped:(UITapGestureRecognizer *)gesture {
    id receiver = [objc_getAssociatedObject(gesture, &PBRGestureControllerKey) nonretainedObjectValue];
    if (!receiver || !PBROriginalCodeSearch) return;
    NSString *code = PBRNormalizedCode(receiver);
    ((void (*)(id, SEL, id))PBROriginalCodeSearch)(
        receiver, NSSelectorFromString(@"searchTapHandlerWithGesture:"), gesture);
    if (code.length) PBRBeginScope([@"code:" stringByAppendingString:code], nil);
}
- (void)channelsSearchTapped:(UITapGestureRecognizer *)gesture {
    id receiver = [objc_getAssociatedObject(gesture, &PBRGestureControllerKey) nonretainedObjectValue];
    if (!receiver || !PBROriginalChannelsSearch) return;
    id collection = PBRDynamicValue(receiver, @"collectionView");
    NSArray *selected = [collection respondsToSelector:@selector(indexPathsForSelectedItems)]
        ? [collection indexPathsForSelectedItems] : nil;
    NSIndexPath *path = selected.firstObject;
    ((void (*)(id, SEL, id))PBROriginalChannelsSearch)(
        receiver, NSSelectorFromString(@"searchTapHandlerWithGesture:"), gesture);
    if (path) {
        PBRBeginScope([NSString stringWithFormat:@"channel:%ld:%ld",
                       (long)path.section, (long)path.item], nil);
    }
}
- (void)friendsSearchTapped:(UITapGestureRecognizer *)gesture {
    id receiver = [objc_getAssociatedObject(gesture, &PBRGestureControllerKey) nonretainedObjectValue];
    if (!receiver || !PBROriginalFriendsButton) return;
    ((void (*)(id, SEL, id))PBROriginalFriendsButton)(
        receiver, NSSelectorFromString(@"buttonTapHandlerWithGesture:"), gesture);
    NSString *target = PBRInvitedFriendLegacyID();
    if (target.length) {
        PBRBeginScope(@"friends", target);
        return;
    }
    id table = PBRDynamicValue(receiver, @"tableView");
    NSIndexPath *row = [table respondsToSelector:@selector(indexPathForSelectedRow)]
        ? [table indexPathForSelectedRow] : nil;
    if (row) PBRBeginScope([NSString stringWithFormat:@"friends-row:%ld", (long)row.row], nil);
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

static NSString *PBRNormalizedCode(id receiver) {
    id field = PBRDynamicValue(receiver, @"textField");
    if (![field respondsToSelector:@selector(text)]) field = PBRDynamicValue(receiver, @"text_field");
    NSString *text = [field respondsToSelector:@selector(text)] ? [field text] : nil;
    text = [[text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if (text.length < 3 || text.length > 32) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    return [[text stringByTrimmingCharactersInSet:allowed] length] == 0 ? text : nil;
}

static void PBRCodeSearch(id receiver, SEL selector, id gesture) {
    NSString *code = PBRNormalizedCode(receiver);
    if (!code.length || !PBROriginalCodeSearch) {
        if (PBROriginalCodeSearch) ((void (*)(id, SEL, id))PBROriginalCodeSearch)(receiver, selector, gesture);
        return;
    }
    PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
    ((void (*)(id, SEL, id))PBROriginalCodeSearch)(receiver, selector, gesture);
    PBRBeginScope([@"code:" stringByAppendingString:code], nil);
}

static void PBRChannelsSearch(id receiver, SEL selector, id gesture) {
    id collection = PBRDynamicValue(receiver, @"collectionView");
    NSArray *selected = [collection respondsToSelector:@selector(indexPathsForSelectedItems)] ? [collection indexPathsForSelectedItems] : nil;
    NSIndexPath *path = selected.firstObject;
    if (!path || !PBROriginalChannelsSearch) {
        if (PBROriginalChannelsSearch) ((void (*)(id, SEL, id))PBROriginalChannelsSearch)(receiver, selector, gesture);
        return;
    }
    NSString *scope = [NSString stringWithFormat:@"channel:%ld:%ld", (long)path.section, (long)path.item];
    PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
    ((void (*)(id, SEL, id))PBROriginalChannelsSearch)(receiver, selector, gesture);
    PBRBeginScope(scope, nil);
}

static void PBRFriendsButton(id receiver, SEL selector, id gesture) {
    if (!PBROriginalFriendsButton) return;
    PBRTradingArmedUntil = CACurrentMediaTime() + 300.0;
    ((void (*)(id, SEL, id))PBROriginalFriendsButton)(receiver, selector, gesture);
    NSString *target = PBRInvitedFriendLegacyID();
    if (target.length) {
        PBRBeginScope(@"friends", target);
    } else {
        id table = PBRDynamicValue(receiver, @"tableView");
        NSIndexPath *row = [table respondsToSelector:@selector(indexPathForSelectedRow)] ? [table indexPathForSelectedRow] : nil;
        if (row) PBRBeginScope([NSString stringWithFormat:@"friends-row:%ld", (long)row.row], nil);
    }
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

static void PBRBeginBackendMatch(GKMatchRequest *request) {
    NSInteger group = request.playerGroup;
    NSUInteger attributes = request.playerAttributes;
    NSString *scope = [NSString stringWithFormat:@"g:%ld:a:%lu", (long)group, (unsigned long)attributes];
    PBRBeginScope(scope, PBRTargetLegacyID(request));
}

static void PBRFindMatch(id receiver, SEL selector, GKMatchRequest *request, id completion) {
    if (!PBRTradingIsArmed() || !request) {
        if (PBROriginalFindMatch) ((void (*)(id, SEL, GKMatchRequest *, id))PBROriginalFindMatch)(receiver, selector, request, completion);
        return;
    }
    PBRBeginBackendMatch(request);
}

static void PBRMatchForInvite(id receiver, SEL selector, GKInvite *invite, id completion) {
    if (!PBRTradingIsArmed()) {
        if (PBROriginalMatchForInvite) ((void (*)(id, SEL, GKInvite *, id))PBROriginalMatchForInvite)(receiver, selector, invite, completion);
        return;
    }
    PBRBeginScope(@"invite", nil);
}

static void PBRMatchmakerCancel(id receiver, SEL selector) {
    if (PBRTradingIsArmed()) {
        Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
        SEL cancel = NSSelectorFromString(@"cancelOriginalMatch");
        if ([launcher respondsToSelector:cancel]) ((void (*)(id, SEL))objc_msgSend)(launcher, cancel);
        PBRTradingArmedUntil = 0;
    }
    if (PBROriginalMatchmakerCancel) ((void (*)(id, SEL))PBROriginalMatchmakerCancel)(receiver, selector);
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
    if (menu && !PBROriginalTradingMenuTap) {
        Method tap = class_getInstanceMethod(menu, NSSelectorFromString(@"buttonTapHandlerWithGesture:"));
        if (tap) PBROriginalTradingMenuTap = method_getImplementation(tap);
    }
    PBRInstallMethodHookOnce(menu, NSSelectorFromString(@"viewDidAppear:"),
                             (IMP)PBRTradingMenuViewDidAppear, &PBROriginalTradingMenuViewDidAppear, &PBRMenuViewHooked);

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

    Class matchmaker = GKMatchmaker.class;
    PBRInstallMethodHookOnce(matchmaker, NSSelectorFromString(@"findMatchForRequest:withCompletionHandler:"),
                             (IMP)PBRFindMatch, &PBROriginalFindMatch, &PBRFindMatchHooked);
    PBRInstallMethodHookOnce(matchmaker, NSSelectorFromString(@"matchForInvite:completionHandler:"),
                             (IMP)PBRMatchForInvite, &PBROriginalMatchForInvite, &PBRInviteHooked);
    PBRInstallMethodHookOnce(matchmaker, NSSelectorFromString(@"cancel"),
                             (IMP)PBRMatchmakerCancel, &PBROriginalMatchmakerCancel, &PBRCancelHooked);
}

__attribute__((constructor)) static void PBRStartRevivalProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PBRInstallRevivalHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PBRInstallRevivalHooks(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PBRInstallRevivalHooks(); });
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
