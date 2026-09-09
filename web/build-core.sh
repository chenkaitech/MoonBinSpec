#!/usr/bin/env sh
# Builds the shared MoonBit decoder core to a JS module and drops it next to
# the static Inspector, so the browser runs the exact same schema parser and
# decoder as the Native CLI (see webcore/webcore.mbt).
set -eu
cd "$(dirname "$0")/.."
moon build --target js webcore --release
cp _build/js/release/build/webcore/webcore.js web/webcore.js
printf '%s\n' 'Built web/webcore.js. Serve web/ with a static HTTP server.'
