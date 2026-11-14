#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the same Apple signing identity across local builds so macOS can
# recognize updates when it checks existing privacy permissions.
signing_identity="${NOTCH_SIGN_IDENTITY:-}"
if [[ "$signing_identity" != "-" ]]; then
    identities="$(security find-identity -v -p codesigning)"
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$(awk '/"(Apple Development|Developer ID Application):/ { print $2; exit }' <<< "$identities")"
        signing_identity="${signing_identity:--}"
    elif ! grep -Fq -- "$signing_identity" <<< "$identities"; then
        printf 'Signing identity not found in the local keychain: %s\n' "$signing_identity" >&2
        exit 1
    fi
fi

if [[ "$signing_identity" == "-" ]]; then
    printf '%s\n' 'Using ad-hoc signing. macOS privacy permissions may need reauthorization after a rebuild.' >&2
fi
signing_options=(--force --sign "$signing_identity" --timestamp=none)

app="$PWD/dist/Notch Player.app"
widget="$app/Contents/PlugIns/ListeningWidget.appex"
widget_products="$PWD/.build/widget-products"
mkdir -p .build/module-cache "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"

xcrun swiftc -O -module-cache-path "$PWD/.build/module-cache" \
    -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    Sources/NotchPlayer/*.swift -o "$app/Contents/MacOS/NotchPlayer"
xcodebuild -quiet -project ListeningWidget.xcodeproj -scheme ListeningWidget \
    -configuration Release -sdk macosx ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
    -derivedDataPath "$PWD/.build/widget-derived" CONFIGURATION_BUILD_DIR="$widget_products" OBJROOT="$PWD/.build/widget-objects" \
    SYMROOT="$PWD/.build/widget-products" build
ditto "$widget_products/ListeningWidget.appex" "$widget"
codesign "${signing_options[@]}" --entitlements scripts/ListeningWidget.entitlements "$widget"
cp assets/NotchPlayer.icns "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
codesign "${signing_options[@]}" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
