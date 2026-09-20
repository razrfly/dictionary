#!/bin/sh
# Rebuilds sketch.css from tailwind.css. Run from anywhere; paths are resolved
# against the repository root.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
bin=$(ls "$root"/_build/tailwind-* 2>/dev/null | head -1)
[ -x "$bin" ] || { echo "no tailwind binary in _build; run: mix tailwind.install" >&2; exit 1; }
NODE_PATH="$root/deps:$root/_build/dev" "$bin" \
  --input="$root/docs/sketches/word-page/tailwind.css" \
  --output="$root/docs/sketches/word-page/sketch.css" \
  --minify
echo "built $root/docs/sketches/word-page/sketch.css"
