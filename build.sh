#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/dist/MonitorKontrol.app"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFT_MODULECACHE_PATH="$BUILD_DIR/ModuleCache"

mkdir -p "$BUILD_DIR/ModuleCache" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

make -C "$PROJECT_DIR/Vendor/m1ddc" clean binary

xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -framework SwiftUI \
  -framework AppKit \
  "$PROJECT_DIR/Sources/MonitorKontrol/main.swift" \
  -o "$APP_DIR/Contents/MacOS/MonitorKontrol"

cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Vendor/m1ddc/m1ddc" "$APP_DIR/Contents/Resources/m1ddc"
cp "$PROJECT_DIR/Vendor/m1ddc/LICENSE" "$APP_DIR/Contents/Resources/LICENSE-m1ddc.txt"
chmod +x "$APP_DIR/Contents/MacOS/MonitorKontrol" "$APP_DIR/Contents/Resources/m1ddc"

codesign --force --deep --sign - "$APP_DIR"
ditto -c -k --keepParent "$APP_DIR" "$PROJECT_DIR/dist/MonitorKontrol.zip"

echo "Hazır: $APP_DIR"
echo "Paket: $PROJECT_DIR/dist/MonitorKontrol.zip"
