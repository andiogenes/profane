(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane keymap) (profane command)
        (profane command-loop) (profane simple) (profane async))

(invoke-library '(profane simple)) ; registers self-insert-command (see boot.ss)

(test-begin "async")

(define (pump-until pred)
  (let loop ([n 0]) (unless (or (pred) (> n 200)) (async-poll! 10) (loop (+ n 1)))))
(define (bv . bytes) (apply bytevector bytes))

;; ---- events reach the handler of their token ----
(define got '())
(define t (async-token-new (lambda (kind data) (set! got (cons (list kind data) got)))))
(%async-post t 7 (bv 1 2 3) 3)
(%async-post t 8 (make-bytevector 0) 0)
(test-eqv "two events wait" 2 (%async-pending))
(test-eqv "dispatch handles both" 2 (async-dispatch!))
(test-equal "in order, with kind and data" (list (list 8 (bv)) (list 7 (bv 1 2 3))) got)
(test-eqv "none left" 0 (async-dispatch!))

;; a released token drops its events; a failing handler is contained
(async-token-release! t)
(%async-post t 1 (bv 9) 1)
(test-eqv "event for a released token is consumed" 1 (async-dispatch!))
(test-equal "and not delivered" 2 (length got))
(define bad (async-token-new (lambda (kind data) (error 'bad "boom"))))
(%async-post bad 0 (make-bytevector 0) 0)
(test-eqv "a raising handler does not stop the drain" 1 (async-dispatch!))
(test-assert "it is reported" (string? (current-message)))

;; a flood is handled in batches
(define flood 0)
(define ft (async-token-new (lambda (kind data) (set! flood (+ flood 1)))))
(do ([i 0 (+ i 1)]) ((= i 150)) (%async-post ft 0 (make-bytevector 0) 0))
(test-eqv "one drain stops at the limit" async-dispatch-limit (async-dispatch!))
(test-eqv "the rest is still queued" (- 150 async-dispatch-limit) (%async-pending))
(async-dispatch!) (async-dispatch!)
(test-eqv "all handled" 150 flood)

;; ---- posting from another thread ----
(define from-thread #f)
(define tt (async-token-new (lambda (kind data) (set! from-thread (utf8->string data)))))
(%async-post-after tt 0 (string->utf8 "later") 5 30)
(test-eqv "nothing yet" #f from-thread)
(pump-until (lambda () from-thread))
(test-equal "a timer posts from its own thread" "later" from-thread)

(define fired 0)
(define cancelled (async-after 20 (lambda () (set! fired (+ fired 1)))))
(async-cancel! cancelled)
(async-after 40 (lambda () (set! fired (+ fired 10))))
(pump-until (lambda () (> fired 0)))
(test-eqv "a cancelled timer does not fire" 10 fired)

;; ---- promises ----
(define p (make-promise))
(define order '())
(promise-then p (lambda (x) (set! order (cons 'a order))))
(promise-then p (lambda (x) (set! order (cons 'b order))))
(test-assert "pending" (not (promise-ready? p)))
(test-assert "value of a pending promise is an error" (guard (c [else #t]) (promise-value p) #f))
(test-assert "resolve" (promise-resolve! p 42))
(test-eqv "value" 42 (promise-value p))
(test-equal "callbacks in registration order" '(b a) order)
(test-assert "settles once" (not (promise-resolve! p 43)))
(test-eqv "unchanged" 42 (promise-value p))
(promise-then p (lambda (x) (set! order (cons 'c order))))
(test-eqv "then on a settled promise runs at once" 'c (car order))
(define r (make-promise))
(promise-reject! r 'nope)
(test-eq "rejected raises its reason" 'nope (guard (c [else c]) (promise-value r)))

;; await outside a command pumps events
(test-eqv "await a timer" #t (await (async-sleep 20)))

;; ---- await inside a command parks it ----
(set-buffer (generate-new-buffer "awaiting"))
(define pending-p (make-promise))
(define after-await #f)
(register-command! 'test-await
  (lambda ()
    (insert "a")
    (set! after-await (await pending-p))
    (insert "b")) "")
(define-key! (global-map) "<f9>" 'test-await)
(for-each handle-key (kbd "<f9>"))
(test-assert "the command waits" (command-busy?))
(test-equal "it ran up to the await" "a" (buffer-string))
(resume-busy!)
(test-assert "a resume does not finish it" (command-busy?))
(handle-text "x")
(test-equal "typeahead waits" "a" (buffer-string))
(promise-resolve! pending-p 'done)
(resume-busy!)
(test-assert "resolved: it finishes" (not (command-busy?)))
(test-eq "with the value" 'done after-await)
(test-equal "and the typeahead ran after it" "abx" (buffer-string))

;; C-g aborts the wait; settling later changes nothing
(define never (make-promise))
(register-command! 'test-await-never (lambda () (await never) (insert "!")) "")
(define-key! (global-map) "<f10>" 'test-await-never)
(for-each handle-key (kbd "<f10>"))
(test-assert "waiting" (command-busy?))
(handle-key "C-g")
(test-assert "C-g aborts" (not (command-busy?)))
(promise-resolve! never #t)
(resume-busy!)
(test-equal "the aborted command did not go on" "abx" (buffer-string))

(test-end "async")
(test-exit)
