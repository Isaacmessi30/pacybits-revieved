#!/bin/bash
set -euo pipefail
revival_root="$(cd "$(dirname "$0")/.." && pwd)"
revival_output="$revival_root/build/ios-client"
revival_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$revival_output"
xcrun --sdk iphoneos swiftc -parse-as-library -swift-version 5 \
  -sdk "$revival_sdk" -target arm64-apple-ios15.0 \
  -module-name RevivalTradingClient -emit-library -static -emit-module \
  -emit-module-path "$revival_output/RevivalTradingClient.swiftmodule" \
  "$revival_root/client/Sources/RevivalTradingClient/TradingClient.swift" \
  "$revival_root/client/Sources/RevivalTradingClient/FirebaseRESTAuthentication.swift" \
  -o "$revival_output/libRevivalTradingClient.a"
xcrun lipo -info "$revival_output/libRevivalTradingClient.a"
cat > "$revival_output/README.txt" <<'INFO'
Unsigned arm64 iPhone client library, minimum iOS 15.
This is NOT an IPA and cannot be installed with ESign.
GoogleSignIn host integration, original game hooks, packaging and device testing remain required.
INFO
