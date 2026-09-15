#!/bin/bash
set -euo pipefail
revival_root="$(cd "$(dirname "$0")/.." && pwd)"
revival_output="$revival_root/build/bootstrap"
mkdir -p "$revival_output"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -fobjc-arc -fmodules -Wall -Wextra -Werror -Wno-unused-parameter \
  -dynamiclib -framework UIKit -framework Foundation \
  -Wl,-install_name,@executable_path/Frameworks/RevivalBootstrap.dylib \
  "$revival_root/client/bootstrap/RevivalBootstrap.m" \
  -o "$revival_output/RevivalBootstrap.dylib"
xcrun lipo -info "$revival_output/RevivalBootstrap.dylib"
# Base64 is a transport copy for fetching this small build through the GitHub API.
base64 < "$revival_output/RevivalBootstrap.dylib" > "$revival_output/RevivalBootstrap.dylib.base64"
shasum -a 256 "$revival_output/RevivalBootstrap.dylib" > "$revival_output/SHA256.txt"
