#!/bin/sh
# What the window server actually shows (not the offscreen snapshot). Opt-in: needs a GUI
# session and Screen Recording permission for the terminal, so it is skipped (77) unless
# PROFANE_SCREEN_TESTS=1.
#
# Regression: frames presented from the render thread early in a window's life were not
# delivered, so the window kept its first (empty) frame: a blank *scratch* at startup, and
# edits made right after launch never appeared.
set -eu
[ "${PROFANE_SCREEN_TESTS:-}" = 1 ] || { echo "skipped: set PROFANE_SCREEN_TESTS=1"; exit 77; }
app="$1"
client="$2"
ink="$3"
here=$(cd "$(dirname "$0")" && pwd)

dir=$(mktemp -d /tmp/pf-screen.XXXX)
trap 'kill $pid 2>/dev/null || true; rm -rf "$dir"' EXIT

# First text line, in window points at 1x: below the 28 pt title bar plus 2 pt padding.
first_line_ink() {
    wid=$(osascript -l JavaScript "$here/window_id.js" "$pid")
    [ -n "$wid" ] || { echo "no profane window" >&2; exit 1; }
    screencapture -x -o -l"$wid" "$dir/w.png"
    scale=$(sips -g pixelWidth "$dir/w.png" | awk '/pixelWidth/ {print ($2 >= 1800) ? 2 : 1}')
    "$ink" "$dir/w.png" $((4 * scale)) $((31 * scale)) $((300 * scale)) $((14 * scale))
}

launch() {
    PROFANE_REPL_SOCKET="$dir/repl.sock" "$app/Contents/MacOS/profane" >/dev/null 2>&1 &
    pid=$!
    i=0
    until [ -S "$dir/repl.sock" ]; do
        i=$((i + 1)); [ $i -le 200 ] || { echo "REPL did not start" >&2; exit 1; }
        sleep 0.02
    done
}

stop() {
    kill $pid; wait $pid 2>/dev/null || true
    rm -f "$dir/repl.sock"
}

for run in 1 2 3; do
    launch
    sleep 1
    v=$(first_line_ink)
    stop
    awk -v v="$v" 'BEGIN { exit !(v > 0.05) }' || { echo "startup run $run: blank first line ($v)" >&2; exit 1; }
done

for run in 1 2 3; do
    launch
    "$client" --socket "$dir/repl.sock" \
        --eval '(begin (goto-char 0) (insert (make-string 60 #\x2588) "\n") #t)' >/dev/null
    sleep 1
    v=$(first_line_ink)
    stop
    awk -v v="$v" 'BEGIN { exit !(v > 0.6) }' || { echo "early edit run $run: not shown ($v)" >&2; exit 1; }
done
echo ok
