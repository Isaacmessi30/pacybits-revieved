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
- (void)tradingMessageFallbackTapped:(UITapGestureRecognizer *)gesture;
- (void)revivalAcceptTapped:(UITapGestureRecognizer *)gesture;
- (void)revivalCancelTapped:(UITapGestureRecognizer *)gesture;
- (void)revivalCompleteDialogTapped:(UITapGestureRecognizer *)gesture;
- (void)revivalMakeChangesTapped:(UITapGestureRecognizer *)gesture;
- (void)revivalChatOverlayPressed:(UIButton *)sender;
- (void)revivalAcceptOverlayPressed:(UIButton *)sender;
- (void)revivalCancelOverlayPressed:(UIButton *)sender;
- (void)revivalMakeChangesOverlayPressed:(UIButton *)sender;
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
static IMP PBROriginalWishlistCardsSetter = NULL;
static IMP PBROriginalMessageDoneTap = NULL;
static IMP PBROriginalWishlistDoneTap = NULL;
static IMP PBROriginalTradingChatTap = NULL;
static IMP PBROriginalTradingCardOutlineTap = NULL;
static IMP PBROriginalDuplicatesDidSelect = NULL;
static IMP PBROriginalCoinsConfirmTap = NULL;
static IMP PBROriginalMessageReturn = NULL;
static IMP PBROriginalMessageDidMoveToWindow = NULL;
static IMP PBROriginalTradingCardDeleteTap = NULL;
static IMP PBROriginalTradingCardSetCard = NULL;
static IMP PBROriginalCompleteTradeDidMove = NULL;
static IMP PBROriginalConfirmButtonDidMove = NULL;
static NSInteger PBRPendingLocalOfferSlot = NSNotFound;
static NSMutableDictionary<NSNumber *, NSString *> *PBRTrackedOfferCards = nil;
static NSInteger PBRTrackedOfferCoins = 0;
static BOOL PBRResettingTradeUI = NO;
static BOOL PBRTradeOverlayWatchStarted = NO;
static char PBRChatOverlayKey;
static char PBRAcceptOverlayKey;
static char PBRCancelOverlayKey;
static char PBRMakeChangesOverlayKey;
static UIButton *PBRAcceptWindowOverlay = nil;
static UIButton *PBRCancelWindowOverlay = nil;
static id PBRCompleteTradeNibOwner = nil;
static UIView *PBRCompleteTradeNibRoot = nil;
static NSMutableArray<NSString *> *PBRCachedWishlistIdentifiers = nil;
static UIViewController *PBRLastTradingMenuController = nil;
static __weak UINavigationController *PBRLastTradingNavigationController = nil;
static __weak UITabBarController *PBRLastTradingTabController = nil;

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
static BOOL PBRWishlistCardsHooked = NO;
static BOOL PBRMessageDoneHooked = NO;
static BOOL PBRWishlistDoneHooked = NO;
static BOOL PBRTradingChatHooked = NO;
static BOOL PBRTradingCardOutlineHooked = NO;
static BOOL PBRDuplicatesSelectHooked = NO;
static BOOL PBRCoinsConfirmHooked = NO;
static BOOL PBRMessageReturnHooked = NO;
static BOOL PBRMessageDidMoveHooked = NO;
static BOOL PBRTradingCardDeleteHooked = NO;
static BOOL PBRTradingCardSetCardHooked = NO;
static BOOL PBRCompleteTradeDidMoveHooked = NO;
static BOOL PBRConfirmButtonDidMoveHooked = NO;

static char PBRButtonWiredKey;
static char PBRGestureControllerKey;
static char PBRGestureModeKey;
static char PBRAboutControlsKey;
static char PBRAboutControllerKey;

NSString *PBRPlayerIdentifier(id player);
id PBRPlayerForIdentifier(NSString *identifier);
static void PBRHealthBeacon(NSString *probe);
static BOOL PBRShouldInterceptTrading(void);
static BOOL PBRTradingIsArmed(void);
static BOOL PBRRevivalMatchActive(void);
static void PBRSubmitNativeFallback(NSString *name);
static UIViewController *PBRRawOriginalTrading(void);
static UIView *PBRFindViewOfClass(UIView *root, Class cls);
static void PBRInstallMessageButtonFallback(void);

static void PBRCaptureWishlistObject(id item,
                                     NSMutableArray<NSString *> *result,
                                     NSMutableSet<NSString *> *seen,
                                     NSUInteger depth) {
    if (!item || result.count >= 50 || depth > 5) return;
    if ([item isKindOfClass:NSString.class] || [item isKindOfClass:NSNumber.class]) {
        NSString *identifier = [item isKindOfClass:NSString.class] ? item : [item stringValue];
        if (identifier.length && ![seen containsObject:identifier]) {
            [seen addObject:identifier];
            [result addObject:identifier];
        }
        return;
    }
    if ([item isKindOfClass:NSArray.class] || [item isKindOfClass:NSSet.class]) {
        for (id value in item) PBRCaptureWishlistObject(value, result, seen, depth + 1);
        return;
    }
    if ([item isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)item allValues]) PBRCaptureWishlistObject(value, result, seen, depth + 1);
        return;
    }
    NSString *identifier = PBRPlayerIdentifier(item);
    if (identifier.length && ![seen containsObject:identifier]) {
        [seen addObject:identifier];
        [result addObject:identifier];
        return;
    }
    for (NSString *key in @[@"player", @"playerObject", @"playerModel", @"cardPlayer",
                            @"card", @"smallCard", @"object", @"data", @"value"]) {
        @try {
            id nested = [item valueForKey:key];
            if (nested && nested != item) PBRCaptureWishlistObject(nested, result, seen, depth + 1);
        } @catch (NSException *ignored) {}
    }
}

static void PBRCaptureWishlist(id raw) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    PBRCaptureWishlistObject(raw, result, seen, 0);
    PBRCachedWishlistIdentifiers = result;
    if (result.count) PBRHealthBeacon(@"fallback-wishlist");
}

static void PBRPersistNativeWishlist(id value) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL save = NSSelectorFromString(@"saveNativeWishlist:");
    if ([launcher respondsToSelector:save]) {
        ((void (*)(id, SEL, id))objc_msgSend)(launcher, save, value ?: @[]);
    }
}

static void PBRTradingWishlistCardsSetter(id receiver, SEL selector, id cards) {
    if (PBROriginalWishlistCardsSetter) {
        ((void (*)(id, SEL, id))PBROriginalWishlistCardsSetter)(receiver, selector, cards);
    }
    PBRCaptureWishlist(cards);
    if (cards) {
        PBRHealthBeacon(@"wishlist-menu-set");
        PBRPersistNativeWishlist(cards);
    }
}


static void PBRSubmitNativeSignal(NSString *type, id value) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL submit = NSSelectorFromString(@"submitNativeSignal:value:");
    if (type.length && [launcher respondsToSelector:submit]) {
        ((void (*)(id, SEL, NSString *, id))objc_msgSend)(launcher, submit, type, value);
    }
}

static void PBRSyncNativeOfferNow(void) {
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL sel = NSSelectorFromString(@"syncNativeOfferNow");
    if ([launcher respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(launcher, sel);
    }
}

static void PBRSubmitNativePicked(NSInteger slot, NSString *cardID) {
    if (slot < 0 || slot > 2 || !cardID.length) return;
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL sel = NSSelectorFromString(@"submitNativePicked:cardID:");
    if ([launcher respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSInteger, NSString *))objc_msgSend)(launcher, sel, slot, cardID);
    }
}

static void PBRSubmitNativeDeleted(NSInteger slot) {
    if (slot < 0 || slot > 2) return;
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL sel = NSSelectorFromString(@"submitNativeDeleted:");
    if ([launcher respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(launcher, sel, slot);
    }
}

static void PBRSubmitNativeCoins(NSInteger coins) {
    if (coins < 0) return;
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL sel = NSSelectorFromString(@"submitNativeCoins:");
    if ([launcher respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(launcher, sel, coins);
    }
}


static void PBRNavigateOriginalRoute(NSString *route) {
    if (!route.length) return;
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL sel = NSSelectorFromString(@"openOriginalRoute:");
    if ([launcher respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(launcher, sel, route);
    }
}

static void PBREnsureTrackedOffer(void) {
    if (!PBRTrackedOfferCards) PBRTrackedOfferCards = [NSMutableDictionary dictionary];
}

static NSString *PBRIdentifierFromDuplicateSelection(id controller, UICollectionView *collectionView, NSIndexPath *indexPath) {
    // filteredPlayers is a real Swift ivar in the inspected PACYBITS binary
    // (instance offset 208). Use the Objective-C runtime metadata rather than
    // KVC, which is unreliable for this stored Swift field.
    @try {
        Ivar ivar = class_getInstanceVariable(object_getClass(controller) ? [controller class] : Nil, "filteredPlayers");
        if (!ivar) ivar = class_getInstanceVariable([controller class], "filteredPlayers");
        id players = ivar ? object_getIvar(controller, ivar) : nil;
        if ([players isKindOfClass:NSArray.class] && indexPath.item >= 0 &&
            (NSUInteger)indexPath.item < [(NSArray *)players count]) {
            id player = [(NSArray *)players objectAtIndex:(NSUInteger)indexPath.item];
            NSString *identifier = PBRPlayerIdentifier(player);
            if (identifier.length) return identifier;
        }
    } @catch (NSException *ignored) {}

    // CellDuplicate.card is only a visual CardSmall; keep it as a fallback for
    // diagnostics, but the model array above is authoritative for the ID.
    id cell = [collectionView cellForItemAtIndexPath:indexPath];
    NSString *identifier = PBRPlayerIdentifier(cell);
    if (identifier.length) return identifier;
    return nil;
}






static UIButton *PBRInstallControlOverlay(UIView *host, const void *key, SEL action, BOOL disableHostGestures) {
    if (!host) return nil;
    UIButton *overlay = objc_getAssociatedObject(host, key);
    if (![overlay isKindOfClass:UIButton.class] || overlay.superview != host) {
        overlay = [UIButton buttonWithType:UIButtonTypeCustom];
        overlay.frame = host.bounds;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.exclusiveTouch = YES;
        overlay.accessibilityIdentifier = @"pbr-revival-control-overlay";
        [overlay addTarget:[PBRRevivalBootstrap shared] action:action forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:overlay];
        objc_setAssociatedObject(host, key, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        overlay.frame = host.bounds;
        [host bringSubviewToFront:overlay];
    }
    host.userInteractionEnabled = YES;
    overlay.userInteractionEnabled = YES;
    overlay.hidden = NO;
    if (disableHostGestures) {
        for (UIGestureRecognizer *gesture in host.gestureRecognizers) gesture.enabled = NO;
    }
    return overlay;
}

static void PBRRemoveControlOverlay(UIView *host, const void *key, BOOL enableHostGestures) {
    if (!host) return;
    UIView *overlay = objc_getAssociatedObject(host, key);
    [overlay removeFromSuperview];
    objc_setAssociatedObject(host, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (enableHostGestures) {
        for (UIGestureRecognizer *gesture in host.gestureRecognizers) gesture.enabled = YES;
    }
}

static UIButton *PBRInstallWindowOverlay(UIView *target, UIButton * __strong *storage, SEL action) {
    if (!target || !target.window) return nil;
    UIWindow *window = target.window;
    UIButton *overlay = *storage;
    if (![overlay isKindOfClass:UIButton.class] || overlay.superview != window) {
        [overlay removeFromSuperview];
        overlay = [UIButton buttonWithType:UIButtonTypeCustom];
        overlay.backgroundColor = UIColor.clearColor;
        overlay.exclusiveTouch = YES;
        overlay.accessibilityIdentifier = @"pbr-revival-window-control";
        [overlay addTarget:[PBRRevivalBootstrap shared] action:action forControlEvents:UIControlEventTouchUpInside];
        [window addSubview:overlay];
        *storage = overlay;
    }
    CGRect frame = [target convertRect:target.bounds toView:window];
    frame = CGRectInset(frame, -10.0, -8.0);
    overlay.frame = frame;
    overlay.hidden = NO;
    overlay.userInteractionEnabled = YES;
    [window bringSubviewToFront:overlay];
    return overlay;
}

static void PBRRemoveWindowOverlay(UIButton * __strong *storage) {
    UIButton *overlay = *storage;
    [overlay removeFromSuperview];
    *storage = nil;
}

static void PBRRefreshTradeControlOverlays(void) {
    @try {
        UIViewController *trade = PBRRawOriginalTrading();
        if (trade && trade.isViewLoaded && trade.view.window) {
            UIView *chat = [trade valueForKey:@"chatButton"];
            // Do not cover/disable the original chat gestures. The original
            // chatTapHandler opens the real PACYBITS message UI.
            PBRRemoveControlOverlay(chat, &PBRChatOverlayKey, YES);

            UIView *confirm = [trade valueForKey:@"confirmButton"];
            BOOL confirmed = NO;
            @try { confirmed = [[confirm valueForKey:@"isConfirmed"] boolValue]; } @catch (NSException *ignored) {}
            if (confirmed) {
                PBRInstallControlOverlay(confirm, &PBRMakeChangesOverlayKey,
                                         @selector(revivalMakeChangesOverlayPressed:), YES);
            } else {
                PBRRemoveControlOverlay(confirm, &PBRMakeChangesOverlayKey, YES);
            }
        }

        UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
        Class completeClass = NSClassFromString(@"_TtC13PACYBITSFUT2026DialogTradingCompleteTrade");
        id dialogOwner = PBRCompleteTradeNibOwner;
        UIView *dialog = PBRCompleteTradeNibRoot;
        if (!dialogOwner) {
            UIView *legacyDialog = PBRFindViewOfClass(window, completeClass);
            if (legacyDialog) {
                dialogOwner = legacyDialog;
                dialog = legacyDialog;
            }
        }
        if (dialogOwner && dialog && dialog.window) {
            dialog.userInteractionEnabled = YES;
            UIView *accept = nil;
            UIView *cancel = nil;
            @try { accept = [dialogOwner valueForKey:@"acceptButton"]; } @catch (NSException *ignored) {}
            @try { cancel = [dialogOwner valueForKey:@"cancelButton"]; } @catch (NSException *ignored) {}

            // Child overlays remain as a fallback, but window-level overlays sit
            // above PACYBITS' disabled/blocking hierarchy and own the tap.
            PBRInstallControlOverlay(accept, &PBRAcceptOverlayKey,
                                     @selector(revivalAcceptOverlayPressed:), YES);
            PBRInstallControlOverlay(cancel, &PBRCancelOverlayKey,
                                     @selector(revivalCancelOverlayPressed:), YES);
            PBRInstallWindowOverlay(accept, &PBRAcceptWindowOverlay,
                                    @selector(revivalAcceptOverlayPressed:));
            PBRInstallWindowOverlay(cancel, &PBRCancelWindowOverlay,
                                    @selector(revivalCancelOverlayPressed:));
        } else {
            PBRRemoveWindowOverlay(&PBRAcceptWindowOverlay);
            PBRRemoveWindowOverlay(&PBRCancelWindowOverlay);
        }
    } @catch (NSException *ignored) {}
}

static void PBRTradeOverlayWatchTick(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PBRRefreshTradeControlOverlays();
        PBRTradeOverlayWatchTick();
    });
}

static void PBRStartTradeOverlayWatch(void) {
    if (PBRTradeOverlayWatchStarted) return;
    PBRTradeOverlayWatchStarted = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ PBRTradeOverlayWatchTick(); });
}

static void PBRTradingCardSetCard(id receiver, SEL selector, id card) {
    if (PBROriginalTradingCardSetCard) {
        ((void (*)(id, SEL, id))PBROriginalTradingCardSetCard)(receiver, selector, card);
    }
    if (PBRResettingTradeUI || !(PBRRevivalMatchActive() || PBRTradingIsArmed())) return;

    @try {
        UIViewController *trade = PBRRawOriginalTrading();
        NSArray *left = [trade valueForKey:@"cardsLeft"];
        if (![left isKindOfClass:NSArray.class]) return;
        NSUInteger found = [left indexOfObjectIdenticalTo:receiver];
        if (found == NSNotFound || found >= 3) return;
        NSInteger slot = (NSInteger)found;

        PBREnsureTrackedOffer();
        if (!card) {
            if (PBRTrackedOfferCards[@(slot)] != nil) {
                [PBRTrackedOfferCards removeObjectForKey:@(slot)];
                PBRSubmitNativeDeleted(slot);
            }
            return;
        }

        NSString *identifier = PBRPlayerIdentifier(card);
        if (!identifier.length) {
            @try { identifier = PBRPlayerIdentifier([card valueForKey:@"player"]); }
            @catch (NSException *ignored) {}
        }
        if (identifier.length && ![PBRTrackedOfferCards[@(slot)] isEqualToString:identifier]) {
            PBRTrackedOfferCards[@(slot)] = identifier;
            PBRSubmitNativePicked(slot, identifier);
        }
    } @catch (NSException *ignored) {}
}

static void PBRReplaceTapGestures(UIView *view, id target, SEL action) {
    if (!view) return;
    for (UIGestureRecognizer *gesture in [view.gestureRecognizers copy]) {
        if ([gesture isKindOfClass:UITapGestureRecognizer.class]) {
            [view removeGestureRecognizer:gesture];
        }
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:action];
    tap.cancelsTouchesInView = YES;
    [view addGestureRecognizer:tap];
    view.userInteractionEnabled = YES;
}

static void PBRCompleteTradeDidMoveToWindow(id receiver, SEL selector) {
    if (PBROriginalCompleteTradeDidMove) {
        ((void (*)(id, SEL))PBROriginalCompleteTradeDidMove)(receiver, selector);
    }
    if (![receiver window]) return;
    @try {
        UIView *accept = [receiver valueForKey:@"acceptButton"];
        UIView *cancel = [receiver valueForKey:@"cancelButton"];
        PBRReplaceTapGestures(accept, [PBRRevivalBootstrap shared], @selector(revivalAcceptTapped:));
        PBRReplaceTapGestures(cancel, [PBRRevivalBootstrap shared], @selector(revivalCancelTapped:));

        // Also own the whole dialog hit-test. PACYBITS' nested gesture hierarchy
        // can swallow taps before they reach acceptButton/cancelButton.
        static const void *PBRCompleteDialogTapKey = &PBRCompleteDialogTapKey;
        if (!objc_getAssociatedObject(receiver, PBRCompleteDialogTapKey)) {
            UITapGestureRecognizer *dialogTap = [[UITapGestureRecognizer alloc]
                initWithTarget:[PBRRevivalBootstrap shared]
                        action:@selector(revivalCompleteDialogTapped:)];
            dialogTap.cancelsTouchesInView = NO;
            [receiver addGestureRecognizer:dialogTap];
            objc_setAssociatedObject(receiver, PBRCompleteDialogTapKey, dialogTap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        PBRHealthBeacon(@"complete-dialog-direct-controls");
    } @catch (NSException *ignored) {}
}

static void PBRConfirmButtonDidMoveToWindow(id receiver, SEL selector) {
    if (PBROriginalConfirmButtonDidMove) {
        ((void (*)(id, SEL))PBROriginalConfirmButtonDidMove)(receiver, selector);
    }
    if (![receiver window]) return;
    @try {
        // Preserve the pan recognizer used to Ready. Replace only tap gestures
        // so a tap in the confirmed state maps to Make Changes deterministically.
        PBRReplaceTapGestures((UIView *)receiver, [PBRRevivalBootstrap shared], @selector(revivalMakeChangesTapped:));
        PBRHealthBeacon(@"confirm-button-direct-controls");
    } @catch (NSException *ignored) {}
}

static void PBRRestoreLocalReadyUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *trade = PBRRawOriginalTrading();
            if (!trade) return;
            id confirm = [trade valueForKey:@"confirmButton"];
            if (confirm) {
                @try { [confirm setValue:@NO forKey:@"isConfirmed"]; } @catch (NSException *ignored) {}
                @try { [confirm setUserInteractionEnabled:YES]; } @catch (NSException *ignored) {}
                @try {
                    NSLayoutConstraint *constraint = [confirm valueForKey:@"dragConstraint"];
                    if ([constraint isKindOfClass:NSLayoutConstraint.class]) constraint.constant = 0.0;
                } @catch (NSException *ignored) {}
                @try { [confirm setNeedsLayout]; [confirm layoutIfNeeded]; } @catch (NSException *ignored) {}
            }

            Class completeClass = NSClassFromString(@"_TtC13PACYBITSFUT2026DialogTradingCompleteTrade");
            UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
            UIView *dialog = PBRFindViewOfClass(window, completeClass);
            if (dialog) {
                [dialog removeFromSuperview];
                PBRHealthBeacon(@"ready-cancel-dialog-removed");
            }
            PBRHealthBeacon(@"ready-cancel-ui-restored");
        } @catch (NSException *exception) {
            PBRHealthBeacon(@"ready-cancel-ui-failed");
        }
    });
}

static void PBRTradingMessageDidMoveToWindow(id receiver, SEL selector) {
    if (PBROriginalMessageDidMoveToWindow) {
        ((void (*)(id, SEL))PBROriginalMessageDidMoveToWindow)(receiver, selector);
    }
    if (![receiver window]) return;
    @try {
        id field = [receiver valueForKey:@"textField"];
        id button = [receiver valueForKey:@"button"];
        [field setUserInteractionEnabled:YES];
        [button setUserInteractionEnabled:YES];
    } @catch (NSException *ignored) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ PBRInstallMessageButtonFallback(); });
    PBRHealthBeacon(@"message-dialog-visible");
}

static void PBRTradingMessageDoneTap(id receiver, SEL selector, id gesture) {
    NSString *message = nil;
    @try {
        id field = [receiver valueForKey:@"textField"];
        if ([field respondsToSelector:@selector(text)]) message = [field text];
    } @catch (NSException *ignored) {}
    NSString *trimmed = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        PBRHealthBeacon(@"fallback-message");
        PBRSubmitNativeSignal(@"tradingDidSetMessage", trimmed);
    }
    if (PBROriginalMessageDoneTap) {
        ((void (*)(id, SEL, id))PBROriginalMessageDoneTap)(receiver, selector, gesture);
    }
}

static void PBRTradingWishlistDoneTap(id receiver, SEL selector, id gesture) {
    NSMutableArray *rawWishlist = [NSMutableArray array];
    @try {
        UICollectionView *collection = [receiver valueForKey:@"collectionView"];
        for (UICollectionViewCell *cell in collection.visibleCells) {
            id card = nil;
            @try { card = [cell valueForKey:@"card"]; } @catch (NSException *ignored) {}
            if (card) [rawWishlist addObject:card];
        }
    } @catch (NSException *ignored) {}

    // If the collection has offscreen items, ask its data source for every cell
    // before the original handler closes the dialog.
    @try {
        UICollectionView *collection = [receiver valueForKey:@"collectionView"];
        NSInteger sections = [collection numberOfSections];
        for (NSInteger section = 0; section < sections; section++) {
            NSInteger items = [collection numberOfItemsInSection:section];
            for (NSInteger item = 0; item < items; item++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForItem:item inSection:section];
                UICollectionViewCell *cell = [collection cellForItemAtIndexPath:indexPath];
                id card = nil;
                @try { card = [cell valueForKey:@"card"]; } @catch (NSException *ignored) {}
                if (card && ![rawWishlist containsObject:card]) [rawWishlist addObject:card];
            }
        }
    } @catch (NSException *ignored) {}

    if (rawWishlist.count) PBRCaptureWishlist(rawWishlist);

    if (PBROriginalWishlistDoneTap) {
        ((void (*)(id, SEL, id))PBROriginalWishlistDoneTap)(receiver, selector, gesture);
    }

    if (PBRShouldInterceptTrading()) {
        PBRHealthBeacon(rawWishlist.count ? @"fallback-wishlist-dialog" : @"fallback-wishlist-dialog-empty");
        PBRPersistNativeWishlist(rawWishlist);
        PBRSubmitNativeSignal(@"tradingDidSetWishlist", rawWishlist);
    }
}


static char PBRMessageDialogAssociationKey;
static char PBRMessageButtonFallbackInstalledKey;

static UIView *PBRFindSubviewOfClass(UIView *root, Class expected) {
    if (!root || !expected) return nil;
    if ([root isKindOfClass:expected]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = PBRFindSubviewOfClass(child, expected);
        if (found) return found;
    }
    return nil;
}

static void PBRInstallMessageButtonFallback(void) {
    UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
    Class dialogClass = NSClassFromString(@"_TtC13PACYBITSFUT2020DialogTradingMessage");
    id dialog = PBRFindSubviewOfClass(window, dialogClass);
    if (!dialog) return;

    id button = nil;
    @try { button = [dialog valueForKey:@"button"]; } @catch (NSException *ignored) {}
    if (![button isKindOfClass:UIView.class]) return;
    if ([objc_getAssociatedObject(button, &PBRMessageButtonFallbackInstalledKey) boolValue]) return;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:[PBRRevivalBootstrap shared]
        action:@selector(tradingMessageFallbackTapped:)];
    tap.cancelsTouchesInView = NO;
    objc_setAssociatedObject(tap, &PBRMessageDialogAssociationKey,
                             [NSValue valueWithNonretainedObject:dialog],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [button addGestureRecognizer:tap];
    objc_setAssociatedObject(button, &PBRMessageButtonFallbackInstalledKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PBRHealthBeacon(@"message-fallback-installed");
}

static void PBRTradingChatTap(id receiver, SEL selector, id gesture) {
    // Preserve PACYBITS' real chat/message interaction. The previous revival
    // shortcut incorrectly sent messageLeft (the player's status, e.g. "LOL")
    // instead of opening the original message UI.
    if (PBROriginalTradingChatTap) {
        ((void (*)(id, SEL, id))PBROriginalTradingChatTap)(receiver, selector, gesture);
    }
    if (PBRRevivalMatchActive() || PBRTradingIsArmed()) {
        PBRHealthBeacon(@"chat-original-open");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PBRInstallMessageButtonFallback(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ PBRInstallMessageButtonFallback(); });
    }
}


static void PBRTradingCardOutlineTap(id receiver, SEL selector, id gesture) {
    PBRPendingLocalOfferSlot = NSNotFound;
    @try {
        UIViewController *trade = PBRCurrentOriginalTrading();
        NSArray *left = [trade valueForKey:@"cardsLeft"];
        if ([left isKindOfClass:NSArray.class]) {
            NSUInteger found = [left indexOfObjectIdenticalTo:receiver];
            if (found != NSNotFound && found < 3) PBRPendingLocalOfferSlot = (NSInteger)found;
        }
    } @catch (NSException *ignored) {}

    if (PBROriginalTradingCardOutlineTap) {
        ((void (*)(id, SEL, id))PBROriginalTradingCardOutlineTap)(receiver, selector, gesture);
    }
    if (!PBRShouldInterceptTrading()) return;

    PBRHealthBeacon(PBRPendingLocalOfferSlot == NSNotFound ? @"offer-slot-tap-unknown" : @"offer-slot-tap");
    // Original PACYBITS records the selected slot in its helper before routing.
    // GameKit retirement can leave the UI blocked without performing the route,
    // so explicitly enter the original Duplicates controller as a fallback.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class dupClass = NSClassFromString(@"_TtC13PACYBITSFUT2024DuplicatesViewController");
        UIViewController *top = [[PBRRevivalBootstrap shared] topPresenter];
        if (![top isKindOfClass:dupClass]) {
            PBRHealthBeacon(@"offer-slot-open-duplicates");
            PBRNavigateOriginalRoute(@"duplicates");
        }
    });
}

static void PBRTradingCardDeleteTap(id receiver, SEL selector, id gesture) {
    NSInteger slot = NSNotFound;
    @try {
        UIViewController *trade = PBRCurrentOriginalTrading();
        NSArray *left = [trade valueForKey:@"cardsLeft"];
        if ([left isKindOfClass:NSArray.class]) {
            NSUInteger found = [left indexOfObjectIdenticalTo:receiver];
            if (found != NSNotFound && found < 3) slot = (NSInteger)found;
        }
    } @catch (NSException *ignored) {}

    if (PBROriginalTradingCardDeleteTap) {
        ((void (*)(id, SEL, id))PBROriginalTradingCardDeleteTap)(receiver, selector, gesture);
    }
    if (PBRShouldInterceptTrading() && slot != NSNotFound) {
        PBREnsureTrackedOffer();
        [PBRTrackedOfferCards removeObjectForKey:@(slot)];
        PBRHealthBeacon(@"offer-card-deleted");
        PBRSubmitNativeDeleted(slot);
    }
}

static void PBRDuplicatesDidSelect(id receiver, SEL selector, UICollectionView *collectionView, NSIndexPath *indexPath) {
    NSString *selectedIdentifier = PBRIdentifierFromDuplicateSelection(receiver, collectionView, indexPath);
    NSInteger selectedSlot = PBRPendingLocalOfferSlot;

    if (PBROriginalDuplicatesDidSelect) {
        ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))PBROriginalDuplicatesDidSelect)(
            receiver, selector, collectionView, indexPath);
    }
    if (!PBRShouldInterceptTrading() || PBRPendingLocalOfferSlot == NSNotFound) return;

    PBREnsureTrackedOffer();
    if (selectedSlot != NSNotFound && selectedIdentifier.length) {
        PBRTrackedOfferCards[@(selectedSlot)] = selectedIdentifier;
        PBRHealthBeacon(@"offer-card-selected");
        PBRSubmitNativePicked(selectedSlot, selectedIdentifier);
    } else {
        PBRHealthBeacon(@"offer-card-selected-id-missing");
    }
    // PACYBITS' original selection callback owns populating the remembered
    // TradingCard slot and returning to Trading. Resync after that callback has
    // had time to restore the original screen.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ PBRSyncNativeOfferNow(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Some retired GameKit paths remember the selected player but fail to
        // navigate back from Duplicates. Re-enter PACYBITS' original Trading
        // route so viewWillAppear can restore the pending selected slot.
        if (!PBRCurrentOriginalTrading()) {
            PBRHealthBeacon(@"offer-card-return-trading");
            PBRNavigateOriginalRoute(@"trading");
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PBRSyncNativeOfferNow();
        PBRPendingLocalOfferSlot = NSNotFound;
    });
}

static void PBRTradingCoinsConfirmTap(id receiver, SEL selector, id gesture) {
    NSString *value = nil;
    @try {
        id field = [receiver valueForKey:@"textField"];
        if ([field respondsToSelector:@selector(text)]) value = [field text];
    } @catch (NSException *ignored) {}

    if (PBROriginalCoinsConfirmTap) {
        ((void (*)(id, SEL, id))PBROriginalCoinsConfirmTap)(receiver, selector, gesture);
    }
    if (!PBRShouldInterceptTrading()) return;

    PBREnsureTrackedOffer();
    NSMutableString *coinDigits = [NSMutableString string];
    NSCharacterSet *decimal = NSCharacterSet.decimalDigitCharacterSet;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar ch = [value characterAtIndex:i];
        if ([decimal characterIsMember:ch]) [coinDigits appendFormat:@"%C", ch];
    }
    long long parsedCoins = coinDigits.longLongValue;
    PBRTrackedOfferCoins = (parsedCoins >= 0 && parsedCoins <= NSIntegerMax) ? (NSInteger)parsedCoins : 0;
    PBRHealthBeacon(value.length ? @"offer-coins-confirm" : @"offer-coins-empty");
    PBRSubmitNativeCoins(PBRTrackedOfferCoins);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ PBRSyncNativeOfferNow(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ PBRSyncNativeOfferNow(); });
}

static BOOL PBRTradingMessageReturn(id receiver, SEL selector, UITextField *field) {
    NSString *message = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL result = YES;
    if (PBROriginalMessageReturn) {
        result = ((BOOL (*)(id, SEL, UITextField *))PBROriginalMessageReturn)(receiver, selector, field);
    }
    if (message.length) {
        PBRHealthBeacon(@"fallback-message-return");
        PBRSubmitNativeSignal(@"tradingDidSetMessage", message);
    }
    return result;
}

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
    if ([receiver isKindOfClass:UIViewController.class]) {
        PBRLastTradingMenuController = (UIViewController *)receiver;
        PBRLastTradingNavigationController = ((UIViewController *)receiver).navigationController;
        PBRLastTradingTabController = ((UIViewController *)receiver).tabBarController;
    }
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
- (void)tradingMessageFallbackTapped:(UITapGestureRecognizer *)gesture {
    id dialog = [objc_getAssociatedObject(gesture, &PBRMessageDialogAssociationKey) nonretainedObjectValue];
    if (!dialog) return;
    NSString *message = nil;
    @try {
        id field = [dialog valueForKey:@"textField"];
        if ([field respondsToSelector:@selector(text)]) message = [field text];
    } @catch (NSException *ignored) {}
    NSString *trimmed = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        PBRHealthBeacon(@"fallback-message-gesture");
        PBRSubmitNativeSignal(@"tradingDidSetMessage", trimmed);
    }
}

- (void)revivalAcceptTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    PBRHealthBeacon(@"direct-accept");
    PBRSubmitNativeFallback(@"accept");
}

- (void)revivalCancelTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    PBRHealthBeacon(@"direct-cancel-ready");
    PBRRestoreLocalReadyUI();
    PBRSubmitNativeFallback(@"makeChanges");
}

- (void)revivalCompleteDialogTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    UIView *dialog = gesture.view;
    if (!dialog) return;

    UIView *accept = nil;
    UIView *cancel = nil;
    @try {
        accept = [dialog valueForKey:@"acceptButton"];
        cancel = [dialog valueForKey:@"cancelButton"];
    } @catch (NSException *ignored) {}

    CGPoint point = [gesture locationInView:dialog];
    if (accept) {
        CGRect rect = [accept convertRect:accept.bounds toView:dialog];
        rect = CGRectInset(rect, -18.0, -14.0);
        if (CGRectContainsPoint(rect, point)) {
            PBRHealthBeacon(@"dialog-level-accept");
            PBRSubmitNativeFallback(@"accept");
            return;
        }
    }
    if (cancel) {
        CGRect rect = [cancel convertRect:cancel.bounds toView:dialog];
        rect = CGRectInset(rect, -18.0, -14.0);
        if (CGRectContainsPoint(rect, point)) {
            PBRHealthBeacon(@"dialog-level-cancel");
            PBRRestoreLocalReadyUI();
            PBRSubmitNativeFallback(@"makeChanges");
            return;
        }
    }
}

- (void)revivalMakeChangesTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    id view = gesture.view;
    BOOL confirmed = NO;
    @try { confirmed = [[view valueForKey:@"isConfirmed"] boolValue]; } @catch (NSException *ignored) {}
    if (!confirmed) return;
    PBRHealthBeacon(@"direct-make-changes");
    PBRRestoreLocalReadyUI();
    PBRSubmitNativeFallback(@"makeChanges");
}



- (void)revivalChatOverlayPressed:(UIButton *)sender {
    UIViewController *trade = PBRRawOriginalTrading();
    NSString *message = nil;
    @try {
        id label = [trade valueForKey:@"messageLeft"];
        if ([label respondsToSelector:@selector(text)]) message = [label text];
    } @catch (NSException *ignored) {}
    NSString *trimmed = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        sender.alpha = 0.6;
        [UIView animateWithDuration:0.12 animations:^{ sender.alpha = 1.0; }];
        PBRSubmitNativeSignal(@"tradingMessage", trimmed);
    }
}

- (void)revivalAcceptOverlayPressed:(UIButton *)sender {
    sender.userInteractionEnabled = NO;
    PBRSubmitNativeFallback(@"accept");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ sender.userInteractionEnabled = YES; });
}

- (void)revivalCancelOverlayPressed:(UIButton *)sender {
    PBRRestoreLocalReadyUI();
    PBRSubmitNativeFallback(@"makeChanges");
}

- (void)revivalMakeChangesOverlayPressed:(UIButton *)sender {
    PBRRestoreLocalReadyUI();
    PBRSubmitNativeFallback(@"makeChanges");
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
    UIGestureRecognizerState state = UIGestureRecognizerStatePossible;
    CGFloat translationX = 0.0;
    if ([sender isKindOfClass:UIPanGestureRecognizer.class]) {
        UIPanGestureRecognizer *pan = sender;
        state = pan.state;
        translationX = [pan translationInView:receiver].x;
    }

    if (PBROriginalTradeReadyPan) {
        ((void (*)(id, SEL, id))PBROriginalTradeReadyPan)(receiver, selector, sender);
    }
    if (!PBRShouldInterceptTrading()) return;
    PBRHealthBeacon(@"fallback-ready-pan");

    if (state == UIGestureRecognizerStateEnded && fabs(translationX) >= 30.0) {
        @try { [receiver setValue:@YES forKey:@"isConfirmed"]; } @catch (NSException *ignored) {}
        PBRHealthBeacon(@"fallback-ready");
        PBRSubmitNativeFallback(@"ready");
    }
}

static void PBRTradingAcceptTap(id receiver, SEL selector, id gesture) {
    // This dialog only belongs to the revived trading flow. Never call the
    // retired GameKit accept routine; a single tap maps to one backend confirm.
    PBRHealthBeacon(@"fallback-accept");
    PBRSubmitNativeFallback(@"accept");
}

static void PBRTradingMakeChangesTap(id receiver, SEL selector, id gesture) {
    // Make Changes only clears Ready/Accept state; it must never leave the room.
    PBRHealthBeacon(@"fallback-make-changes");
    PBRRestoreLocalReadyUI();
    PBRSubmitNativeFallback(@"makeChanges");
}

static void PBRTradingCancelAcceptTap(id receiver, SEL selector, id gesture) {
    // Cancel on the confirmation dialog means cancel readiness, not leave trade.
    PBRHealthBeacon(@"fallback-cancel-ready");
    PBRRestoreLocalReadyUI();
    PBRSubmitNativeFallback(@"makeChanges");
}


static UIView *PBRFindViewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = PBRFindViewOfClass(child, cls);
        if (found) return found;
    }
    return nil;
}

static id PBRCurrentOnlineLoading(void) {
    Class cls = NSClassFromString(@"_TtC13PACYBITSFUT2013OnlineLoading");
    if (!cls) return nil;
    UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
    if (!window) return nil;
    return PBRFindViewOfClass(window, cls);
}

void PBRShowBackendPlayerFound(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id loading = PBRCurrentOnlineLoading();
        if (!loading) {
            PBRHealthBeacon(@"player-found-loading-missing");
            return;
        }
        @try {
            id status = [loading valueForKey:@"status"];
            if ([status isKindOfClass:UILabel.class]) {
                UILabel *label = status;
                label.text = @"Opponent Found. Connecting...";
                id yellow = nil;
                @try { yellow = [loading valueForKey:@"yellowColor"]; } @catch (NSException *ignored) {}
                if ([yellow isKindOfClass:UIColor.class]) label.textColor = yellow;
                label.alpha = 1.0;
            }
            @try { [loading setValue:@YES forKey:@"shouldStopAnimation"]; } @catch (NSException *ignored) {}
            [loading setValue:@NO forKey:@"shouldStartGameAfterHide"];
            PBRHealthBeacon(@"player-found-shown");
        } @catch (NSException *exception) {
            PBRHealthBeacon(@"player-found-update-failed");
        }
    });
}

void PBRHideBackendMatchLoading(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id loading = PBRCurrentOnlineLoading();
        if (!loading) {
            PBRHealthBeacon(@"player-found-hide-missing");
            return;
        }
        @try { [loading setValue:@NO forKey:@"shouldStartGameAfterHide"]; } @catch (NSException *ignored) {}
        SEL hide = NSSelectorFromString(@"hide:");
        if ([loading respondsToSelector:hide]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(loading, hide, YES);
            PBRHealthBeacon(@"player-found-hidden");
        } else {
            PBRHealthBeacon(@"player-found-hide-selector-missing");
        }
    });
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
    SEL hide = NSSelectorFromString(@"hide:");
    if (loadingView && [loadingView respondsToSelector:hide]) {
        @try { [loadingView setValue:@NO forKey:@"shouldStartGameAfterHide"]; } @catch (NSException *ignored) {}
        ((void (*)(id, SEL, BOOL))objc_msgSend)(loadingView, hide, YES);
    }

    UIViewController *top = [[PBRRevivalBootstrap shared] topPresenter];
    if ([top isKindOfClass:GKMatchmakerViewController.class]) {
        [top dismissViewControllerAnimated:YES completion:nil];
    }
}

static UIViewController *PBRFindControllerOfClassInTree(UIViewController *root, Class expected) {
    if (!root || !expected) return nil;
    if ([root isKindOfClass:expected]) return root;

    if ([root isKindOfClass:UINavigationController.class]) {
        for (UIViewController *vc in ((UINavigationController *)root).viewControllers) {
            UIViewController *found = PBRFindControllerOfClassInTree(vc, expected);
            if (found) return found;
        }
    }
    if ([root isKindOfClass:UITabBarController.class]) {
        for (UIViewController *vc in ((UITabBarController *)root).viewControllers) {
            UIViewController *found = PBRFindControllerOfClassInTree(vc, expected);
            if (found) return found;
        }
    }
    for (UIViewController *vc in root.childViewControllers) {
        UIViewController *found = PBRFindControllerOfClassInTree(vc, expected);
        if (found) return found;
    }
    if (root.presentedViewController) {
        UIViewController *found = PBRFindControllerOfClassInTree(root.presentedViewController, expected);
        if (found) return found;
    }
    return nil;
}

static void PBRTradingLeaveTap(id receiver, SEL selector, id gesture) {
    if (!PBRShouldInterceptTrading()) {
        if (PBROriginalTradeLeaveTap) {
            ((void (*)(id, SEL, id))PBROriginalTradeLeaveTap)(receiver, selector, gesture);
        }
        return;
    }

    // PACYBITS can misroute the Ready/Accept Cancel control through the old
    // post-trade Leave dialog. While the live trade is Ready/Accepting, Cancel
    // means Make Changes and must keep the backend room alive.
    BOOL shouldMakeChanges = NO;
    @try {
        UIViewController *trade = PBRRawOriginalTrading();
        id confirmButton = [trade valueForKey:@"confirmButton"];
        if (confirmButton) {
            id confirmedValue = [confirmButton valueForKey:@"isConfirmed"];
            if ([confirmedValue respondsToSelector:@selector(boolValue)]) {
                shouldMakeChanges = [confirmedValue boolValue];
            }
        }
    } @catch (NSException *ignored) {}

    @try {
        Class completeClass = NSClassFromString(@"_TtC13PACYBITSFUT2026DialogTradingCompleteTrade");
        UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
        UIView *complete = PBRFindViewOfClass(window, completeClass);
        if (complete) shouldMakeChanges = YES;
    } @catch (NSException *ignored) {}

    if (shouldMakeChanges) {
        PBRHealthBeacon(@"leave-rerouted-make-changes");
        PBRRestoreLocalReadyUI();
        PBRSubmitNativeFallback(@"makeChanges");
        @try {
            SEL hide = NSSelectorFromString(@"hide:");
            if ([receiver respondsToSelector:hide]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(receiver, hide, YES);
            } else if ([receiver isKindOfClass:UIView.class]) {
                [(UIView *)receiver removeFromSuperview];
            }
        } @catch (NSException *ignored) {}
        return;
    }

    // Only a genuine Leave Trade action may cancel the backend room.
    PBRHealthBeacon(@"fallback-leave");
    Class launcher = NSClassFromString(@"PBROriginalTradingLauncher");
    SEL cancel = NSSelectorFromString(@"cancelOriginalMatch");
    if ([launcher respondsToSelector:cancel]) {
        ((void (*)(id, SEL))objc_msgSend)(launcher, cancel);
    }
    PBRTradingArmedUntil = 0;

    __weak id weakDialog = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        id dialog = weakDialog;
        SEL hide = NSSelectorFromString(@"hide:");
        if (dialog && [dialog respondsToSelector:hide]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(dialog, hide, YES);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *rememberedMenu = PBRLastTradingMenuController;
            if (rememberedMenu) {
                UINavigationController *rememberedNav = PBRLastTradingNavigationController ?: rememberedMenu.navigationController;
                UITabBarController *rememberedTabs = PBRLastTradingTabController ?: rememberedMenu.tabBarController;
                if (rememberedTabs && rememberedNav) rememberedTabs.selectedViewController = rememberedNav;
                if (rememberedNav) {
                    [rememberedNav popToViewController:rememberedMenu animated:NO];
                    PBRHealthBeacon(@"leave-return-trading-menu");
                    return;
                }
            }

            Class menuClass = NSClassFromString(@"_TtC13PACYBITSFUT2025TradingMenuViewController");
            UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
            __block UIViewController *menu = nil;

            menu = PBRFindControllerOfClassInTree(window.rootViewController, menuClass);
            if (menu) {
                UITabBarController *tabs = menu.tabBarController;
                UINavigationController *nav = menu.navigationController;
                if (tabs && nav) tabs.selectedViewController = nav;
                if (nav) {
                    [nav popToViewController:menu animated:NO];
                    PBRHealthBeacon(@"leave-return-trading-menu");
                    return;
                }
            }

            UIViewController *trade = PBRCurrentOriginalTrading();
            if (trade.presentingViewController) [trade dismissViewControllerAnimated:NO completion:nil];
            PBRHealthBeacon(@"leave-trading-menu-missing");
        });
    });
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
    PBRInstallMethodHookOnce(menu, NSSelectorFromString(@"setWishlistCards:"),
                             (IMP)PBRTradingWishlistCardsSetter, &PBROriginalWishlistCardsSetter, &PBRWishlistCardsHooked);

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

    Class tradingCard = NSClassFromString(@"_TtC13PACYBITSFUT2011TradingCard");
    PBRInstallMethodHookOnce(tradingCard, NSSelectorFromString(@"outlineTapHandlerWithGesture:"),
                             (IMP)PBRTradingCardOutlineTap, &PBROriginalTradingCardOutlineTap, &PBRTradingCardOutlineHooked);
    PBRInstallMethodHookOnce(tradingCard, NSSelectorFromString(@"deleteTapHandlerWithGesture:"),
                             (IMP)PBRTradingCardDeleteTap, &PBROriginalTradingCardDeleteTap, &PBRTradingCardDeleteHooked);
    PBRInstallMethodHookOnce(tradingCard, NSSelectorFromString(@"setCard:"),
                             (IMP)PBRTradingCardSetCard, &PBROriginalTradingCardSetCard, &PBRTradingCardSetCardHooked);

    Class duplicatesVC = NSClassFromString(@"_TtC13PACYBITSFUT2024DuplicatesViewController");
    PBRInstallMethodHookOnce(duplicatesVC, NSSelectorFromString(@"collectionView:didSelectItemAtIndexPath:"),
                             (IMP)PBRDuplicatesDidSelect, &PBROriginalDuplicatesDidSelect, &PBRDuplicatesSelectHooked);

    Class coinsDialog = NSClassFromString(@"_TtC13PACYBITSFUT2018DialogTradingCoins");
    PBRInstallMethodHookOnce(coinsDialog, NSSelectorFromString(@"confirmTapHandlerWithGesture:"),
                             (IMP)PBRTradingCoinsConfirmTap, &PBROriginalCoinsConfirmTap, &PBRCoinsConfirmHooked);

    Class tradingVC = NSClassFromString(@"_TtC13PACYBITSFUT2021TradingViewController");
    PBRInstallMethodHookOnce(tradingVC, NSSelectorFromString(@"chatTapHandler:"),
                             (IMP)PBRTradingChatTap, &PBROriginalTradingChatTap, &PBRTradingChatHooked);

    Class messageDialog = NSClassFromString(@"_TtC13PACYBITSFUT2020DialogTradingMessage");
    PBRInstallMethodHookOnce(messageDialog, NSSelectorFromString(@"buttonTapHandlerWithGesture:"),
                             (IMP)PBRTradingMessageDoneTap, &PBROriginalMessageDoneTap, &PBRMessageDoneHooked);
    PBRInstallMethodHookOnce(messageDialog, NSSelectorFromString(@"textFieldShouldReturn:"),
                             (IMP)PBRTradingMessageReturn, &PBROriginalMessageReturn, &PBRMessageReturnHooked);
    PBRInstallMethodHookOnce(messageDialog, NSSelectorFromString(@"didMoveToWindow"),
                             (IMP)PBRTradingMessageDidMoveToWindow,
                             &PBROriginalMessageDidMoveToWindow, &PBRMessageDidMoveHooked);

    Class wishlistDialog = NSClassFromString(@"_TtC13PACYBITSFUT2021DialogTradingWishlist");
    PBRInstallMethodHookOnce(wishlistDialog, NSSelectorFromString(@"buttonTapHandlerWithGesture:"),
                             (IMP)PBRTradingWishlistDoneTap, &PBROriginalWishlistDoneTap, &PBRWishlistDoneHooked);

    Class confirmButton = NSClassFromString(@"_TtC13PACYBITSFUT2020TradingConfirmButton");
    PBRInstallMethodHookOnce(confirmButton, NSSelectorFromString(@"panDetectedWithSender:"),
                             (IMP)PBRTradingReadyPan, &PBROriginalTradeReadyPan, &PBRTradeReadyHooked);
    PBRInstallMethodHookOnce(confirmButton, NSSelectorFromString(@"makeChangesTapHandlerWithGesture:"),
                             (IMP)PBRTradingMakeChangesTap, &PBROriginalTradeMakeChangesTap, &PBRTradeMakeChangesHooked);
    PBRInstallMethodHookOnce(confirmButton, NSSelectorFromString(@"didMoveToWindow"),
                             (IMP)PBRConfirmButtonDidMoveToWindow,
                             &PBROriginalConfirmButtonDidMove, &PBRConfirmButtonDidMoveHooked);

    Class completeTrade = NSClassFromString(@"_TtC13PACYBITSFUT2026DialogTradingCompleteTrade");
    PBRInstallMethodHookOnce(completeTrade, NSSelectorFromString(@"acceptTapHandlerWithGesture:"),
                             (IMP)PBRTradingAcceptTap, &PBROriginalTradeAcceptTap, &PBRTradeAcceptHooked);
    PBRInstallMethodHookOnce(completeTrade, NSSelectorFromString(@"cancelTapHandlerWithGesture:"),
                             (IMP)PBRTradingCancelAcceptTap, &PBROriginalTradeCancelAcceptTap, &PBRTradeCancelAcceptHooked);
    PBRInstallMethodHookOnce(completeTrade, NSSelectorFromString(@"didMoveToWindow"),
                             (IMP)PBRCompleteTradeDidMoveToWindow,
                             &PBROriginalCompleteTradeDidMove, &PBRCompleteTradeDidMoveHooked);

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
    PBRStartTradeOverlayWatch();
}

static void PBRScheduleHookInstallation(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PBRInstallRevivalHooks();
        BOOL criticalHooksReady = PBRMenuTapHooked && PBRWishlistCardsHooked && PBROnlineLoadingCancelHooked &&
                                  PBRFindMatchHooked && PBRCancelHooked &&
                                  PBRMessageDoneHooked && PBRWishlistDoneHooked &&
                                  PBRTradeReadyHooked && PBRTradeAcceptHooked &&
                                  PBRTradeMakeChangesHooked && PBRTradeCancelAcceptHooked &&
                                  PBRTradeLeaveHooked && PBRTradingChatHooked &&
                                  PBRTradingCardOutlineHooked && PBRDuplicatesSelectHooked &&
                                  PBRCoinsConfirmHooked && PBRMessageReturnHooked &&
                                  PBRMessageDidMoveHooked && PBRTradingCardDeleteHooked &&
                                  PBRCompleteTradeDidMoveHooked && PBRConfirmButtonDidMoveHooked;
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


void PBRReturnToTradingMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *rememberedMenu = PBRLastTradingMenuController;
        UINavigationController *rememberedNav = PBRLastTradingNavigationController ?: rememberedMenu.navigationController;
        UITabBarController *rememberedTabs = PBRLastTradingTabController ?: rememberedMenu.tabBarController;

        if (rememberedMenu && rememberedNav) {
            if (rememberedTabs) rememberedTabs.selectedViewController = rememberedNav;
            [rememberedNav popToViewController:rememberedMenu animated:NO];
            PBRHealthBeacon(@"complete-return-trading-menu");
            return;
        }

        Class menuClass = NSClassFromString(@"_TtC13PACYBITSFUT2025TradingMenuViewController");
        UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
        UIViewController *menu = PBRFindControllerOfClassInTree(window.rootViewController, menuClass);
        if (menu) {
            UINavigationController *nav = menu.navigationController;
            UITabBarController *tabs = menu.tabBarController;
            if (tabs && nav) tabs.selectedViewController = nav;
            if (nav) {
                [nav popToViewController:menu animated:NO];
                PBRHealthBeacon(@"complete-return-trading-menu");
                return;
            }
        }
        PBRHealthBeacon(@"complete-return-trading-menu-missing");
    });
}

void PBRShowRevivalCompleteTradeDialog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
            if (!window) {
                PBRHealthBeacon(@"complete-dialog-no-window");
                return;
            }

            if (PBRCompleteTradeNibRoot && PBRCompleteTradeNibRoot.window == window) {
                PBRCompleteTradeNibRoot.hidden = NO;
                PBRCompleteTradeNibRoot.userInteractionEnabled = YES;
                [window bringSubviewToFront:PBRCompleteTradeNibRoot];
                PBRRefreshTradeControlOverlays();
                PBRHealthBeacon(@"complete-dialog-existing-front");
                return;
            }

            Class completeClass = NSClassFromString(@"_TtC13PACYBITSFUT2026DialogTradingCompleteTrade");
            if (!completeClass) {
                PBRHealthBeacon(@"complete-dialog-class-missing");
                return;
            }

            // Reproduce the original PACYBITS object lifecycle. The shipped
            // binary allocates a real DialogTradingCompleteTrade UIView and then
            // calls the inherited loadFromXibWithNamed: helper on that instance.
            // Loading the nib with NSBundle/File's Owner is not equivalent.
            UIView *dialog = [[completeClass alloc] initWithFrame:window.bounds];
            if (![dialog isKindOfClass:UIView.class]) {
                PBRHealthBeacon(@"complete-dialog-init-failed");
                return;
            }

            SEL loadSEL = NSSelectorFromString(@"loadFromXibWithNamed:");
            if (![dialog respondsToSelector:loadSEL]) {
                PBRHealthBeacon(@"complete-dialog-load-selector-missing");
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(dialog, loadSEL, @"DialogTradingCompleteTrade");
            PBRHealthBeacon(@"complete-dialog-xib-loaded");

            UIView *accept = nil;
            UIView *cancel = nil;
            @try { accept = [dialog valueForKey:@"acceptButton"]; } @catch (NSException *ignored) {}
            @try { cancel = [dialog valueForKey:@"cancelButton"]; } @catch (NSException *ignored) {}

            if (![accept isKindOfClass:UIView.class] || ![cancel isKindOfClass:UIView.class]) {
                PBRHealthBeacon(@"complete-dialog-outlets-missing");
                return;
            }

            // Match PACYBITS' original zero-duration long-press controls. Our
            // swizzled handlers route these to the revival backend, while the
            // window overlays below provide a second deterministic tap path.
            for (UIView *button in @[accept, cancel]) {
                for (UIGestureRecognizer *g in [button.gestureRecognizers copy]) {
                    [button removeGestureRecognizer:g];
                }
            }
            UILongPressGestureRecognizer *acceptPress =
                [[UILongPressGestureRecognizer alloc] initWithTarget:dialog
                                                               action:NSSelectorFromString(@"acceptTapHandlerWithGesture:")];
            acceptPress.minimumPressDuration = 0.0;
            [accept addGestureRecognizer:acceptPress];

            UILongPressGestureRecognizer *cancelPress =
                [[UILongPressGestureRecognizer alloc] initWithTarget:dialog
                                                               action:NSSelectorFromString(@"cancelTapHandlerWithGesture:")];
            cancelPress.minimumPressDuration = 0.0;
            [cancel addGestureRecognizer:cancelPress];

            dialog.frame = window.bounds;
            dialog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            dialog.hidden = NO;
            dialog.alpha = 1.0;
            dialog.userInteractionEnabled = YES;
            accept.hidden = NO;
            cancel.hidden = NO;
            accept.alpha = 1.0;
            cancel.alpha = 1.0;
            accept.userInteractionEnabled = YES;
            cancel.userInteractionEnabled = YES;

            [window addSubview:dialog];
            [dialog setNeedsLayout];
            [dialog layoutIfNeeded];
            [window bringSubviewToFront:dialog];

            PBRCompleteTradeNibOwner = dialog;
            PBRCompleteTradeNibRoot = dialog;
            PBRRefreshTradeControlOverlays();

            BOOL attached = (dialog.window == window && dialog.superview == window);
            BOOL visible = !dialog.hidden && dialog.alpha > 0.01 &&
                           !accept.hidden && accept.alpha > 0.01 &&
                           !cancel.hidden && cancel.alpha > 0.01;
            BOOL interactive = dialog.userInteractionEnabled &&
                               accept.userInteractionEnabled &&
                               cancel.userInteractionEnabled;
            if (attached && visible && interactive) {
                PBRHealthBeacon(@"complete-dialog-runtime-verified");
            } else if (!attached) {
                PBRHealthBeacon(@"complete-dialog-runtime-not-attached");
            } else if (!visible) {
                PBRHealthBeacon(@"complete-dialog-runtime-not-visible");
            } else {
                PBRHealthBeacon(@"complete-dialog-runtime-not-interactive");
            }
        } @catch (NSException *exception) {
            PBRCompleteTradeNibOwner = nil;
            PBRCompleteTradeNibRoot = nil;
            PBRHealthBeacon(@"complete-dialog-revival-failed");
        }
    });
}

void PBRHideRevivalCompleteTradeDialog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [PBRCompleteTradeNibRoot removeFromSuperview];
            PBRCompleteTradeNibRoot = nil;
            PBRCompleteTradeNibOwner = nil;
            PBRRemoveWindowOverlay(&PBRAcceptWindowOverlay);
            PBRRemoveWindowOverlay(&PBRCancelWindowOverlay);
        } @catch (NSException *ignored) {}
    });
}

void PBRResetOriginalTradeState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PBRResettingTradeUI = YES;
        @try {
            UIViewController *controller = PBRRawOriginalTrading();
            if (!controller) return;

            // Clear the long-lived controller's internal trade lifecycle. These
            // Swift ivars survive route changes and were causing the next trade
            // to reopen with the previous card and disabled controls.
            for (NSString *key in @[@"isReadyLeft", @"isReadyRight", @"isTradeComplete",
                                    @"isCompletingTrade", @"isSentHandshake",
                                    @"isReceivedHandshake", @"isSentTradeAgain",
                                    @"isReceivedTradeAgain", @"isRated", @"showedAd"]) {
                @try { [controller setValue:@NO forKey:key]; } @catch (NSException *ignored) {}
            }
            @try { [controller setValue:nil forKey:@"clickedCard"]; } @catch (NSException *ignored) {}
            @try { [controller setValue:@[] forKey:@"leftIds"]; } @catch (NSException *ignored) {}

            for (NSString *key in @[@"cardsLeft", @"cardsRight"]) {
                id cards = [controller valueForKey:key];
                if ([cards isKindOfClass:NSArray.class]) {
                    for (id slot in (NSArray *)cards) {
                        @try { [slot setValue:nil forKey:@"card"]; } @catch (NSException *ignored) {}
                        @try { [slot setUserInteractionEnabled:YES]; } @catch (NSException *ignored) {}
                        @try { [[slot valueForKey:@"outline"] setHidden:NO]; } @catch (NSException *ignored) {}
                        @try { [[slot valueForKey:@"deleteButton"] setHidden:YES]; } @catch (NSException *ignored) {}
                        @try { [[slot valueForKey:@"newSign"] setHidden:YES]; } @catch (NSException *ignored) {}
                        @try { [[slot valueForKey:@"loading"] stopAnimating]; } @catch (NSException *ignored) {}
                    }
                }
            }

            for (NSString *key in @[@"coinsButtonLeft", @"coinsButtonRight"]) {
                id button = [controller valueForKey:key];
                @try { [button setUserInteractionEnabled:YES]; } @catch (NSException *ignored) {}
                id textField = nil;
                @try { textField = [button valueForKey:@"textField"]; } @catch (NSException *ignored) {}
                if ([textField respondsToSelector:@selector(setText:)]) [textField setText:@""];
                @try { [textField setUserInteractionEnabled:YES]; } @catch (NSException *ignored) {}
            }

            for (NSString *key in @[@"wishlistButton", @"chatButton", @"coinsButton", @"confirmButton", @"mainArea"]) {
                id view = nil;
                @try { view = [controller valueForKey:key]; } @catch (NSException *ignored) {}
                @try { [view setUserInteractionEnabled:YES]; } @catch (NSException *ignored) {}
                @try { [view setAlpha:1.0]; } @catch (NSException *ignored) {}
            }
            id blocker = nil;
            @try { blocker = [controller valueForKey:@"blockingView"]; } @catch (NSException *ignored) {}
            @try { [blocker setHidden:YES]; } @catch (NSException *ignored) {}
            @try { [blocker setUserInteractionEnabled:NO]; } @catch (NSException *ignored) {}

            @try { [[controller valueForKey:@"messageLeft"] setText:@""]; } @catch (NSException *ignored) {}
            @try { [[controller valueForKey:@"messageRight"] setText:@""]; } @catch (NSException *ignored) {}
            PBRPendingLocalOfferSlot = NSNotFound;
            PBRTrackedOfferCards = [NSMutableDictionary dictionary];
            PBRTrackedOfferCoins = 0;
            PBRHealthBeacon(@"trade-ui-reset");
        } @catch (NSException *exception) {
            PBRHealthBeacon(@"trade-ui-reset-failed");
        }
        PBRResettingTradeUI = NO;
    });
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

static void PBRAppendWishlistCandidate(id item,
                                      NSMutableArray<NSString *> *result,
                                      NSMutableSet<NSString *> *seen,
                                      NSUInteger depth) {
    if (!item || result.count >= 50 || depth > 4) return;

    if ([item isKindOfClass:NSString.class] || [item isKindOfClass:NSNumber.class]) {
        NSString *identifier = [item isKindOfClass:NSString.class] ? item : [item stringValue];
        if (identifier.length && ![seen containsObject:identifier]) {
            [seen addObject:identifier];
            [result addObject:identifier];
        }
        return;
    }

    if ([item isKindOfClass:NSArray.class] || [item isKindOfClass:NSSet.class]) {
        for (id value in item) {
            PBRAppendWishlistCandidate(value, result, seen, depth + 1);
            if (result.count >= 50) break;
        }
        return;
    }

    if ([item isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)item allValues]) {
            PBRAppendWishlistCandidate(value, result, seen, depth + 1);
            if (result.count >= 50) break;
        }
        return;
    }

    NSString *identifier = PBRPlayerIdentifier(item);
    if (identifier.length && ![seen containsObject:identifier] && PBRPlayerForIdentifier(identifier)) {
        [seen addObject:identifier];
        [result addObject:identifier];
        return;
    }

    for (NSString *key in @[@"player", @"playerObject", @"playerModel", @"cardPlayer",
                            @"card", @"object", @"data", @"value", @"wishlistPlayers",
                            @"wishlistCards", @"wishlist", @"players"]) {
        @try {
            id nested = [item valueForKey:key];
            if (nested && nested != item) {
                PBRAppendWishlistCandidate(nested, result, seen, depth + 1);
                if (result.count >= 50) return;
            }
        } @catch (NSException *ignored) {}
    }
}

static void PBRCollectWishlistIvars(id owner,
                                    NSMutableArray<NSString *> *result,
                                    NSMutableSet<NSString *> *seen) {
    if (!owner || result.count >= 50) return;
    for (Class cls = [owner class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count && result.count < 50; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            if (!name || !type || type[0] != '@') continue;
            NSString *ivarName = [NSString stringWithUTF8String:name].lowercaseString;
            if (![ivarName containsString:@"wish"]) continue;
            @try {
                id value = object_getIvar(owner, ivar);
                PBRAppendWishlistCandidate(value, result, seen, 0);
            } @catch (NSException *ignored) {}
        }
        if (ivars) free(ivars);
    }
}

NSArray<NSString *> *PBRCurrentWishlistIdentifiers(void) {
    @try {
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        if (PBRCachedWishlistIdentifiers.count) {
            [result addObjectsFromArray:PBRCachedWishlistIdentifiers];
        }
        NSMutableSet<NSString *> *seen = [NSMutableSet set];

        UIWindow *window = [[PBRRevivalBootstrap shared] gameWindow];
        UIViewController *root = window.rootViewController;
        NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
        NSMutableSet<NSValue *> *visitedControllers = [NSMutableSet set];
        if (root) [queue addObject:root];

        while (queue.count && result.count < 50) {
            UIViewController *controller = queue.firstObject;
            [queue removeObjectAtIndex:0];
            NSValue *identity = [NSValue valueWithNonretainedObject:controller];
            if ([visitedControllers containsObject:identity]) continue;
            [visitedControllers addObject:identity];

            PBRCollectWishlistIvars(controller, result, seen);
            for (NSString *key in @[@"wishlistCards", @"wishlistPlayers", @"wishlist"]) {
                @try {
                    PBRAppendWishlistCandidate([controller valueForKey:key], result, seen, 0);
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

        NSMutableArray<UIView *> *views = [NSMutableArray array];
        NSMutableSet<NSValue *> *visitedViews = [NSMutableSet set];
        if (window) [views addObject:window];
        while (views.count && result.count < 50) {
            UIView *view = views.firstObject;
            [views removeObjectAtIndex:0];
            NSValue *identity = [NSValue valueWithNonretainedObject:view];
            if ([visitedViews containsObject:identity]) continue;
            [visitedViews addObject:identity];

            PBRCollectWishlistIvars(view, result, seen);
            for (NSString *key in @[@"wishlistPlayers", @"wishlistCards", @"wishlist"]) {
                @try {
                    PBRAppendWishlistCandidate([view valueForKey:key], result, seen, 0);
                } @catch (NSException *ignored) {}
            }
            [views addObjectsFromArray:view.subviews ?: @[]];
        }

        // PACYBITS keeps several trading fields on its long-lived GameCenter helper.
        // Inspect only ivars whose names contain "wish"; this avoids guessing offsets
        // while still surviving Swift property-name changes between UI states.
        @try {
            intptr_t slide = _dyld_get_image_vmaddr_slide(0);
            void *raw = *(void **)(uintptr_t)(0x1012be350ULL + slide);
            if (raw) PBRCollectWishlistIvars((__bridge id)raw, result, seen);
        } @catch (NSException *ignored) {}

        if (result.count) PBRHealthBeacon(@"fallback-wishlist");
        return result;
    } @catch (NSException *exception) {
        return @[];
    }
}

NSDictionary *PBRCurrentLocalOfferSnapshot(void) {
    @try {
        PBREnsureTrackedOffer();
        NSMutableArray<NSString *> *trackedCards = [NSMutableArray array];
        NSMutableArray<NSNumber *> *trackedSlots = [NSMutableArray array];
        for (NSInteger slot = 0; slot < 3; slot++) {
            NSString *identifier = PBRTrackedOfferCards[@(slot)];
            if (identifier.length) {
                [trackedCards addObject:identifier];
                [trackedSlots addObject:@(slot)];
            }
        }
        if (trackedCards.count || PBRTrackedOfferCoins > 0) {
            return @{@"coins": @(PBRTrackedOfferCoins), @"cards": trackedCards, @"slots": trackedSlots};
        }

        UIViewController *controller = PBRCurrentOriginalTrading();
        if (!controller) return @{@"coins": @0, @"cards": @[], @"slots": @[]};

        NSMutableArray<NSString *> *cards = [NSMutableArray array];
        NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
        id rawCards = nil;
        @try { rawCards = [controller valueForKey:@"cardsLeft"]; } @catch (NSException *ignored) {}
        if ([rawCards isKindOfClass:NSArray.class]) {
            NSInteger slot = 0;
            for (id tradingCard in (NSArray *)rawCards) {
                if (slot >= 3) break;
                id smallCard = nil;
                @try { smallCard = [tradingCard valueForKey:@"card"]; } @catch (NSException *ignored) {}
                NSString *identifier = PBRPlayerIdentifier(smallCard);
                if (!identifier.length) {
                    @try { identifier = PBRPlayerIdentifier([smallCard valueForKey:@"player"]); }
                    @catch (NSException *ignored) {}
                }
                if (identifier.length) {
                    [cards addObject:identifier];
                    [slots addObject:@(slot)];
                }
                slot += 1;
            }
        }

        NSInteger coins = 0;
        id coinsButton = nil;
        id textField = nil;
        @try { coinsButton = [controller valueForKey:@"coinsButtonLeft"]; } @catch (NSException *ignored) {}
        @try { textField = [coinsButton valueForKey:@"textField"]; } @catch (NSException *ignored) {}
        NSString *text = [textField respondsToSelector:@selector(text)] ? [textField text] : nil;
        if ([text isKindOfClass:NSString.class] && text.length) {
            NSMutableString *digits = [NSMutableString string];
            NSCharacterSet *decimal = NSCharacterSet.decimalDigitCharacterSet;
            for (NSUInteger i = 0; i < text.length; i++) {
                unichar ch = [text characterAtIndex:i];
                if ([decimal characterIsMember:ch]) [digits appendFormat:@"%C", ch];
            }
            long long value = digits.longLongValue;
            if (value > 0 && value <= NSIntegerMax) coins = (NSInteger)value;
        }

        return @{@"coins": @(coins), @"cards": cards, @"slots": slots};
    } @catch (NSException *exception) {
        return @{@"coins": @0, @"cards": @[], @"slots": @[]};
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
