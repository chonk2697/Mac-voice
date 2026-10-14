#!/bin/zsh
# Builds the app bundle and launches it, replacing any running copy.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh "${1:-release}"
pkill -x Voice 2>/dev/null || true
open build/Voice.app
