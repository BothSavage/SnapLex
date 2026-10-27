#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:?Specify the path to SnapLex.app}"
APP_PATH="$(cd "$(dirname "$INPUT_PATH")" && pwd)/$(basename "$INPUT_PATH")"
EXECUTABLE="$APP_PATH/Contents/MacOS/SnapLex"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "SnapLex executable is missing from $APP_PATH." >&2
    exit 1
fi
if ! /usr/bin/strings "$EXECUTABLE" | /usr/bin/grep -F -- '--verify-installation' >/dev/null; then
    echo "This SnapLex executable does not support the headless installation check." >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
# Launch the packaged executable without opening the UI or relying on the repo's working directory.
(cd "${TMPDIR:-/tmp}" && "$EXECUTABLE" --verify-installation)
