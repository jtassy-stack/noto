#!/usr/bin/env bash
# Rebuilds Noto/Resources/pawnote-bundle.js from Noto/Resources/pawnote-bridge.js
# with the pinned @niicojs/pawnote + esbuild (package-lock.json). CI runs the
# same build and fails when the committed bundle differs. Never hand-edit the
# bundle: change pawnote-bridge.js (or bump the pin) and run this script.
set -euo pipefail
cd "$(dirname "$0")"
npm ci --no-audit --no-fund --loglevel=error
npm run --silent build
node --check ../../Noto/Resources/pawnote-bundle.js
echo "pawnote-bundle.js rebuilt ($(wc -c < ../../Noto/Resources/pawnote-bundle.js) bytes)"
