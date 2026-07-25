#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Shuo.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_BUILD_DIR="$PROJECT_DIR/.build/icon-assets"
SIGNING_IDENTITY="${SHUO_SIGNING_IDENTITY:--}"

cd "$PROJECT_DIR"
/usr/bin/xcrun swift build --disable-sandbox -c release
BIN_DIR=$(/usr/bin/xcrun swift build --disable-sandbox -c release --show-bin-path)

/bin/rm -rf "$APP_DIR"
/bin/rm -rf "$ICON_BUILD_DIR"
/bin/mkdir -p "$CONTENTS_DIR/MacOS/Resources" "$CONTENTS_DIR/Resources"
/bin/mkdir -p "$ICON_BUILD_DIR"
/Applications/Xcode.app/Contents/Developer/usr/bin/actool \
    "$PROJECT_DIR/Resources/AppIcon.icon" \
    --compile "$ICON_BUILD_DIR" \
    --output-format human-readable-text \
    --output-partial-info-plist "$ICON_BUILD_DIR/Info.plist" \
    --notices \
    --warnings \
    --app-icon AppIcon \
    --standalone-icon-behavior all \
    --target-device mac \
    --minimum-deployment-target 15.0 \
    --platform macosx
/usr/bin/ditto "$BIN_DIR/Shuo" "$CONTENTS_DIR/MacOS/Shuo"
/usr/bin/ditto "$PROJECT_DIR/Resources/default.metallib" "$CONTENTS_DIR/MacOS/Resources/mlx.metallib"
/usr/bin/ditto "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/ditto "$ICON_BUILD_DIR/Assets.car" "$CONTENTS_DIR/Resources/Assets.car"
/usr/bin/ditto "$ICON_BUILD_DIR/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/usr/bin/ditto \
    "$PROJECT_DIR/Resources/ShuoMenuBarIconTemplate.png" \
    "$CONTENTS_DIR/Resources/ShuoMenuBarIconTemplate.png"

for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    /usr/bin/ditto "$bundle" "$CONTENTS_DIR/Resources/$(basename "$bundle")"
done

# Files under Contents/MacOS are treated as nested code by codesign.
/usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    "$CONTENTS_DIR/MacOS/Resources/mlx.metallib"

/usr/bin/codesign \
    --force \
    --options runtime \
    --entitlements "$PROJECT_DIR/Resources/Shuo.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
