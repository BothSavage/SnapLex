#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> [1/3] Compiling SnapLex (arm64 native release)..."
swift build -c release

APP_DIR="$ROOT_DIR/dist/SnapLex.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> [2/3] Packaging macOS App Bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/SnapLex" "$MACOS_DIR/SnapLex"
chmod +x "$MACOS_DIR/SnapLex"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SnapLex</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.snaplex.app</string>
    <key>CFBundleName</key>
    <string>SnapLex</string>
    <key>CFBundleDisplayName</key>
    <string>SnapLex</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> [3/3] Signing SnapLex.app with Apple Development identity for persistent TCC permissions..."
SIGN_ID=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk '{print $2}' || true)
if [ -n "$SIGN_ID" ]; then
    codesign --force --deep --sign "$SIGN_ID" "$APP_DIR"
else
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "✅ Done! App bundle created at: $APP_DIR"
echo "   Binary size: $(du -sh "$MACOS_DIR/SnapLex" | cut -f1)"
