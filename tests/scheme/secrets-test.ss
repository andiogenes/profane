(import (chezscheme) (srfi :64) (profane secrets))

(test-begin "secrets")

(define (fails? thunk) (guard (c [else #t]) (thunk) #f))

;; Without the shell there is no keychain.
(test-assert "get needs a backend" (fails? (lambda () (secret-get "svc" "acct"))))
(test-assert "set needs a backend" (fails? (lambda () (secret-set! "svc" "acct" "x"))))

;; A fake keychain: what its users' tests install.
(define store '())
(set-secrets-backend!
 (lambda (s a) (let ([e (assoc (cons s a) store)]) (and e (cdr e))))
 (lambda (s a v) (set! store (cons (cons (cons s a) v) (remp (lambda (e) (equal? (car e) (cons s a))) store))))
 (lambda (s a) (let ([had (assoc (cons s a) store)])
                 (set! store (remp (lambda (e) (equal? (car e) (cons s a))) store))
                 (and had #t))))

(test-eqv "missing is #f" #f (secret-get "svc" "acct"))
(secret-set! "svc" "acct" "one")
(test-equal "stored" "one" (secret-get "svc" "acct"))
(secret-set! "svc" "acct" "two")
(test-equal "replaced" "two" (secret-get "svc" "acct"))
(test-eqv "by service and account" #f (secret-get "svc" "other"))
(test-eqv "delete says it deleted" #t (secret-delete! "svc" "acct"))
(test-eqv "and that there was nothing" #f (secret-delete! "svc" "acct"))
(test-eqv "gone" #f (secret-get "svc" "acct"))

(set-secrets-backend! #f)
(test-assert "removing the fake backend leaves none (no shell here)" (fails? (lambda () (secret-get "a" "b"))))

(test-end "secrets")
(test-exit)
