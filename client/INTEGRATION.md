# Trading integration status

## Current source: Google authentication

The active client authenticates through GoogleBrowserLogin and Firebase REST.
Trading no longer asks Game Center for a proof or checks GKLocalPlayer. Each
request uses the Firebase session and checks that its UID matches the connected
account. The Render service accepts only Google-backed Firebase tokens with a
verified email. Provider fields in request bodies cannot override the token.

Firebase-configured packaging uses `com.pacybitsrevival.fut20` and registers the
plist's reversed Google client ID as a callback scheme. ESign must retain that
bundle ID. Browser login starts after the controller has a presentation window.
This source change does not modify any previously downloaded IPA.

## Original interface work remains incomplete

The active bootstrap still opens the prototype trading panel. The user rejected
that interface; it must not be described or distributed as restored original
trading. The original sender hook and payload bridge are implemented and tested
structurally, but not enabled by the packager. Original matchmaking, rendering
and completion must be connected before an original-interface IPA is ready.
See [the adapter map](original-ui/ADAPTER-MAP.md).

LegacyInventoryBridge is restricted to the inspected FUT20 arm64 Mach-O UUID.
It waits for the original Swift collection initialization, compares the live
String/Int dictionary with the Valet Keychain archive, and refuses unknown layouts.
Settlement writes a durable before/after journal before changing Keychain,
preferences and the live dictionary. A partially applied write can resume only
if each component still equals its recorded before or after value. This is a
static implementation pending real device validation, not proven crash recovery.

The server's optional preserveFirstCopy import mode stores total owned counts,
including each protected first copy. Existing duplicate-only test fixtures retain
their previous semantics. No repeat import or ongoing client balance upload was
added. Offline earnings remain local and are not newly tradeable in this version.
Server deltas preserve unrelated local gains; conflicting spends stop recovery.

Validation: 32 backend unit tests and 15 portable HTTP/offer checks passed before
this authentication switch. The Google-only backend passed all 32 tests after
the switch. On-device Google login and complete original-UI trades remain unverified.
The previously delivered build 2 still uses Game Center and the separate
`.launchtest` bundle; it is not a Google build.
