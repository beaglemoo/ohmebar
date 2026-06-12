#!/bin/bash
# Standalone release build.
#
# Default: ad-hoc signed app, runs on the machine that built it.
#   ./build.sh
#
# Distribution: set a Developer ID identity, and optionally a notarytool
# keychain profile to notarize and staple the result.
#   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="notarytool-profile" ./build.sh
set -e

APP_NAME="OhmeBar"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "Compiling $APP_NAME..."
swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework SwiftUI -framework Security \
  -framework Combine -framework ServiceManagement -framework CryptoKit \
  -O \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  OhmeBar/*.swift \
  OhmeBar/**/*.swift

if [ -f "Assets/AppIcon.icns" ]; then
  cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>OhmeBar</string>
	<key>CFBundleIdentifier</key>
	<string>com.cb.ohmebar</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>OhmeBar</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

echo "Signing with: $SIGNING_IDENTITY"
codesign --force --options runtime \
  --entitlements OhmeBar/OhmeBar.entitlements \
  --sign "$SIGNING_IDENTITY" \
  "$APP_BUNDLE"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing..."
  ditto -c -k --keepParent "$APP_BUNDLE" "$BUILD_DIR/$APP_NAME-notarize.zip"
  xcrun notarytool submit "$BUILD_DIR/$APP_NAME-notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm "$BUILD_DIR/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$BUILD_DIR/$APP_NAME-$VERSION.zip"
  echo "Release artifact: $BUILD_DIR/$APP_NAME-$VERSION.zip"
fi

echo "Done: $APP_BUNDLE"
