#!/usr/bin/env bash
# Runs every test that doesn't need Xcode: relay, TroveCore, browser extension.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ Relay (Workers runtime)"
(cd server && npm install --silent && npx vitest run && npx tsc --noEmit)

echo "▶ TroveCore"
(cd Packages/TroveCore && swift test)

echo "▶ Browser extension"
node --experimental-strip-types --test extensions/browser/test/trv1.test.mjs

echo "✅ All green"
