# Revival iOS client source

This is client source for integration, not a rebuilt IPA or Xcode app.
Target: iOS 15 or later. Actual iPhone compatibility remains untested.

## Components

- `Sources/RevivalTradingClient/TradingClient.swift`: typed trading requests,
  authenticated HTTPS, server errors, account-switch and logout safeguards.
- `Sources/RevivalTradingClient/FirebaseRESTAuthentication.swift`: exchanges a
  Google ID token for a Firebase session and coalesces token refreshes. Tokens
  stay in memory. Restarting the app requires signing in again.
- `ios/GoogleLoginCoordinator.swift`: host integration source using the official
  GoogleSignIn SDK. Its separate Swift package pins GoogleSignIn 9.0.0 and
  is built with the iPhone SDK in GitHub Actions. The installed bundle ID must match the supplied plist, and the host
  must forward the registered reversed-client-ID URL callback.

The existing IPA already includes Firebase Core and Database. This source uses
Firebase Auth REST to avoid embedding another copy of those Firebase classes.
GoogleSignIn dependency compatibility with the IPA's existing libraries still
needs checking during native packaging.

## Required host flow

1. Present Google login and provide the resulting Firebase session to the client.
2. Call `register`. If `inventoryReady` is false, read the existing local
   tradeable cards and coins and call `importLegacyInventory` once.
3. If the import response is lost, fetch `status` to determine whether it
   committed. Never overwrite an initialized ledger from a device save.
4. Bind invitation/random queue and room snapshots to the trading screens.
5. Send offers, readiness and confirmations with the current room revision.
6. Fetch server inventory after completion. Apply it to the original save only
   through an adapter that understands its storage and duplicate-card semantics.

Steps 2, 4 and 6 still require the original game's native hooks/storage mapping.
There is no ongoing offline-earnings synchronization. No Game Center replacement
has been injected into the supplied IPA.

## Checks

From the workspace root:

```sh
bash scripts/check-client.sh
```

This compiles the portable Swift sources and runs 12 mock-HTTP checks with the
installed macOS command-line tools. It does not test UIKit, GoogleSignIn,
real OAuth, iPhone launch or an actual game trade. XCTest files are included
for environments with the full developer tools; they were not run here.

## Legacy collection reader

`LegacyCollectionSnapshot` reads the statically mapped `bXlJZHM=` preferences
entry as a card-ID-to-duplicate-count dictionary. Zero means a retained owned
card with no duplicates; only positive counts become tradeable cards. Missing
or malformed data fails. This reader does not write saves or upload inventory.
It has fixture checks but still needs real device-save validation. Coin storage
and reconciling the in-memory game collection remain unfinished.
