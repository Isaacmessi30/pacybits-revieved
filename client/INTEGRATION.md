# Connected native client, build 2

The injected module now opens a UIKit trading panel from the original trading
menu's Objective-C tap handler, with a floating button as a second entry point.
It exchanges fresh Game Center proof for Firebase credentials, calls the Render
API, imports the current installation's collection once, and implements invites,
queue renewal, offers, ready/confirm/cancel, status polling and receipt recovery.
Google coordinator source remains separate; this injected build uses Game Center.

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

Validation: 27 backend unit tests, 10 standalone Firebase emulator checks,
13 portable mock-HTTP checks and hosted iPhone compilation passed. These checks
do not prove Apple identity verification, real Valet access, or two-device trades.
The first connected IPA uses the existing separate launch-test bundle ID.
