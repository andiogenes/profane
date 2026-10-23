#!/bin/sh
# Starts a headless profane, talks to its socket REPL with profane-client, then quits it
# through the REPL.
set -eu
app="$1"
client="$2"

dir=$(mktemp -d)
sock="$dir/repl.sock"
PROFANE_REPL_SOCKET="$sock" "$app/Contents/MacOS/profane" --headless &
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
expect '(+ 1 2)' '3'
expect '(define greeting "hi") (string-append greeting " there")' '"hi there"'
expect '(car 1)' 'Exception in car: 1 is not a pair'
expect '(threaded?)' '#t'
expect '(with-current-buffer (get-buffer-create "r") (insert "abc") (goto-char 1) (insert "X") (buffer-string))' '"aXbc"'
printf '(* 6 7)\n' | "$client" --socket "$sock" | grep -qx 42

"$client" --socket "$sock" --eval '(exit)' >/dev/null
i=0
while kill -0 $pid 2>/dev/null; do
    i=$((i + 1))
    [ $i -le 100 ] || { echo "profane did not exit" >&2; exit 1; }
    sleep 0.1
done
wait $pid
[ ! -e "$sock" ] || { echo "socket not removed on exit" >&2; exit 1; }
