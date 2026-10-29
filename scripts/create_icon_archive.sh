#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 /path/to/input.dmg /path/to/AppIcon.icns /path/to/output.zip" >&2
    exit 1
fi

DMG_PATH="$1"
ICON_PATH="$2"
ZIP_PATH="$3"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaplex-icon-archive.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_DMG="$STAGING_DIR/$(basename "$DMG_PATH")"
cp "$DMG_PATH" "$STAGED_DMG"
swift "$(dirname "$0")/set_file_icon.swift" "$ICON_PATH" "$STAGED_DMG"
ditto -c -k --sequesterRsrc "$STAGING_DIR" "$ZIP_PATH"
