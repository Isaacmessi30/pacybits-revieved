# Original PACYBITS interface adapter

The user explicitly rejected the replacement table-based trading panel. The target
is the existing Trading.storyboardc / TradingViewController and its original
card, coin, drag-to-ready, confirmation, wishlist, chat and post-trade controls.
Do not ship the prototype panel as this feature or claim that changing its labels
restores the original interface.

## Confirmed static boundaries, FUT20 1.2 arm64

- Menu: `_TtC13PACYBITSFUT2025TradingMenuViewController`.
  `buttonTapHandlerWithGesture:` at 0x100123790 wraps 0x1001233c8;
  main button routing continues in 0x100123a0c.
- `Trading.storyboardc/Info.plist` maps identifier `TradingViewController` to
  its existing nib. No replacement layout is necessary.
- Original trade viewDidLoad at 0x1000097f8 installs the active controller into
  global 0x1012bef00, then calls setup 0x100009fd0.
- Sender at 0x1006e3b6c receives a Swift String in x0/x1, an indirect Any? in x2,
  and GameCenterHelper self in x20. It handles other game modes too. Any eventual
  interception must preserve their behavior and account for argument ownership.
- Trading dispatch at 0x1006e48b4 receives String in x0/x1 and [String:Any] in x2.
  Calling an interior instruction such as 0x1006e5120 as a function is invalid.
- `tradingIntro`: envelope value is [String:Any], stored as opponentInfo at the
  helper's field offset loaded from 0x101297318. It also changes navigation/state.
- `tradingPickedOutline`: receiver 0x1006de4b0 reads envelope value dictionary,
  then integer tag and native Player object under player. Card IDs alone cannot
  be passed to this renderer. It calls original TradingCard renderer 0x1003bc024.
- `tradingDeletedOutline`: receiver 0x1006de8b4 takes integer envelope value.
- `tradingCoins`: receiver 0x1006ded30 takes integer envelope value.
- `tradingReady`: receiver 0x1006df10c checks original state before updating readiness.
- Accept/cancel/handshake are separate original events. They must be mapped to
  revision-bound backend confirmation and receipt reconciliation, not blindly
  relayed: original handshake completion can otherwise duplicate local settlement.

## Remaining work before an original-UI IPA

1. Install a version-checked native outbound transport hook and its fallback for
   non-trading messages; verify calling convention and retained payload lifetime.
2. Map matchmaking start/cancel for original channels, friends and code dialogs.
3. Translate accepted server state back into validated original rendering events.
4. Preserve the original completion animations while preventing the old peer
   handshake and the new ledger from applying one inventory change twice.
5. Verify on-device Google login, original view initialization and complete trades.

The Google browser OAuth implementation uses the project's iOS client ID, PKCE,
state validation and Firebase token verification. It has no Apple/Game Center
identity dependency. The IPA must use the plist's BUNDLE_ID and register the
REVERSED_CLIENT_ID URL scheme. Existing .launchtest packaging does not meet that
bundle requirement and must not be advertised as Google-ready.

## Card position transport (2026-09-16)

`TradeOffer.slots` optionally carries one original position (0–2) per card.
The server sorts cards and positions together, rejects duplicate/out-of-range
positions, and invalidates readiness even when only positions change.
`OriginalTradeOffer` preserves empty positions and translates native pick/delete/
coin actions. This is tested independently of the runtime hook. It does not
activate the original screen or authorize native completion/handshake events.

The inspected routine at `0x1004b9ee0` changes view frames and schedules a closure;
it is not established as the actual matchmaking boundary. Further tracing is
required before redirecting that path.
