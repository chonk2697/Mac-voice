#!/bin/zsh
# Builds the Voice menu bar app into build/Voice.app using only SwiftPM.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Voice.app"

swift build -c "$CONFIG" --product Voice
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Voice"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Voice"
cp App/Info.plist "$APP/Contents/Info.plist"
[[ -f App/Voice.icns ]] && cp App/Voice.icns "$APP/Contents/Resources/Voice.icns"

# Prefer a real development certificate when one exists: its signature is
# stable across rebuilds, so macOS asks for microphone access once rather
# than after every build. Falls back to ad-hoc signing.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"

echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
