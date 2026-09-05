#!/usr/bin/env bash
#
# build.sh — produce an UNSIGNED .ipa from the unzip-drop Xcode project.
# Runs on macOS / GitHub Actions macOS runner. No signing required.
# On failure it prints the actual error lines, not just a non-zero exit.
#
set -uo pipefail   # NOT -e: we catch failures ourselves and print details

APP_NAME="${APP_NAME:-unzip-drop}"
SCHEME="${SCHEME:-unzip-drop}"
CONFIG="${CONFIG:-Release}"

PROJECT="$(ls -d ./*.xcodeproj 2>/dev/null | head -n1)"
if [ -z "$PROJECT" ]; then echo "ERROR: no .xcodeproj found in $(pwd)"; exit 1; fi

BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
OUT="$BUILD_DIR/ipa"
LOG="$BUILD_DIR/xcodebuild.log"

mkdir -p "$BUILD_DIR"
: > "$LOG"

hr() { printf '%s\n' "------------------------------------------------------------"; }

dump_errors() {
  local rc="$1"
  echo ""
  hr
  echo "BUILD FAILED (exit $rc) — extracted errors:"
  hr
  grep -nE "error:|fatal error:|\*\* .*FAILED \*\*|Undefined symbols?|linker command failed|No such module|cannot find |does not conform|Command .* failed|Provisioning|code signing" "$LOG" \
    | tail -n 120 || echo "(no matching error lines — see full log below)"
  echo ""
  echo "----- last 80 lines of $LOG -----"
  tail -n 80 "$LOG"
  echo ""
  echo "Full log saved at: $LOG"
}

# run a command: stream to console AND log; on failure, print errors and exit
run() {
  echo ""
  echo "==> $*"
  ( "$@" ) 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then dump_errors "$rc"; exit "$rc"; fi
}

# soft run: log + show, but don't abort on failure
run_soft() {
  echo ""
  echo "==> (soft) $*"
  ( "$@" ) 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then echo "   (non-fatal: exited $rc, continuing)"; fi
}

echo "==> Environment"
echo "    pwd     : $(pwd)"
echo "    project : $PROJECT"
echo "    scheme  : $SCHEME  ($CONFIG)"
xcodebuild -version 2>&1 | tee -a "$LOG" || true
echo ""
echo "==> Schemes / targets in project"
run_soft xcodebuild -list -project "$PROJECT"

# Resolve Swift packages (ZIPFoundation). Non-fatal; archive re-resolves.
run_soft xcodebuild -project "$PROJECT" -scheme "$SCHEME" -resolvePackageDependencies \
  -derivedDataPath "$DERIVED" -skipPackagePluginValidation

# Archive, unsigned.
run xcodebuild \
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

APP_PATH="$(ls -d "$ARCHIVE"/Products/Applications/*.app 2>/dev/null | head -n1)"
if [ -z "$APP_PATH" ]; then
  echo "ERROR: no .app inside archive at $ARCHIVE"
  dump_errors 1
  exit 1
fi
echo ""
echo "==> Built: $APP_PATH"

rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP_PATH" "$OUT/Payload/"
( cd "$OUT" && zip -qry "$APP_NAME.ipa" Payload && rm -rf Payload )

echo ""
hr
echo "SUCCESS — IPA: $OUT/$APP_NAME.ipa"
ls -lh "$OUT/$APP_NAME.ipa"
hr
