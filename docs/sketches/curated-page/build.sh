#!/bin/sh
# Rebuilds the #309 sketches: the pages from content.json, then sketch.css.
# Run from anywhere; paths are resolved against the repository root.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
dir="$root/docs/sketches/curated-page"
python3 -I "$dir/build.py" "$dir"
bin=$(ls "$root"/_build/tailwind-* 2>/dev/null | head -1)
[ -x "$bin" ] || { echo "no tailwind binary in _build; run: mix tailwind.install" >&2; exit 1; }
# phoenix-colocated is compiled under the build env; a worktree may have only test.
env=$( [ -d "$root/_build/dev/phoenix-colocated" ] && echo dev || echo test )
NODE_PATH="$root/deps:$root/_build/$env" "$bin" \
  --input="$dir/tailwind.css" \
  --output="$dir/sketch.css" \
  --minify
echo "built $dir/sketch.css"
