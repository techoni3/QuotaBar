#!/usr/bin/env bash
# AIMeter release pipeline (spec §8 / PER-5):
#   build (release) → assemble bundle → sign (Developer ID + hardened runtime,
#   ad-hoc fallback) → notarize + staple (when tooling+profile present) →
#   signed DMG (hdiutil) → Sparkle appcast (docs/aimeter-appcast.xml).
#
# Requirements / env (all optional unless marked):
#   AIMETER_VERSION         version string            (default 0.1.0)
#   DEVELOPER_ID_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)"
#                           (absent → ad-hoc sign, notarization skipped)
#   AIMETER_NOTARY_PROFILE  notarytool --keychain-profile name (requires Xcode's xcrun)
#   AIMETER_RELEASE_BASE_URL  base for appcast links, e.g.
#                           https://github.com/OWNER/REPO/releases/download/v0.1.0
#                           (defaults to an OWNER/REPO placeholder until the repo is pushed)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${AIMETER_VERSION:-0.1.0}"
IDENTITY="${DEVELOPER_ID_IDENTITY:-}"
NOTARY_PROFILE="${AIMETER_NOTARY_PROFILE:-}"
SDK_OVERRIDE="${AIMETER_SDK:-}"
BASE_URL="${AIMETER_RELEASE_BASE_URL:-https://github.com/OWNER/REPO/releases/download/v${VERSION}}"
APPCAST_URL="${AIMETER_SU_FEED_URL:-https://raw.githubusercontent.com/OWNER/REPO/main/docs/aimeter-appcast.xml}"
ENTITLEMENTS="$ROOT/Support/entitlements.plist"
APP="$ROOT/dist/AIMeter.app"
DMG="$ROOT/dist/AIMeter-${VERSION}.dmg"
ZIP="$ROOT/dist/AIMeter-${VERSION}.zip"

if [[ -n "$SDK_OVERRIDE" ]]; then
  echo "==> [1/6] swift build -c release --sdk $SDK_OVERRIDE"
  swift build -c release --sdk "$SDK_OVERRIDE"
else
  echo "==> [1/6] swift build -c release"
  swift build -c release
fi

echo "==> [2/6] assemble bundle (make-app.sh release)"
AIMETER_SDK="$SDK_OVERRIDE" AIMETER_SU_FEED_URL="$APPCAST_URL" scripts/make-app.sh release

echo "==> [3/6] sign (identity: ${IDENTITY:-adhoc})"
# Keep the signed release bundle in /tmp: ~/Documents is iCloud file-provider
# synced and re-stamps FinderInfo xattrs that invalidate code signatures.
STAGE="$(mktemp -d /tmp/aimeter-release.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
SIGNED_APP="$STAGE/AIMeter.app"
cp -R "$APP" "$SIGNED_APP"
xattr -cr "$SIGNED_APP"
# Nested code first (Sparkle framework), then the app with entitlements.
if [[ -n "$IDENTITY" ]]; then
  if [[ -d "$SIGNED_APP/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SIGNED_APP/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$SIGNED_APP"
else
  if [[ -d "$SIGNED_APP/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force -s - "$SIGNED_APP/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --deep -s - "$SIGNED_APP"
fi
codesign --verify --deep --strict "$SIGNED_APP" || { echo "signature verify failed"; exit 1; }

echo "==> [4/6] notarize + staple (skipped when no identity/profile/tooling)"
NOTARY="$(command -v xcrun && xcrun --find notarytool 2>/dev/null || true)"
if [[ -n "$IDENTITY" && -n "$NOTARY_PROFILE" && -x "$NOTARY" ]]; then
  ditto -c -k --keepParent "$SIGNED_APP" "$ZIP"
  "$NOTARY" submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  "$(dirname "$NOTARY")/stapler" staple "$SIGNED_APP" 2>/dev/null || xcrun stapler staple "$SIGNED_APP"
  rm -f "$ZIP"
else
  echo "   (notarization skipped — not distributable yet)"
fi

echo "==> [5/6] build DMG (hdiutil, zero deps)"
DMG_STAGE="$STAGE/dmg-stage-${VERSION}"
DMG_TEMP="$STAGE/AIMeter-${VERSION}.dmg"
rm -rf "$DMG_STAGE" "$DMG_TEMP" "$DMG"
mkdir -p "$DMG_STAGE/.background"
cp -R "$SIGNED_APP" "$DMG_STAGE/AIMeter.app"
xattr -cr "$DMG_STAGE/AIMeter.app"
codesign --verify --deep --strict "$DMG_STAGE/AIMeter.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp "$ROOT/Assets/dmg-background.png" "$DMG_STAGE/.background/background.png"
if [[ -f "$ROOT/Assets/icon.icns" ]]; then
  cp "$ROOT/Assets/icon.icns" "$DMG_STAGE/.VolumeIcon.icns"
  command -v SetFile >/dev/null 2>&1 && SetFile -a C "$DMG_STAGE" || true
fi
hdiutil create -volname "AIMeter" -srcfolder "$DMG_STAGE" \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG_TEMP" >/dev/null
# Sign the DMG itself with the same identity (required alongside notarization).
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$DMG_TEMP"
  codesign --verify --strict "$DMG_TEMP"
fi
hdiutil verify "$DMG_TEMP"
mv "$DMG_TEMP" "$DMG"

echo "==> [6/6] Sparkle appcast → docs/aimeter-appcast.xml"
ED_SIGNATURE="$(swift scripts/sparkle-sign.swift "$DMG")"
DMG_SIZE="$(stat -f %z "$DMG")"
python3 - "$VERSION" "$BASE_URL" "$DMG_SIZE" "$ED_SIGNATURE" <<'PY'
import plistlib, sys
version, base_url, size, sig = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>AIMeter</title>
    <link>{base_url}/../..</link>
    <description>AIMeter — AI subscription usage HUD</description>
    <language>en</language>
    <item>
      <title>Version {version}</title>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <pubDate>&#10;&#13;</pubDate>
      <enclosure url="{base_url}/AIMeter-{version}.dmg" length="{size}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
    </item>
  </channel>
</rss>
"""
open("docs/aimeter-appcast.xml", "w").write(appcast)
print("appcast written (version %s, sig %s…)" % (version, sig[:16]))
PY

echo
echo "==> artifact: $DMG"
echo "    to distribute: set DEVELOPER_ID_IDENTITY + AIMETER_NOTARY_PROFILE and re-run;"
echo "    appcast is docs/aimeter-appcast.xml (placeholder base URL until the"
echo "    repo is pushed to GitHub)."