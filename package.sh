#!/bin/bash
set -euo pipefail

# Builds the app, names it "Galaxy Buds.app", and produces a distributable
# drag-to-Applications .dmg in dist/.

APP_NAME="Galaxy Buds"
VERSION="${1:-1.0.0}"
DIST="dist"
STAGE="$DIST/stage"
DMG="$DIST/Galaxy-Buds-$VERSION.dmg"

echo "==> Building…"
bash build.sh

echo "==> Staging $APP_NAME.app…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "BudsApp.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating .dmg…"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$STAGE"
echo "==> Done: $DMG"
echo "    SHA256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
