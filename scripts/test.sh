#!/bin/bash
# Builds and runs the unit tests. They run through the app binary (`Golle --test`), so no XCTest needed.
set -uo pipefail
cd "$(dirname "$0")/.."

LOG="${TMPDIR:-/tmp}/golle-build.log"
if ! scripts/build-app.sh "${1:-debug}" >"$LOG" 2>&1; then
  echo "BUILD FAILED — tests not run:"
  grep -E "error:" -A3 "$LOG" | head -40
  exit 1
fi

build/Golle.app/Contents/MacOS/Golle --test
