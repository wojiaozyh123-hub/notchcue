#!/bin/bash
#
# Builds a universal (Apple silicon + Intel) NotchCue.app and a DMG.
#
#   SIGNING_IDENTITY="Developer ID Application: …"  sign with Developer ID
#   NOTARY_PROFILE="notchcue-notary"                 notarize and staple
#                                                    (a profile saved with
#                                                    `xcrun notarytool store-credentials`)
#
# Without SIGNING_IDENTITY the app is ad-hoc signed for local testing only.
#
set -euo pipefail

SCHEME="Textream"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
ARCHIVE_ARM="$BUILD_DIR/Textream-arm64.xcarchive"
ARCHIVE_X86="$BUILD_DIR/Textream-x86_64.xcarchive"
APP_NAME="NotchCue.app"
EXECUTABLE_NAME="NotchCue"
OUTPUT_DIR="$BUILD_DIR/universal"
OUTPUT_APP="$OUTPUT_DIR/$APP_NAME"
DEVELOPER_ID_ENTITLEMENTS="$PROJECT_DIR/Textream/Textream-DeveloperID.entitlements"

# Submits a file for notarization and fails unless Apple accepts it.
notarize() {
  local file="$1"
  echo "🛂 Notarizing $(basename "$file")… (usually a few minutes)"
  local result
  result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  echo "$result"
  if ! echo "$result" | grep -q '"status" *: *"Accepted"'; then
    local id
    id=$(echo "$result" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)
    echo "❌ Notarization was not accepted. Log:"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
  fi
}

if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${SIGNING_IDENTITY:-}" ]; then
  echo "❌ NOTARY_PROFILE needs SIGNING_IDENTITY: Apple only notarizes Developer ID-signed apps."
  exit 1
fi

echo "🧹 Cleaning previous build…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "🔨 Building for Apple Silicon (arm64)…"
xcodebuild archive \
  -project "$PROJECT_DIR/Textream.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_ARM" \
  -destination "generic/platform=macOS" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -quiet

echo "🔨 Building for Intel (x86_64)…"
xcodebuild archive \
  -project "$PROJECT_DIR/Textream.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_X86" \
  -destination "generic/platform=macOS" \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -quiet

ARM_APP="$ARCHIVE_ARM/Products/Applications/$APP_NAME"
X86_APP="$ARCHIVE_X86/Products/Applications/$APP_NAME"

echo "🧬 Creating universal binary…"
cp -R "$ARM_APP" "$OUTPUT_APP"

# Find all Mach-O binaries and lipo them together
find "$ARM_APP" -type f | while read -r arm_file; do
  rel="${arm_file#$ARM_APP}"
  x86_file="$X86_APP$rel"
  out_file="$OUTPUT_APP$rel"

  if [ -f "$x86_file" ] && file "$arm_file" | grep -q "Mach-O"; then
    lipo -create "$arm_file" "$x86_file" -output "$out_file"
    lipo "$out_file" -verify_arch arm64 x86_64
  fi
done

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$OUTPUT_APP/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/NotchCue-$VERSION.dmg"

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  echo "🖋️  Signing universal app with Developer ID…"
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    --entitlements "$DEVELOPER_ID_ENTITLEMENTS" \
    "$OUTPUT_APP"

  codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
else
  echo "⚠️  SIGNING_IDENTITY is not set; creating an ad-hoc signed local build."
  codesign --force --sign - "$OUTPUT_APP"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  # Notarize the app itself and staple its ticket, so it opens offline
  # after being copied out of the DMG.
  APP_ZIP="$BUILD_DIR/NotchCue-$VERSION-app.zip"
  ditto -c -k --keepParent "$OUTPUT_APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$OUTPUT_APP"
  rm -f "$APP_ZIP"
fi

echo "📦 Creating DMG…"
rm -f "$DMG_PATH"

# Create a temporary DMG folder with the app and an Applications symlink
DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$OUTPUT_APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "NotchCue" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" \
  -quiet

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  echo "🖋️  Signing DMG with Developer ID…"
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    --identifier app.notchcue.dmg \
    "$DMG_PATH"

  codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "🔎 Gatekeeper check:"
  spctl --assess --type execute --verbose=2 "$OUTPUT_APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

rm -rf "$DMG_STAGING"

echo ""
echo "✅ Done!"
echo "   App:  $OUTPUT_APP"
echo "   DMG:  $DMG_PATH"
echo ""
lipo -info "$OUTPUT_APP/Contents/MacOS/$EXECUTABLE_NAME"
