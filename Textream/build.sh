#!/bin/bash
#
# Builds a universal (Apple silicon + Intel) NotchCue.app signed with
# Developer ID, and a DMG.
#
#   NOTARY_PROFILE="notchcue-notary"  notarize and staple; the profile is
#                                     saved once with
#                                     `xcrun notarytool store-credentials`
#   TEAM_ID="A9K69U4GT3"              signing team (default below)
#
# Signing goes through Xcode's automatic Developer ID export
# (-allowProvisioningUpdates): it uses the team's Developer ID certificate if
# this Mac has one, or Apple's cloud-managed certificate otherwise, so no
# certificate has to be created by hand. Xcode must be signed in to the team's
# account (Xcode → Settings → Accounts).
#
set -euo pipefail

SCHEME="Textream"
TEAM_ID="${TEAM_ID:-A9K69U4GT3}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
ARCHIVE="$BUILD_DIR/NotchCue.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
APP="$EXPORT_DIR/NotchCue.app"
EXECUTABLE_NAME="NotchCue"
DEVELOPER_ID_ENTITLEMENTS="$PROJECT_DIR/Textream/Textream-DeveloperID.entitlements"

# Submits a file for notarization and fails unless Apple accepts it.
notarize() {
  local file="$1"
  echo "🛂 Notarizing $(basename "$file")… (usually a few minutes)"
  local result
  result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  echo "$result"
  if ! grep -q '"status" *: *"Accepted"' <<< "$result"; then
    local id
    id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<< "$result" | head -1)
    echo "❌ Notarization was not accepted. Log:"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
  fi
}

echo "🧹 Cleaning previous build…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "🔨 Archiving for Apple Silicon and Intel…"
xcodebuild archive \
  -project "$PROJECT_DIR/Textream.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Development" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_ENTITLEMENTS="$DEVELOPER_ID_ENTITLEMENTS" \
  -allowProvisioningUpdates \
  -quiet

echo "🖋️  Exporting with Developer ID…"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  -quiet

codesign --verify --deep --strict --verbose=2 "$APP"
# Read the signature into a variable first: with pipefail, `codesign | grep -q`
# fails whenever grep stops reading early.
SIGNATURE=$(codesign -dv --verbose=2 "$APP" 2>&1)
if ! grep -q "Authority=Developer ID Application" <<< "$SIGNATURE"; then
  echo "❌ The exported app is not signed with Developer ID."
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/NotchCue-$VERSION.dmg"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  # Notarize the app itself and staple its ticket, so it opens offline
  # after being copied out of the DMG.
  APP_ZIP="$BUILD_DIR/NotchCue-$VERSION-app.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  xcrun stapler staple "$APP"
  rm -f "$APP_ZIP"
fi

echo "📦 Creating DMG…"
DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "NotchCue" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" \
  -quiet
rm -rf "$DMG_STAGING"

# A cloud-managed certificate can only sign through Xcode's export, so the
# DMG is signed only when this Mac holds a Developer ID certificate. The app
# inside is signed and notarized either way.
LOCAL_IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" | head -1)
if [ -n "$LOCAL_IDENTITY" ]; then
  echo "🖋️  Signing DMG with $LOCAL_IDENTITY…"
  codesign --force --sign "$LOCAL_IDENTITY" --timestamp --identifier app.notchcue.dmg "$DMG_PATH"
  codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "🔎 Gatekeeper check:"
  spctl --assess --type execute --verbose=2 "$APP"
  xcrun stapler validate "$DMG_PATH"
fi

echo ""
echo "✅ Done!"
echo "   App:  $APP"
echo "   DMG:  $DMG_PATH"
echo ""
lipo -info "$APP/Contents/MacOS/$EXECUTABLE_NAME"
