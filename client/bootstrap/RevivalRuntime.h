#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NSString * _Nullable PBRCardLabel(NSString * _Nonnull identifier);
NSString * _Nullable PBRPlayerIdentifier(id _Nonnull player);
id _Nullable PBRPlayerForIdentifier(NSString * _Nonnull identifier);
UIViewController * _Nullable PBRInstantiateOriginalTrading(void);

BOOL PBRStartOriginalNativeMatch(NSString * _Nonnull peerAlias);
void PBRShowBackendPlayerFound(void);
void PBRHideBackendMatchLoading(void);
void PBRResetOriginalTradeState(void);
void PBRReturnToTradingMenu(void);
void PBRShowRevivalCompleteTradeDialog(void);
void PBRHideRevivalCompleteTradeDialog(void);
UIViewController * _Nullable PBRCurrentOriginalTrading(void);
UIViewController * _Nullable PBRPresentOriginalTradingFallback(void);

NSArray<NSString *> * _Nonnull PBRCurrentWishlistIdentifiers(void);
void PBRNativeEventProbe(NSString * _Nonnull label);
NSDictionary * _Nonnull PBRCurrentLocalOfferSnapshot(void);
