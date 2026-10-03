#!/usr/bin/env bash
# Ad-hoc signs a bundle on a staging copy in /tmp, then swaps it back.
#
# Why staging: the repo lives under ~/Documents (iCloud file provider), which
# re-stamps com.apple.FinderInfo / com.apple.fileprovider.fpfs#P on every file
# shortly after creation — codesign rejects those ("resource fork, Finder
# information, or similar detritus not allowed"). /tmp is provider-free, so the
# attrs cleared by xattr -cr stay cleared through the sign.
set -euo pipefail

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
STAGE="$(mktemp -d /tmp/aimeter-sign.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/AIMeter.app"
xattr -cr "$STAGE/AIMeter.app"

if [[ -d "$STAGE/AIMeter.app/Contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force -s - "$STAGE/AIMeter.app/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --deep -s - "$STAGE/AIMeter.app"
codesign --verify --deep --strict "$STAGE/AIMeter.app"

rm -rf "$APP"
mv "$STAGE/AIMeter.app" "$APP"
# Clear FinderInfo that iCloud may add while moving the bundle back, then
# verify the on-disk result as well as the staged signature above.
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
echo "signed (adhoc): $(basename "$APP")"
