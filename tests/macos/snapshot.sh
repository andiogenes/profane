#!/bin/sh
# Opens a real window and requires that AppKit presented at least one Metal frame before the
# offscreen snapshot is written (regression: the CAMetalLayer view never drew on screen).
# Needs a GUI login session.
set -eu
app="$1"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
PROFANE_REPL_SOCKET="$dir/repl.sock" "$app/Contents/MacOS/profane" --snapshot "$dir/frame.png"
[ -s "$dir/frame.png" ] || { echo "no snapshot written" >&2; exit 1; }
