#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/dist/Shuo.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/Shuo.app"

"$PROJECT_DIR/scripts/build-app.sh"
/bin/mkdir -p "$TARGET_DIR"
/usr/bin/pkill -x Shuo 2>/dev/null || true
/bin/rm -rf "$TARGET_APP"
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
/usr/bin/open "$TARGET_APP"
echo "Installed $TARGET_APP"
