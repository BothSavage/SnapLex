#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 /path/to/SnapLex.app /path/to/output.dmg" >&2
    exit 1
fi

APP_DIR="$1"
DMG_PATH="$2"
ICON_PATH="$APP_DIR/Contents/Resources/AppIcon.icns"
if [ ! -d "$APP_DIR" ] || [ ! -f "$ICON_PATH" ]; then
    echo "SnapLex.app or its app icon is missing: $APP_DIR" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaplex-dmg.XXXXXX")"
MOUNT_DIR="$STAGING_DIR/mount"
CONTENT_DIR="$STAGING_DIR/content"
RW_DMG="$STAGING_DIR/writable.dmg"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" = 1 ] && ! hdiutil detach "$MOUNT_DIR" -quiet; then
        echo "Could not detach the image; temporary files remain at $STAGING_DIR." >&2
        return
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
mkdir -p "$CONTENT_DIR" "$MOUNT_DIR"
ditto "$APP_DIR" "$CONTENT_DIR/SnapLex.app"
ln -s /Applications "$CONTENT_DIR/Applications"
cp "$ICON_PATH" "$CONTENT_DIR/.VolumeIcon.icns"
hdiutil create -volname SnapLex -srcfolder "$CONTENT_DIR" -format UDRW "$RW_DMG"
hdiutil attach -nobrowse -noverify -quiet -mountpoint "$MOUNT_DIR" "$RW_DMG"
MOUNTED=1
SetFile -a C "$MOUNT_DIR"
hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0
hdiutil convert "$RW_DMG" -ov -format UDZO -o "$DMG_PATH"
