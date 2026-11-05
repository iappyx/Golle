#!/bin/bash
# Renders the README screenshots into docs/screenshots from the real views, with demo data.
# The windows stay off screen and Golle never activates, so nothing on your screen changes.
# Usage: scripts/screenshots.sh [light|dark]
set -euo pipefail
cd "$(dirname "$0")/.."

APPEARANCE="${1:-light}"
scripts/build-app.sh debug >/dev/null 2>&1 || { echo "build failed: run scripts/build-app.sh debug to see why" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# English and a neutral locale, whatever this Mac is set to.
build/Golle.app/Contents/MacOS/Golle --screenshots "$TMP" "$APPEARANCE" \
  -AppleLanguages '(en)' -AppleLocale en_IE >/dev/null 2>&1

OUT=docs/screenshots
mkdir -p "$OUT"
for pair in 1-table:table 11-gallery-grouped:gallery 3-form:form 8-board:board 9-calendar:calendar \
            10-map:map 14-chart:chart 16-dashboard:dashboard 26-timeline-grouped:timeline 28-report:report \
            27-rules:rules; do
  cp "$TMP/${pair%%:*}.png" "$OUT/${pair##*:}.png"
done
echo "Updated $OUT"
