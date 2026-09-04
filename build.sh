#!/usr/bin/env bash
#
# build.sh — produce an UNSIGNED .ipa from the unzip-drop Xcode project.
# Runs on a macOS machine or GitHub Actions macOS runner. No signing needed.
#
set -euo pipefail

APP_NAME="${APP_NAME:-unzip-drop}"
SCHEME="${SCHEME:-unzip-drop}"
CONFIG="${CONFIG:-Release}"

PROJECT="$(ls -d ./*.xcodeproj 2>/dev/null | head -n1)"
[ -n "$PROJECT" ] || { echo "No .xcodeproj found"; exit 1; }

BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
OUT="$BUILD_DIR/ipa"

echo "==> Project : $PROJECT"
echo "==> Scheme  : $SCHEME  ($CONFIG)"

# Resolve Swift packages first (ZIPFoundation).
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -resolvePackageDependencies \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation || true

# Archive without code signing.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
  clean archive

APP_PATH="$(ls -d "$ARCHIVE"/Products/Applications/*.app | head -n1)"
[ -n "$APP_PATH" ] || { echo "No .app in archive"; exit 1; }
echo "==> Built   : $APP_PATH"

rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP_PATH" "$OUT/Payload/"
( cd "$OUT" && zip -qry "$APP_NAME.ipa" Payload && rm -rf Payload )

echo "==> IPA     : $OUT/$APP_NAME.ipa"
ls -lh "$OUT/$APP_NAME.ipa"
