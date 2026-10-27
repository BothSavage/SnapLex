#!/usr/bin/env bash
set -euo pipefail

# Build the signed feed next to a manually packaged release DMG.
# Usage: ./scripts/generate_appcast.sh 1.2.3 /path/to/SnapLex-1.2.3-macOS-arm64-unnotarized.dmg [release-notes.md]
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Specify a version, for example 1.2.3}"
DMG_PATH="${2:?Specify the release DMG}"
NOTES_PATH="${3:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use MAJOR.MINOR.PATCH." >&2
    exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then echo "DMG does not exist." >&2; exit 1; fi
DMG_NAME="$(basename "$DMG_PATH")"
case "$DMG_NAME" in
    "SnapLex-${VERSION}-macOS-arm64.dmg"|"SnapLex-${VERSION}-macOS-arm64-unnotarized.dmg"|\
    "SnapLex-${VERSION}-macOS-x86_64.dmg"|"SnapLex-${VERSION}-macOS-x86_64-unnotarized.dmg") ;;
    *) echo "DMG name must match the release version and architecture." >&2; exit 1 ;;
esac
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
ACCOUNT="io.github.snaplex.updates"
PUBLIC_KEY="mVBZlQtFsQAnDQeK67N1iHhLqFESazmbYuox/6yOrPY="
if [[ ! -x "$TOOLS/generate_appcast" ]]; then
    echo "Resolve Swift packages first: swift package resolve" >&2
    exit 1
fi
ACTUAL_KEY="$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)"
if [[ "$ACTUAL_KEY" != "$PUBLIC_KEY" ]]; then
    echo "The Sparkle signing key does not match the key embedded in SnapLex." >&2
    exit 1
fi
OUTPUT_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
if [[ -e "$OUTPUT_DIR/appcast.xml" ]]; then
    echo "appcast.xml already exists; refusing to overwrite it." >&2
    exit 1
fi
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaplex-appcast.XXXXXX")"
MOUNT_DIR="$STAGING_DIR/mount"
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
mkdir -p "$MOUNT_DIR"
hdiutil attach -readonly -nobrowse -noverify -quiet -mountpoint "$MOUNT_DIR" "$DMG_PATH"
MOUNTED=1
APP_PATH="$MOUNT_DIR/SnapLex.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "The update image must contain SnapLex.app." >&2
    exit 1
fi
"$ROOT_DIR/scripts/verify_app_bundle.sh" "$APP_PATH"
SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1)"
REQUIREMENT_UPPER="$(printf '%s' "$DESIGNATED_REQUIREMENT" | tr '[:lower:]' '[:upper:]')"
if printf '%s\n' "$SIGNATURE_INFO" | grep -q '^Signature=adhoc' || \
    ! printf '%s' "$REQUIREMENT_UPPER" | grep -q 'CERTIFICATE LEAF = H"[0-9A-F]\{40\}"'; then
    echo "Updates must use a stable certificate-based code signature; ad-hoc signatures cannot preserve macOS permissions across builds." >&2
    exit 1
fi
EXPECTED_CERT_SHA1="$(printf '%s' "${SNAPLEX_EXPECTED_SIGNING_CERT_SHA1:-}" | tr '[:lower:]' '[:upper:]' | tr -d ':[:space:]')"
if [[ -n "$EXPECTED_CERT_SHA1" && "$REQUIREMENT_UPPER" != *"CERTIFICATE LEAF = H\"$EXPECTED_CERT_SHA1\""* ]]; then
    echo "Update app was signed with a certificate other than the pinned SnapLex signing identity." >&2
    exit 1
fi
hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0
cp "$DMG_PATH" "$STAGING_DIR/$DMG_NAME"
if [[ -n "$NOTES_PATH" ]]; then cp "$NOTES_PATH" "$STAGING_DIR/${DMG_NAME%.dmg}.md"; fi
"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/BothSavage/SnapLex/releases/download/v${VERSION}/" \
    "$STAGING_DIR"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGING_DIR/appcast.xml"
swift "$ROOT_DIR/scripts/verify_sparkle_feed.swift" "$STAGING_DIR/appcast.xml"
python3 - "$STAGING_DIR/appcast.xml" "$VERSION" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
items = root.findall('./channel/item')
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
if len(items) != 1 or any(items[0].findtext(namespace + name) != sys.argv[2]
                          for name in ('version', 'shortVersionString')):
    raise SystemExit('DMG version does not match the requested release version.')
PY
cp "$STAGING_DIR/appcast.xml" "$OUTPUT_DIR/appcast.xml"
echo "Signed update feed created at $OUTPUT_DIR/appcast.xml"
