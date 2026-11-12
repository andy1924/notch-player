#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/dist/Notch Player.app"
mkdir -p .build/module-cache "$app/Contents/MacOS"

xcrun swiftc -O -module-cache-path "$PWD/.build/module-cache" \
    -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    Sources/NotchPlayer/*.swift -o "$app/Contents/MacOS/NotchPlayer"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
