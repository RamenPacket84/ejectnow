#!/bin/zsh
# Build a Developer ID–signed EjectNow.app and wrap it in a distributable .dmg.
# Usage: ./scripts/build-release-dmg.sh [version]
# Example: ./scripts/build-release-dmg.sh 1.0.0
#
# Notarization (optional, recommended before GitHub Releases):
#   xcrun notarytool store-credentials ejectnow
# Then re-run this script; it notarizes + staples when the profile exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
TEAM_ID="ZTVWS9B36C"
APP_SIGN_ID="Developer ID Application: Andrew Bacon (${TEAM_ID})"
NOTARY_PROFILE="${NOTARY_PROFILE:-ejectnow}"

DIST="$ROOT/dist"
DERIVED="$DIST/DerivedData"
STAGE="$DIST/dmg-stage"
APP_NAME="EjectNow"
APP_BUNDLE="${APP_NAME}.app"
VOL_NAME="EjectNow"
DMG_RW="$DIST/${APP_NAME}-rw.dmg"
DMG_PATH="$DIST/${APP_NAME}-${VERSION}.dmg"

echo "==> Cleaning dist/"
rm -rf "$DIST"
mkdir -p "$DIST" "$STAGE"

echo "==> Building Release (${APP_BUNDLE})"
xcodebuild \
  -project "$ROOT/ejectnow.xcodeproj" \
  -scheme ejectnow \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APP_SIGN_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build

BUILT_APP="$DERIVED/Build/Products/Release/${APP_BUNDLE}"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

echo "==> Re-signing with Developer ID + hardened runtime"
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --sign "$APP_SIGN_ID" \
  "$BUILT_APP"

codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

echo "==> Staging DMG contents"
ditto "$BUILT_APP" "$STAGE/${APP_BUNDLE}"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$DMG_RW"

# Compact to compressed read-only image
rm -f "$DMG_PATH"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_RW"

echo "==> Signing DMG"
codesign --force --timestamp --sign "$APP_SIGN_ID" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "==> Submitting DMG to Apple notary service (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  echo "==> Notarization + staple complete"
  spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" || true
else
  echo "==> Skipping notarization (no keychain profile '$NOTARY_PROFILE')"
  echo "    Do this before publishing to GitHub:"
  echo "      xcrun notarytool store-credentials $NOTARY_PROFILE"
  echo "    Then re-run: ./scripts/build-release-dmg.sh $VERSION"
fi

echo ""
echo "Built: $DMG_PATH"
ls -lh "$DMG_PATH"
