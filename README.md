## Current integration status — 2026-09-16

A connected device-test IPA is packaged locally at `dist/Pacybits-Revival-Trading-2.ipa`.
Its native trading panel uses Game Center → Firebase Auth → Render, with guarded
legacy collection import and settlement. iPhone compilation and automated tests
pass; real login and two-device trades remain unverified. See
[client/INTEGRATION.md](client/INTEGRATION.md) for scope and collection limitations.
Earlier implementation notes below describe the development stages leading here.

# PACYBITS revival development

Development source for a Google-authenticated trading backend and iOS client.
**There is no trading-enabled IPA yet.** The original game has not been
connected to this backend, and real Google login/device trading is untested.

## Hosted Mac build

Open **Actions → Client build and backend checks**. A push to `main` starts
checks; **Run workflow** starts them manually. The Mac job uses Xcode 16.4 on
GitHub, so Xcode is not required on your computer.

The workflow runs backend unit tests, portable Swift checks, XCTest, and an
arm64 iPhone SDK compile targeting iOS 15. Its downloadable artifact is an
**unsigned static client library, not an installable IPA**. The workflow also compiles the Google login coordinator against GoogleSignIn
9.0.0. Wiring it into the original game and testing real login remain required.

No signing certificate, Firebase service-account key or production credentials
are needed by this workflow. There is no cloud deployment. Artifacts expire
after seven days. GitHub account Actions allowances and billing still apply.

## Components

- [Backend](backend/README.md): Google session checks, invitation/random rooms,
  offer revisions, rate limits and atomic trading settlement.
- [Client](client/README.md): Firebase Auth REST, token refresh, typed trading API
  and an iOS Google login coordinator source file.
- Database rules deny all direct client database reads and writes.

Players can import existing cards and coins once. That initial collection is
unverified; later transfers use the server ledger. Ongoing offline earnings
synchronization and original save integration remain unfinished.

## Remaining work

Connect GoogleSignIn and URL callbacks, map the original collection storage,
connect the game screens to the API, reconcile committed inventory, package an
unsigned IPA, then sign using ESign and test on real devices. Building a client
library alone does not establish that the game works.

## First ESign launch test

`Build ESign launch-test module` compiles a small native module that adds a
**Revival test** status button inside the game. It does not change saves,
authentication or networking. `scripts/package-test-ipa.py` packages the exact
inspected original IPA and the module into a separate test app. The original
IPA is kept locally and is not in this repository.

```sh
python3 scripts/package-test-ipa.py 'FUT20DRAFT 2.ipa' build/bootstrap/RevivalBootstrap.dylib dist/Pacybits-Revival-Launch-Test-1.ipa
```

This uses the original unencrypted arm64 slice, adds a dylib load command only
in verified empty header padding, and sets the separate test bundle ID to
`com.pacybitsrevival.fut20.launchtest`. Minimum iOS is 15. Sign the output with
ESign. The archive has no valid final signature until ESign signs it.
The test app has separate storage and does not import the original collection.
**This test does not restore trading or connect Google login.**

## Free server hosting

[Deploy the Render Free server](https://render.com/deploy?repo=https://github.com/Isaacmessi30/pacybits-revieved)

Follow [the Render setup guide](backend/RENDER.md). The Blueprint selects the
Free compute plan and keeps Firebase on Spark. Enter the Firebase server key
only in Render. Deployment is pending the account owner completing that step.
