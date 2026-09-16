#!/bin/bash
set -euo pipefail
revival_root="$(cd "$(dirname "$0")/.." && pwd)"
revival_build="$(mktemp -d "${TMPDIR:-/tmp}/pacybits-client.XXXXXX")"
trap 'rm -rf "$revival_build"' EXIT
xcrun swiftc -parse-as-library \
  -target "$(uname -m)-apple-macos12.0" \
  -module-cache-path "${TMPDIR:-/tmp}/pacybits-revival-swift-modules" \
  "$revival_root/client/Sources/RevivalTradingClient/TradingClient.swift" \
  "$revival_root/client/Sources/RevivalTradingClient/FirebaseRESTAuthentication.swift" \
  "$revival_root/client/Sources/RevivalTradingClient/GoogleOAuthCallback.swift" \
  "$revival_root/client/original-ui/OriginalTradeProtocol.swift" \
  "$revival_root/client/original-ui/OriginalTradeOffer.swift" \
  "$revival_root/client/Checks/ClientChecks.swift" \
  -o "$revival_build/client-checks"
"$revival_build/client-checks"
