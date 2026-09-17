#!/bin/bash
set -euo pipefail
revival_root="$(cd "$(dirname "$0")/.." && pwd)"
revival_output="$revival_root/build/bootstrap"
mkdir -p "$revival_output"
revival_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
  -isysroot "$revival_sdk" -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-unused-parameter \
  -c "$revival_root/client/bootstrap/RevivalBootstrap.m" -o "$revival_output/bootstrap.o"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
  -isysroot "$revival_sdk" -c "$revival_root/client/original-ui/LegacySendIsland.s" \
  -o "$revival_output/LegacySendIsland.o"
xcrun --sdk iphoneos swiftc -parse-as-library -swift-version 5 \
  -sdk "$revival_sdk" -target arm64-apple-ios15.0 -module-name PBRRevival \
  -import-objc-header "$revival_root/client/bootstrap/RevivalRuntime.h" \
  -emit-library -Xlinker -install_name -Xlinker @executable_path/Frameworks/RevivalBootstrap.dylib \
  -framework UIKit -framework Foundation -framework GameKit -framework AuthenticationServices -framework Security \
  "$revival_root/client/Sources/RevivalTradingClient/TradingClient.swift" \
  "$revival_root/client/Sources/RevivalTradingClient/FirebaseRESTAuthentication.swift" \
  "$revival_root/client/Sources/RevivalTradingClient/GoogleOAuthCallback.swift" \
  "$revival_root/client/bootstrap/GoogleBrowserLogin.swift" \
  "$revival_root/client/original-ui/OriginalTradeProtocol.swift" \
  "$revival_root/client/original-ui/OriginalTradeOffer.swift" \
  "$revival_root/client/original-ui/OriginalTradeSession.swift" \
  "$revival_root/client/original-ui/OriginalTradePeerState.swift" \
  "$revival_root/client/original-ui/OriginalTradingScreen.swift" \
  "$revival_root/client/original-ui/LegacyOutboundBridge.swift" \
  "$revival_root/client/bootstrap/LegacyInventoryBridge.swift" \
  "$revival_root/client/bootstrap/OriginalTradingCoordinator.swift" \
  "$revival_root/client/bootstrap/OriginalTradingLauncher.swift" \
  "$revival_output/bootstrap.o" -o "$revival_output/RevivalBootstrap.dylib"
rm "$revival_output/bootstrap.o"
xcrun lipo -info "$revival_output/RevivalBootstrap.dylib"
base64 < "$revival_output/RevivalBootstrap.dylib" > "$revival_output/RevivalBootstrap.dylib.base64"
shasum -a 256 "$revival_output/RevivalBootstrap.dylib" > "$revival_output/SHA256.txt"
