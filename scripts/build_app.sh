#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="${SNAPLEX_VERSION:-1.0.6}"
APP_BUILD_NUMBER="${SNAPLEX_BUILD_NUMBER:-$APP_VERSION}"

echo "==> [1/3] Compiling SnapLex (arm64 native release)..."
swift build -c release

APP_DIR="${SNAPLEX_APP_OUTPUT_DIR:-$ROOT_DIR/dist}/SnapLex.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> [2/3] Packaging macOS App Bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/SnapLex" "$MACOS_DIR/SnapLex"
chmod +x "$MACOS_DIR/SnapLex"

ICON_TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/snaplex-icon.XXXXXX")"
ICONSET_DIR="$ICON_TEMP_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
ICON_SOURCE="$ROOT_DIR/Assets/AppIcon-1024.png"
for spec in "16 16 16" "16 16 32" "32 32 32" "32 32 64" "128 128 128" "128 128 256" "256 256 256" "256 256 512" "512 512 512"; do
    read -r base height pixels <<< "$spec"
    suffix=""
    if [ "$pixels" -eq $((base * 2)) ]; then suffix="@2x"; fi
    sips -z "$pixels" "$pixels" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${base}x${base}${suffix}.png" >/dev/null
done
cp "$ICON_SOURCE" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICON_TEMP_ROOT"

# SwiftPM stores processed resources (including the user-editable i18n catalog)
# in a sibling bundle. Keep it inside the app bundle so Bundle.module can find it.
RESOURCE_BUNDLE=".build/release/SnapLex_SnapLex.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$CONTENTS_DIR/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/Sparkle.framework"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>用于在录屏时录制麦克风音频。</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>用于按你的选择录制屏幕区域。</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/BothSavage/SnapLex/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>mVBZlQtFsQAnDQeK67N1iHhLqFESazmbYuox/6yOrPY=</string>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUEnableAutomaticChecks</key>
    <false/>
</dict>
</plist>
EOF

echo "==> [3/3] Signing SnapLex.app..."
SIGN_ID="${SNAPLEX_SIGN_IDENTITY:-}"
SIGNING_KEYCHAIN="${SNAPLEX_SIGNING_KEYCHAIN:-}"
if [ -z "$SIGNING_KEYCHAIN" ]; then
    PERSISTENT_SIGNING_KEYCHAIN="${HOME}/Library/Application Support/SnapLex/Signing/SnapLex-Stable-Signing.keychain-db"
    if [ -f "$PERSISTENT_SIGNING_KEYCHAIN" ]; then
        LOGIN_KEYCHAIN="$(security login-keychain | sed -E 's/^[[:space:]]*"//; s/"$//')"
        KEYCHAIN_PASSWORD="$(security find-generic-password -a "$(id -un)" -s io.github.snaplex.release-signing-keychain -w "$LOGIN_KEYCHAIN" 2>/dev/null || true)"
        if [ -n "$KEYCHAIN_PASSWORD" ]; then
            security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$PERSISTENT_SIGNING_KEYCHAIN"
            SIGNING_KEYCHAIN="$PERSISTENT_SIGNING_KEYCHAIN"
        fi
    fi
fi
if [ -z "$SIGN_ID" ]; then
    if [ -n "$SIGNING_KEYCHAIN" ]; then
        SIGN_ID=$(security find-identity -p codesigning "$SIGNING_KEYCHAIN" | awk -F '"' '/SnapLex Stable Code Signing/ { print $2; exit }' || true)
    else
        SIGN_ID=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk '{print $2}' || true)
    fi
fi
if [ -n "$SIGN_ID" ]; then
    if [ "${SNAPLEX_HARDENED_RUNTIME:-0}" = "1" ]; then
        SIGN_OPTIONS=(--options runtime)
    else
        SIGN_OPTIONS=()
    fi
else
    if [ "${SNAPLEX_HARDENED_RUNTIME:-0}" = "1" ]; then
        echo "SNAPLEX_HARDENED_RUNTIME=1 requires SNAPLEX_SIGN_IDENTITY." >&2
        exit 1
    fi
    SIGN_ID="-"
    SIGN_OPTIONS=()
fi

FRAMEWORK="$CONTENTS_DIR/Frameworks/Sparkle.framework"
SIGNING_ARGS=(--force --sign "$SIGN_ID")
if [ -n "$SIGNING_KEYCHAIN" ]; then
    SIGNING_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
fi
APP_SIGNING_ARGS=("${SIGNING_ARGS[@]}")
if [ "${SNAPLEX_DISABLE_LIBRARY_VALIDATION:-0}" = "1" ]; then
    APP_SIGNING_ARGS+=(--entitlements "$ROOT_DIR/scripts/SnapLex-selfsigned.entitlements")
fi
codesign "${SIGNING_ARGS[@]}" "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGNING_ARGS[@]}" "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGNING_ARGS[@]}" "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGNING_ARGS[@]}" "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGNING_ARGS[@]}" "${SIGN_OPTIONS[@]}" "$FRAMEWORK"
codesign "${APP_SIGNING_ARGS[@]}" "${SIGN_OPTIONS[@]}" "$APP_DIR"

# Release builds must use the persistent self-signed identity. Its certificate
# leaf hash is checked against the value pinned in GitHub Actions variables.
if [ "${SNAPLEX_REQUIRE_STABLE_SIGNING:-0}" = "1" ]; then
    EXPECTED_CERT_SHA1="$(printf '%s' "${SNAPLEX_EXPECTED_SIGNING_CERT_SHA1:-}" | tr '[:lower:]' '[:upper:]' | tr -d ':[:space:]')"
    if [[ ! "$EXPECTED_CERT_SHA1" =~ ^[0-9A-F]{40}$ ]]; then
        echo "SNAPLEX_EXPECTED_SIGNING_CERT_SHA1 must contain the pinned 40-character certificate SHA-1." >&2
        exit 1
    fi
    SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
    DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1)"
    REQUIREMENT_UPPER="$(printf '%s' "$DESIGNATED_REQUIREMENT" | tr '[:lower:]' '[:upper:]')"
    if printf '%s\n' "$SIGNATURE_INFO" | grep -q '^Signature=adhoc' || \
        ! printf '%s' "$REQUIREMENT_UPPER" | grep -Fq "CERTIFICATE LEAF = H\"$EXPECTED_CERT_SHA1\""; then
        echo "SnapLex.app was not signed with the pinned stable signing certificate." >&2
        echo "Observed designated requirement: $DESIGNATED_REQUIREMENT" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$APP_DIR"
    echo "   Stable signing certificate: $EXPECTED_CERT_SHA1"
fi

echo "✅ Done! App bundle created at: $APP_DIR"
echo "   Binary size: $(du -sh "$MACOS_DIR/SnapLex" | cut -f1)"
