#!/bin/sh
# (profane net) against local servers (nc for plain TCP, the system openssl for TLS): connecting, data
# both ways, a large transfer, ALPN, a refused port, a certificate that does not verify, closing.
# No outside network is used.
set -eu
app="$1"
client="$2"

dir=$(mktemp -d /tmp/pf.XXXX)
sock="$dir/s"
pids=""
cleanup() {
    for p in $pids; do kill "$p" 2>/dev/null || true; done
    pkill -f "nc -l 127.0.0.1" 2>/dev/null || true
    rm -rf "$dir"
}
trap cleanup EXIT

PROFANE_REPL_SOCKET="$sock" "$app/Contents/MacOS/profane" --headless >/dev/null 2>&1 &
pids="$!"
i=0
until [ -S "$sock" ]; do
    i=$((i + 1))
    [ $i -le 100 ] || { echo "REPL socket did not appear" >&2; exit 1; }
    sleep 0.1
done

ev() { "$client" --socket "$sock" --eval "$1"; }
expect() {
    out=$(ev "$1")
    [ "$out" = "$2" ] || { printf 'eval %s: got [%s], expected [%s]\n' "$1" "$out" "$2" >&2; exit 1; }
}
# polls an expression until it prints the expected value
wait_for() {
    i=0
    while :; do
        out=$(ev "$1")
        [ "$out" = "$2" ] && return 0
        i=$((i + 1))
        [ $i -le 100 ] || { printf 'waiting for %s: got [%s], expected [%s]\n' "$1" "$out" "$2" >&2; exit 1; }
        sleep 0.1
    done
}
free_port() {
    p=$((20000 + ($$ + $1 * 37) % 20000))
    while nc -z 127.0.0.1 "$p" 2>/dev/null; do p=$((p + 1)); done
    echo "$p"
}

ev '(begin (define log (quote ())) (define (note! x) (set! log (cons x log))) 1)' >/dev/null

# ---- plain TCP ----
port=$(free_port 1)
( printf 'hello from server\n'; sleep 3 ) | nc -l 127.0.0.1 "$port" > "$dir/received" &
pids="$pids $!"
sleep 0.3
ev "(begin (define text \"\") (define c1 (open-network-stream \"127.0.0.1\" $port (list (cons (quote filter) (lambda (c bv) (set! text (string-append text (utf8->string bv))))) (cons (quote sentinel) (lambda (c e) (note! e)))))) 1)" >/dev/null
wait_for '(connection-status c1)' 'open'
expect '(connection-open? c1)' '#t'
expect '(connection-protocol c1)' '""'
wait_for 'text' '"hello from server\n"'
expect '(connection-send c1 "ping\n")' '#t'
sleep 0.5
expect '(connection-close c1)' '#t'
wait_for '(connection-status c1)' 'closed'
expect '(connection-send c1 "late")' '#f'
expect '(reverse log)' '("open\n" "closed\n")'
grep -q '^ping$' "$dir/received" || { echo "the server did not receive ping" >&2; exit 1; }

# ---- a large transfer, with receiving paused while the editor catches up ----
port=$(free_port 2)
( head -c 3000000 /dev/zero; sleep 3 ) | nc -l 127.0.0.1 "$port" >/dev/null &
pids="$pids $!"
sleep 0.3
ev "(begin (define total 0) (define c2 (open-network-stream \"127.0.0.1\" $port (list (cons (quote filter) (lambda (c bv) (set! total (+ total (bytevector-length bv)))))))) 1)" >/dev/null
wait_for 'total' '3000000'
ev '(connection-close c2)' >/dev/null

# ---- refused ----
port=$(free_port 3)
ev "(begin (define c3 (open-network-stream \"127.0.0.1\" $port)) 1)" >/dev/null
wait_for '(connection-status c3)' 'failed'
msg=$(ev '(guard (e [else (condition-message e)]) (await (connection-ready c3)))')
case "$msg" in *[Rr]efused*|*"Connection"*|*"POSIX"*) ;; *) echo "refused: unexpected message [$msg]" >&2; exit 1;; esac

# ---- bad arguments ----
expect '(guard (e [else (quote refused)]) (open-network-stream "" 80))' 'refused'
expect '(guard (e [else (quote refused)]) (open-network-stream "localhost" 0))' 'refused'

# ---- TLS against a self-signed server ----
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/k.pem" -out "$dir/c.pem" -days 1 -subj /CN=localhost >/dev/null 2>&1
tport=$(free_port 4)
/usr/bin/openssl s_server -accept "$tport" -cert "$dir/c.pem" -key "$dir/k.pem" -www -quiet -alpn h2,http/1.1 >/dev/null 2>&1 &
pids="$pids $!"
sleep 0.5

# verified: the certificate is not trusted, so the connection fails
ev "(begin (define c4 (open-network-stream \"localhost\" $tport (list (cons (quote tls) #t) (cons (quote sentinel) (lambda (c e) (note! e)))))) 1)" >/dev/null
wait_for '(connection-status c4)' 'failed'
expect '(connection-send c4 "x")' '#f'
msg=$(ev '(guard (e [else (condition-message e)]) (await (connection-ready c4)))')
[ -n "$msg" ] && [ "$msg" != '""' ] || { echo "verification failure had no message" >&2; exit 1; }

# insecure: any certificate is accepted; an HTTP request over it
ev "(begin (define page \"\") (define c5 (open-network-stream \"localhost\" $tport (list (cons (quote tls) #t) (cons (quote insecure) #t) (cons (quote alpn) (list \"h2\" \"http/1.1\")) (cons (quote filter) (lambda (c bv) (set! page (string-append page (utf8->string bv)))))))) 1)" >/dev/null
wait_for '(connection-status c5)' 'open'
expect '(connection-protocol c5)' '"h2"'
expect '(connection-send c5 "GET / HTTP/1.0\r\n\r\n")' '#t'
wait_for '(and (> (string-length page) 15) (substring page 0 15))' '"HTTP/1.0 200 ok"'
wait_for '(connection-status c5)' 'closed'

# and no ALPN means none negotiated
ev "(begin (define c6 (open-network-stream \"localhost\" $tport (list (cons (quote tls) #t) (cons (quote insecure) #t)))) 1)" >/dev/null
wait_for '(connection-status c6)' 'open'
expect '(connection-protocol c6)' '""'
ev '(connection-close c6)' >/dev/null

ev '(exit)' >/dev/null 2>&1 || true
