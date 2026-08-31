#!/usr/bin/env bash
# Assembles a minimal AIMeter.app bundle from the SwiftPM build output.
# Requires: swift build has produced .build/<configuration>/AIMeterApp
# Usage: scripts/make-app.sh [release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/AIMeterApp"
APP="$ROOT/dist/AIMeter.app"

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN — run 'swift build -c $CONFIG' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>app.aimeter.macos</string>
    <key>CFBundleName</key>
    <string>AIMeter</string>
    <key>CFBundleDisplayName</key>
    <string>AIMeter</string>
    <key>CFBundleExecutable</key>
    <string>AIMeterApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/AIMeterApp"
touch "$APP/Contents/Resources/empty.lproj"

echo "Bundle created: $APP"