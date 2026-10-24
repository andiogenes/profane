#!/bin/sh
# Key-to-pixel latency: types N characters (posted to profane's process, SPACING ms apart) into
# the front window and prints the renderer's latency report. Fails if the p95 from key event to
# committed frame exceeds LIMIT ms (the M1 <8 ms target). Opt-in like the other screen tests.
set -eu
[ "${PROFANE_SCREEN_TESTS:-}" = 1 ] || { echo "skipped: set PROFANE_SCREEN_TESTS=1"; exit 77; }
app="$1"
client="$2"
keys="$3"
n="${LATENCY_KEYS:-200}"
spacing="${LATENCY_SPACING_MS:-30}"
limit="${LATENCY_LIMIT_MS:-8}"

dir=$(mktemp -d /tmp/pf-latency.XXXX)
PROFANE_REPL_SOCKET="$dir/repl.sock" "$app/Contents/MacOS/profane" >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$dir"' EXIT
until [ -S "$dir/repl.sock" ]; do sleep 0.02; done
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true"
sleep 0.5
eval_() { "$client" --socket "$dir/repl.sock" --eval "$1"; }
# Optional pre-fill: LATENCY_PREFILL_LINES lines of code-like text, typing then happens in the
# middle of the buffer. LATENCY_WINDOWS=N shows the buffer in N windows (split side by side and
# below), all of which must redraw on each key.
prefill="${LATENCY_PREFILL_LINES:-0}"
windows="${LATENCY_WINDOWS:-1}"
eval_ "(let ([line \"(define (f x) (+ x 1)) ; some text to shape\\n\"])
         (goto-char (point-max))
         (do ([i 0 (+ i 1)]) ((= i $prefill)) (insert line))
         (goto-char (quotient (point-max) 2))
         (do ([i 1 (+ i 1)]) ((= i $windows))
           (split-window (car (last-pair (window-list))) (if (odd? i) 'right 'below)))
         (latency-reset))" >/dev/null

set --
i=0
while [ $i -lt "$n" ]; do
    set -- "$@" "text:x" "sleep:$spacing"
    i=$((i + 1))
done
"$keys" $pid "$@"
sleep 0.5

report=$(eval_ '(latency-report)')
echo "$report"
p95=$(echo "$report" | awk '$1 == "commit" { print $3 }')
awk -v p="$p95" -v l="$limit" 'BEGIN { exit !(p < l) }' ||
    { echo "commit p95 ${p95} ms exceeds ${limit} ms" >&2; exit 1; }
