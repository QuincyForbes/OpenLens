#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/DerivedDataMac}"
OUTPUT_DMG="${OUTPUT_DMG:-$ROOT_DIR/OpenLens-macOS.dmg}"
STAGING_DIR="$ROOT_DIR/build/dmg-staging"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

echo "[build-macos-dmg] Building Universal Mac Catalyst OpenLens.app (arm64 + x86_64)..."
xcodebuild \
  -project OpenLens.xcodeproj \
  -scheme OpenLensMac \
  -configuration Release \
  -destination "generic/platform=macOS,variant=Mac Catalyst" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  ENABLE_HARDENED_RUNTIME=NO \
  build

APP_PATH="$(find "$DERIVED_DATA_PATH/Build/Products" -maxdepth 2 -name "OpenLens.app" -type d | head -n 1)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "[build-macos-dmg] ERROR: Could not locate built OpenLens.app under $DERIVED_DATA_PATH/Build/Products" >&2
  exit 1
fi

echo "[build-macos-dmg] Found app bundle: $APP_PATH"
rm -rf "$STAGING_DIR" "$OUTPUT_DMG"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/OpenLens.app"

# Ad-hoc sign the universal bundle so Apple Silicon (arm64) and Intel Macs can
# launch OpenLens.app directly without amfid rejecting an unsigned Mach-O binary.
echo "[build-macos-dmg] Ad-hoc signing OpenLens.app..."
codesign --force --deep --sign - "$STAGING_DIR/OpenLens.app"

echo "[build-macos-dmg] Smoke-testing OpenLens.app startup on macOS..."
"$STAGING_DIR/OpenLens.app/Contents/MacOS/OpenLens" &
SMOKE_PID=$!
sleep 3
if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
  SMOKE_EXIT=0
  wait "$SMOKE_PID" || SMOKE_EXIT=$?
  echo "[build-macos-dmg] ERROR: OpenLens.app crashed or exited during launch smoke test (exit code $SMOKE_EXIT)!" >&2
  exit 1
fi
kill "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
echo "[build-macos-dmg] Startup smoke test passed!"

ln -s /Applications "$STAGING_DIR/Applications"

echo "[build-macos-dmg] Packaging DMG -> $OUTPUT_DMG"
hdiutil create \
  -volname "OpenLens" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_DMG"

ls -lh "$OUTPUT_DMG"
echo "[build-macos-dmg] Done: $OUTPUT_DMG"
