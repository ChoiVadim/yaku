#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/dist/Yaku.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICNS_PATH="$ROOT/Resources/AppIcon.icns"
DMG_BG_PATH="$ROOT/Resources/dmg-background.png"
DMG_PATH="$ROOT/dist/Yaku.dmg"
DMG_RW_PATH="$ROOT/.build/Yaku.rw.dmg"
DMG_STAGE="$ROOT/.build/dmg-stage"
LOCAL_HOME="$ROOT/.build/home"
LOCAL_MODULE_CACHE="$ROOT/.build/clang-module-cache-release"

# Universal (arm64 + x86_64) by default; pass UNIVERSAL=0 to build host-arch only.
UNIVERSAL="${UNIVERSAL:-1}"

cd "$ROOT"
mkdir -p "$LOCAL_HOME" "$LOCAL_MODULE_CACHE"
export HOME="$LOCAL_HOME"
export CLANG_MODULE_CACHE_PATH="$LOCAL_MODULE_CACHE"

if [ ! -f "$ICNS_PATH" ]; then
    echo "AppIcon.icns missing — regenerating."
    swift "$ROOT/Scripts/generate-icon.swift" "$ICNS_PATH"
fi
if [ ! -f "$DMG_BG_PATH" ]; then
    echo "dmg-background.png missing — regenerating."
    swift "$ROOT/Scripts/generate-dmg-background.swift" "$DMG_BG_PATH"
fi

if [ "$UNIVERSAL" = "1" ]; then
    swift build \
        -c release \
        --arch arm64 \
        --arch x86_64 \
        --disable-sandbox \
        --cache-path "$ROOT/.build/swiftpm-cache" \
        --config-path "$ROOT/.build/swiftpm-config" \
        --security-path "$ROOT/.build/swiftpm-security" \
        -Xcc "-fmodules-cache-path=$LOCAL_MODULE_CACHE"
    BINARY_PATH="$ROOT/.build/apple/Products/Release/Yaku"
else
    swift build \
        -c release \
        --disable-sandbox \
        --cache-path "$ROOT/.build/swiftpm-cache" \
        --config-path "$ROOT/.build/swiftpm-config" \
        --security-path "$ROOT/.build/swiftpm-security" \
        -Xcc "-fmodules-cache-path=$LOCAL_MODULE_CACHE"
    BINARY_PATH="$ROOT/.build/release/Yaku"
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "Build output not found at $BINARY_PATH" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/Yaku"
cp "$ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICNS_PATH" "$RESOURCES_DIR/AppIcon.icns"

codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "local.vadim.yaku"' \
    "$APP_DIR"

xattr -cr "$APP_DIR"
echo "Built $APP_DIR"

# --- Styled DMG packaging ---

# Detach any leftover Yaku mounts so we land at /Volumes/Yaku exactly.
for stale in $(/sbin/mount | /usr/bin/awk -F' on ' '/Yaku/ {sub(/ \(.*$/, "", $2); print $2}'); do
    /usr/bin/hdiutil detach "$stale" -force >/dev/null 2>&1 || true
done

rm -rf "$DMG_STAGE" "$DMG_PATH" "$DMG_RW_PATH"
mkdir -p "$DMG_STAGE/.background"
cp "$DMG_BG_PATH" "$DMG_STAGE/.background/dmg-background.png"
cp -R "$APP_DIR" "$DMG_STAGE/Yaku.app"
ln -s /Applications "$DMG_STAGE/Applications"

# Pre-size the DMG with some headroom over the staged content.
STAGE_SIZE_KB="$(/usr/bin/du -sk "$DMG_STAGE" | awk '{print $1}')"
DMG_SIZE_MB=$(( STAGE_SIZE_KB / 1024 + 12 ))

/usr/bin/hdiutil create \
    -volname "Yaku" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    -size "${DMG_SIZE_MB}m" \
    "$DMG_RW_PATH" >/dev/null

ATTACH_OUTPUT="$(/usr/bin/hdiutil attach "$DMG_RW_PATH" -nobrowse -noautoopen -readwrite)"
MOUNT_DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk -F'\t' '/Apple_HFS/ {print $NF; exit}')"
if [ -z "$MOUNT_POINT" ]; then
    MOUNT_POINT="/Volumes/Yaku"
fi
echo "Mounted at $MOUNT_POINT"

# Hide the .background folder using all available mechanisms so Finder ignores it.
/usr/bin/chflags hidden "$MOUNT_POINT/.background" || true
SETFILE_BIN="$(/usr/bin/xcrun -f SetFile 2>/dev/null || true)"
if [ -n "$SETFILE_BIN" ] && [ -x "$SETFILE_BIN" ]; then
    "$SETFILE_BIN" -a V "$MOUNT_POINT/.background" || true
fi

sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "Yaku"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 940, 480}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:dmg-background.png"
        set position of item "Yaku.app" of container window to {145, 200}
        set position of item "Applications" of container window to {395, 200}
        try
            set position of item ".background" of container window to {2000, 2000}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 1

# Detach with retries — Finder sometimes still holds the volume briefly.
for attempt in 1 2 3 4 5; do
    if /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet; then
        break
    fi
    if [ "$attempt" -eq 5 ]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" -force
    else
        sleep 2
    fi
done

/usr/bin/hdiutil convert "$DMG_RW_PATH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH" >/dev/null
rm -f "$DMG_RW_PATH"
rm -rf "$DMG_STAGE"

echo "Packaged $DMG_PATH"

ARCHS_OUT="$(/usr/bin/lipo -archs "$MACOS_DIR/Yaku" 2>/dev/null || echo unknown)"
DMG_SIZE="$(/usr/bin/du -h "$DMG_PATH" | cut -f1)"
echo "Architectures: $ARCHS_OUT"
echo "DMG size: $DMG_SIZE"
