;;; (profane async) — results from other threads, delivered to the main thread. Unstable API
;;; (plan §10).
;;;
;;; C threads post events (a token, a kind, bytes) to a queue (core/async/pf_async.h); the shell
;;; wakes Scheme (pf-async) and each event goes to the handler registered for its token. On top
;;; of that: promises that a command can `await` without blocking the editor (the command parks;
;;; C-g still aborts it), timers (async-after, async-sleep). Handlers run between commands, one
;;; event at a time, and are not sliced (like hooks): keep them short.

(library (profane async)
  (export make-promise promise? promise-ready? promise-value promise-resolve! promise-reject!
          promise-then await
          async-token-new async-token-release! async-token-live?
          async-dispatch! async-poll! async-after async-cancel! async-sleep async-dispatch-limit)
  (import (chezscheme) (profane native) (profane buffer) (profane command) (profane command-loop))

  ;; ---- tokens and dispatch ----

  (define handlers (make-eqv-hashtable))
  (define next-token 1)

  ;; A new token whose events go to (HANDLER kind data), data a bytevector, on the main thread.
  ;; Whoever posts events for it (from C) is given the integer.
  (define (async-token-new handler)
    (let ([t next-token])
      (set! next-token (+ t 1))
      (hashtable-set! handlers t handler)
      t))

  ;; Events still to come for a released token are dropped.
  (define (async-token-release! token) (hashtable-delete! handlers token))
  (define (async-token-live? token) (hashtable-contains? handlers token))

  ;; Events handled per drain: past it the rest waits for the next turn of the event loop, so a
  ;; flood of output cannot starve input or redisplay.
  (define async-dispatch-limit 64)

  (define (report who c)
    (message "~a: ~a" who
             (if (condition? c)
                 (call-with-string-output-port (lambda (p) (display-condition c p)))
                 c)))

  ;; Handles waiting events (up to async-dispatch-limit); returns how many. The shell calls it
  ;; from pf-async when woken.
  (define (async-dispatch!)
    (%async-wake-ack)
    (let ([token (make-bytevector 8)] [kind (make-bytevector 4)])
      (let loop ([n 0])
        (cond
          [(>= n async-dispatch-limit)
           (when (> (%async-pending) 0) (%async-rewake))
           n]
          [else
           (let ([len (%async-pop token kind)])
             (cond
               [(< len 0) n]
               [else
                (let ([data (make-bytevector len)])
                  (%async-data data len)
                  (let ([handler (hashtable-ref handlers (bytevector-u64-native-ref token 0) #f)])
                    (when handler
                      (guard (c [else (report 'async c)])
                        (handler (bytevector-s32-native-ref kind 0) data)))))
                (loop (+ n 1))]))]))))

  ;; Waits up to MS milliseconds for events, then handles them: how headless runs and tests
  ;; (which have no shell to wake them) pump. Returns the number handled.
  (define (async-poll! ms)
    (%async-wait ms)
    (async-dispatch!))

  ;; ---- promises ----

  (define-record-type promise
    (fields (mutable state) (mutable result) (mutable callbacks))
    (protocol (lambda (new) (lambda () (new 'pending #f '())))))

  (define (promise-ready? p) (not (eq? (promise-state p) 'pending)))

  ;; The value; raises the condition or object the promise was rejected with; an error if the
  ;; promise is still pending.
  (define (promise-value p)
    (case (promise-state p)
      [(resolved) (promise-result p)]
      [(rejected) (raise (promise-result p))]
      [else (error 'promise-value "promise is still pending" p)]))

  (define (settle! p state value)
    (and (not (promise-ready? p))
         (let ([callbacks (reverse (promise-callbacks p))])
           (promise-state-set! p state)
           (promise-result-set! p value)
           (promise-callbacks-set! p '())
           (for-each (lambda (cb) (guard (c [else (report 'promise c)]) (cb p))) callbacks)
           (command-wake!)
           #t)))

  ;; Settle once; later calls change nothing and return #f.
  (define (promise-resolve! p value) (settle! p 'resolved value))
  (define (promise-reject! p reason) (settle! p 'rejected reason))

  ;; Calls (PROC p) when P settles (at once, if it has), in the order registered.
  (define (promise-then p proc)
    (if (promise-ready? p)
        (proc p)
        (promise-callbacks-set! p (cons proc (promise-callbacks p)))))

  ;; The value of P, waiting for it. In a command the command parks: the editor stays alive and
  ;; C-g aborts the wait. Anywhere else (the REPL, a test) it pumps events until P settles, which
  ;; blocks the main thread; never await what only the main thread could settle.
  (define (await p)
    (unless (command-wait! (lambda () (promise-ready? p)))
      (let loop ()
        (unless (promise-ready? p)
          (async-poll! 50)
          (loop))))
    (promise-value p))

  ;; ---- timers ----

  ;; Calls (THUNK) on the main thread after MS milliseconds. Returns a token for async-cancel!.
  (define (async-after ms thunk)
    (letrec ([token (async-token-new
                     (lambda (kind data)
                       (async-token-release! token)
                       (thunk)))])
      (when (< (%async-post-after token 0 (make-bytevector 0) 0 ms) 0)
        (async-token-release! token)
        (error 'async-after "cannot start a timer"))
      token))

  (define (async-cancel! token) (async-token-release! token))

  ;; A promise resolved with #t after MS milliseconds.
  (define (async-sleep ms)
    (let ([p (make-promise)])
      (async-after ms (lambda () (promise-resolve! p #t)))
      p)))
