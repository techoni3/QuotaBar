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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Sparkle framework from the SPM binary artifact (platform slice the build used).
SPARKLE_ARTIFACT="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$ROOT/.build/arm64-apple-macosx/$CONFIG/Sparkle.framework" ]]; then
  SPARKLE_ARTIFACT="$ROOT/.build/arm64-apple-macosx/$CONFIG/Sparkle.framework"
fi
if [[ -d "$SPARKLE_ARTIFACT" ]]; then
  cp -R "$SPARKLE_ARTIFACT" "$APP/Contents/Frameworks/Sparkle.framework"
  # Sparkle's framework ships a stub executable-less layout; strip quarantine/xattrs.
  xattr -cr "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
else
  echo "warning: Sparkle.framework not found — the app will still link only if Sparkle was linked statically" >&2
fi

# App icon (placeholder art — see scripts/make-assets.swift).
if [[ -f "$ROOT/Assets/icon.icns" ]]; then
  cp "$ROOT/Assets/icon.icns" "$APP/Contents/Resources/icon.icns"
fi

SU_FEED_URL="${AIMETER_SU_FEED_URL:-https://raw.githubusercontent.com/OWNER/REPO/main/docs/aimeter-appcast.xml}"
SU_PUBLIC_KEY="$(tr -d '[:space:]' < "$ROOT/Support/SparklePublicKey.txt" 2>/dev/null || echo 'PLACEHOLDER')"

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SU_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/AIMeterApp"
touch "$APP/Contents/Resources/empty.lproj"

# The SPM link records @rpath/Sparkle.framework but leaves no bundle-relative
# rpath; add one so dyld finds the embedded framework at runtime.
install_name_tool -add_rpath @executable_path/../Frameworks \
  "$APP/Contents/MacOS/AIMeterApp" 2>/dev/null || true

# Ad-hoc sign (development). Release builds use scripts/release.sh (Developer ID).
codesign --force --deep -s - "$APP" 2>/dev/null

echo "Bundle created: $APP"