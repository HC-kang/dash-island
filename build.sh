#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DashIsland"
BUNDLE_ID="dev.dashisland.DashIsland"
VERSION="$(cat VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must be X.Y.Z (got '$VERSION')" >&2
  exit 1
fi

BUILD_DIR="./build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

SWIFT_SOURCES=$(find Sources -name '*.swift' | sort)

DEPLOYMENT_TARGET="13.0"

swiftc \
  -target "arm64-apple-macos${DEPLOYMENT_TARGET}" \
  -O \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -framework Security \
  -o "$MACOS_DIR/$APP_NAME" \
  $SWIFT_SOURCES

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Dash Island</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - --timestamp=none "$APP_DIR"

echo "✓ built $APP_DIR ($VERSION)"
