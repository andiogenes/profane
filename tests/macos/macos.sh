#!/bin/sh
# (profane macos) against the real shell: a private pasteboard (never the owner's clipboard),
# the kill ring on it, AppleScript, window bounds. Nothing here opens an app or a window.
set -eu
app="$1"
client="$2"

dir=$(mktemp -d /tmp/pf.XXXX)
sock="$dir/s"
PROFANE_PASTEBOARD="profane-test-$$" PROFANE_REPL_SOCKET="$sock" "$app/Contents/MacOS/profane" --headless &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$dir"' EXIT

i=0
until [ -S "$sock" ]; do
    i=$((i + 1))
    [ $i -le 100 ] || { echo "REPL socket did not appear" >&2; exit 1; }
    sleep 0.1
done

expect() {
    out=$("$client" --socket "$sock" --eval "$1")
    [ "$out" = "$2" ] || { printf 'eval %s: got [%s], expected [%s]\n' "$1" "$out" "$2" >&2; exit 1; }
}

# pasteboard, including text that is not ASCII
"$client" --socket "$sock" --eval "(pasteboard-set! \"héllo ✓\")" >/dev/null
expect '(pasteboard-string)' '"héllo ✓"'
expect '(let ([a (pasteboard-change-count)]) (pasteboard-set! "x") (> (pasteboard-change-count) a))' '#t'

# the kill ring writes to it, and takes in a copy made behind its back
expect '(begin (kill-new "killed") (pasteboard-string))' '"killed"'
expect '(begin (pasteboard-set! "outside") (current-kill))' '"outside"'
expect '(kill-ring)' '("outside" "killed")'

# AppleScript, in process
expect '(run-applescript "return \"x\" & 2")' '"x2"'
expect '(guard (c [else (condition-message c)]) (run-applescript "error \"boom\""))' '"boom"'
expect '(guard (c [else #t]) (run-applescript "this is not applescript") #f)' '#t'

# other apps' windows: none for an app that does not exist, a list of 4-number lists otherwise
expect '(app-window-bounds "No Such App pf")' '()'
expect '(let ([w (app-window-bounds "Finder")]) (andmap (lambda (b) (and (= 4 (length b)) (andmap integer? b))) w))' '#t'

# URLs that are not URLs are refused (nothing is opened)
expect '(open-url "not a url")' '#f'
expect '(open-url "")' '#f'

"$client" --socket "$sock" --eval '(exit)' >/dev/null
i=0
while kill -0 $pid 2>/dev/null; do
    i=$((i + 1))
    [ $i -le 100 ] || { echo "profane did not exit" >&2; exit 1; }
    sleep 0.1
done
