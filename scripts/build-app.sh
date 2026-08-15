#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d /tmp/rapp-recall-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/RappRecall.app"
OUTPUT_APP="$ROOT/build/RappRecall.app"
ARCHIVE="$ROOT/build/RappRecall-macos-arm64.tar.gz"

cd "$ROOT"
swift build -c release --product RappRecall
swift build -c release --product RecallAcceptance
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/RappRecall" "$APP/Contents/MacOS/RappRecall"
cp "$BIN_DIR/RecallAcceptance" "$APP/Contents/MacOS/RecallAcceptance"
chmod 0755 "$APP/Contents/MacOS/RappRecall" "$APP/Contents/MacOS/RecallAcceptance"

xattr -cr "$APP"
SIGNING_IDENTITY="${RAPP_RECALL_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/MacOS/RecallAcceptance"
  codesign --force --sign - "$APP"
else
  codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/RecallAcceptance"
  codesign --force --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

rm -f "$ARCHIVE"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$STAGING" RappRecall.app

mkdir -p "$STAGING/verify"
tar -xzf "$ARCHIVE" -C "$STAGING/verify"
codesign --verify --deep --strict "$STAGING/verify/RappRecall.app"

# Keep an unpacked convenience copy, but the archive extraction above is the
# release artifact whose signature is trusted. Synced folders may add Finder
# metadata after this script exits.
rm -rf "$OUTPUT_APP"
ditto --noextattr --norsrc "$APP" "$OUTPUT_APP"
xattr -cr "$OUTPUT_APP"

echo "$OUTPUT_APP"
echo "$ARCHIVE"
