# Game Center authentication

Enable Game Center in Firebase Authentication → Sign-in method. Google can stay enabled.
The coordinator uses the existing game's authenticated GKLocalPlayer, requests a fresh
Apple identity signature, and exchanges it through Firebase's signInWithGameCenter API.
The actual running bundle ID is sent in the required header. Firebase verifies the proof;
the Render backend accepts only Firebase-verified Google or Game Center sessions.

This source is not yet connected to the injected launch-test module. A welcome banner
proves Game Center authentication only, not successful Firebase credential exchange.
The final ESign bundle and provisioning profile must support Game Center. Test the
exchange on that exact build before replacing Google as the primary login.

After deploying the updated server, verify login and registration, then connect the
trade UI and reconcile completed transfers with the game's live and persisted inventory.
Do not update only the preferences backup: the game also maintains live/keychain state.

References:
- https://firebase.google.com/docs/auth/ios/game-center
- https://docs.cloud.google.com/identity-platform/docs/reference/rest/v1/accounts/signInWithGameCenter
