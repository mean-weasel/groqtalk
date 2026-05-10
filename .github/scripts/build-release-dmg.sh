#!/usr/bin/env bash
set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is required}"
: "${APP_STORE_CONNECT_PRIVATE_KEY:?APP_STORE_CONNECT_PRIVATE_KEY is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

ARCHIVE_PATH="$RUNNER_TEMP/GroqTalk.xcarchive"
EXPORT_PATH="$RUNNER_TEMP/export"
DMG_ROOT="$RUNNER_TEMP/dmg-root"
DMG_PATH="$RUNNER_TEMP/GroqTalk-${VERSION}-macos.dmg"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"

sed -i '' "s/\$(APPLE_TEAM_ID)/$APPLE_TEAM_ID/" ExportOptions.plist

xcodebuild archive \
  -scheme GroqTalk \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist ExportOptions.plist

codesign --verify --deep --strict "$EXPORT_PATH/GroqTalk.app"
codesign -dv "$EXPORT_PATH/GroqTalk.app"

APP_VERSION="$(defaults read "$EXPORT_PATH/GroqTalk.app/Contents/Info.plist" CFBundleShortVersionString)"
APP_BUILD="$(defaults read "$EXPORT_PATH/GroqTalk.app/Contents/Info.plist" CFBundleVersion)"
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "Expected CFBundleShortVersionString '$VERSION' but found '$APP_VERSION'" >&2
  exit 1
fi
if [ "$APP_BUILD" != "$BUILD_NUMBER" ]; then
  echo "Expected CFBundleVersion '$BUILD_NUMBER' but found '$APP_BUILD'" >&2
  exit 1
fi
echo "Verified app bundle version: $APP_VERSION ($APP_BUILD)"

brew install create-dmg

mkdir -p "$DMG_ROOT"
cp -R "$EXPORT_PATH/GroqTalk.app" "$DMG_ROOT/GroqTalk.app"

create-dmg \
  --volname "GroqTalk" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "GroqTalk.app" 150 190 \
  --app-drop-link 450 190 \
  "$DMG_PATH" \
  "$DMG_ROOT"

codesign --force \
  --sign "Developer ID Application" \
  --timestamp \
  "$DMG_PATH"

PRIVATE_KEYS_DIR="$RUNNER_TEMP/private_keys"
mkdir -p "$PRIVATE_KEYS_DIR"
KEY_PATH="$PRIVATE_KEYS_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

xcrun notarytool submit \
  "$DMG_PATH" \
  --key "$KEY_PATH" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

xcrun stapler staple "$DMG_PATH"

spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

gh release upload "v${VERSION}" "$DMG_PATH" --clobber
