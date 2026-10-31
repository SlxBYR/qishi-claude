#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${QISHI_BUILD_DIR:-$ROOT/.build}"
DEST="${QISHI_OUTPUT_DIR:-$ROOT/..}"
APP="$DEST/栖时·Claude.app"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx27.0 \
  -module-cache-path "$BUILD/ModuleCache" \
  "$ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/Qishi"
cp -R "$ROOT/Resources/Claude" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/Clawd" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/CrossPet" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/ClawdWeb" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/ClaudeLogo" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/Sidebar" "$APP/Contents/Resources/"
cp "$ROOT/Resources/upstream-lock.json" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/README.md" "$APP/Contents/Resources/使用说明.md"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
