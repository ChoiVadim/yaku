#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/Translater.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
LOCAL_HOME="$ROOT/.build/home"
LOCAL_MODULE_CACHE="$ROOT/.build/clang-module-cache"

cd "$ROOT"
mkdir -p "$LOCAL_HOME" "$LOCAL_MODULE_CACHE"
export HOME="$LOCAL_HOME"
export CLANG_MODULE_CACHE_PATH="$LOCAL_MODULE_CACHE"

swift build \
    -c release \
    --disable-sandbox \
    --cache-path "$ROOT/.build/swiftpm-cache" \
    --config-path "$ROOT/.build/swiftpm-config" \
    --security-path "$ROOT/.build/swiftpm-security" \
    -Xcc "-fmodules-cache-path=$ROOT/.build/clang-module-cache"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BUILD_DIR/Translater" "$MACOS_DIR/Translater"
cp "$ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "local.vadim.translater"' \
    "$APP_DIR"

echo "Built $APP_DIR"
