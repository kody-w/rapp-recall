#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build
BIN_DIR="$(swift build --show-bin-path)"
"$BIN_DIR/RappRecall" acceptance

if command -v sandbox-exec >/dev/null 2>&1; then
  # The acceptance path must not merely work offline by accident. Deny every
  # network operation while leaving filesystem/framework access intact.
  sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    "$BIN_DIR/RappRecall" acceptance
fi
