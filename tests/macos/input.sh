#!/bin/sh
# Real key events into the app (posted to its process only), checked through the REPL.
# Opt-in like screen.sh: needs Accessibility permission, so skipped (77) unless
# PROFANE_SCREEN_TESTS=1.
set -eu
[ "${PROFANE_SCREEN_TESTS:-}" = 1 ] || { echo "skipped: set PROFANE_SCREEN_TESTS=1"; exit 77; }
app="$1"
client="$2"
keys="$3"

dir=$(mktemp -d /tmp/pf-input.XXXX)
PROFANE_REPL_SOCKET="$dir/repl.sock" "$app/Contents/MacOS/profane" >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$dir"' EXIT
i=0
until [ -S "$dir/repl.sock" ]; do
    i=$((i + 1)); [ $i -le 200 ] || { echo "REPL did not start" >&2; exit 1; }
    sleep 0.02
done
sleep 0.3
eval_() { "$client" --socket "$dir/repl.sock" --eval "$1"; }
eval_ '(begin (delete-region (point-min) (point-max)) #t)' >/dev/null

# Posted key events and REPL requests reach the main thread by different routes, so poll.
expect() {
    n=0
    while got=$(eval_ "$1"); [ "$got" != "$2" ]; do
        n=$((n + 1))
        [ $n -lt 20 ] || { printf '%s: got [%s], expected [%s]\n' "$3" "$got" "$2" >&2; exit 1; }
        sleep 0.05
    done
}

"$keys" $pid "text:hello world"
expect '(buffer-string)' '"hello world"' "typed text"
"$keys" $pid C-a M-'>' C-b C-b DEL
expect '(list (buffer-string) (point))' '("hello wold" 8)' "chords and DEL"
"$keys" $pid '<home>' RET '<up>' "text:é—😀"
expect '(buffer-string)' '"é—😀\nhello wold"' "named keys and non-ASCII text"
"$keys" $pid C-/
expect '(buffer-string)' '"\nhello wold"' "undo removes the typed run"
"$keys" $pid C-?
expect '(buffer-string)' '"é—😀\nhello wold"' "undo-redo"
# Regression: "M-<" was sent as "M-S-<" (Shift added to the character "<"), leaving it unbound.
"$keys" $pid M-'>' M-'<'
expect '(point)' '0' "M-< moves to the beginning"

# Regression: an unpaired surrogate in typed text made -UTF8String return NULL and crashed.
"$keys" $pid raw16:D83D
expect '(char->integer (char-after (point-min)))' '65533' "lone surrogate becomes U+FFFD"
# Regression: a plain key after a prefix went through the input method as text and was
# inserted ("C-x u" typed "u"). Under a Russian layout "C-x o" must still be other-window.
before=$(eval_ '(buffer-string)')
"$keys" $pid C-x 2
expect '(length (window-list))' '2' "C-x 2 splits the window"
"$keys" $pid C-x o
expect '(eq? (selected-window) (cadr (window-list)))' '#t' "C-x o selects the other window"
expect '(buffer-string)' "$before" "and nothing was inserted"
"$keys" $pid C-x 1
expect '(length (window-list))' '1' "C-x 1"
echo ok
