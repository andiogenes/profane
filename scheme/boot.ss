;;; Loaded by pf_scheme_init into the interaction environment, after the C side has defined
;;; `pf-scheme-dir`. Everything C calls is a top-level definition reached through
;;; `pf-ffi-call` by symbol, so any entry point can be redefined live from the REPL.

(library-directories (list (cons pf-scheme-dir pf-scheme-dir)))
(library-extensions '((".sls" . ".so")))

(import (profane repl) (profane buffer) (profane window) (profane var) (profane hook)
        (profane keymap) (profane face) (profane command) (profane mode) (profane command-loop)
        (profane simple))

;;; Chez invokes a library only when one of its variables is first used; libraries whose body
;;; registers commands, modes and bindings must be invoked explicitly.
(for-each invoke-library '((profane simple) (profane window)))

;;; FFI trampoline. An exception escaping into C would terminate the process, so every call
;;; from C lands here. Returns a UTF-8 bytevector for a string result, #t for any other
;;; result, #f if the call raised.

(define (pf-ffi-call name . args)
  (guard (c [else (pf-report-error name c) #f])
    (let ([v (apply (top-level-value name) args)])
      (if (string? v) (string->utf8 v) #t))))

(define (pf-report-error name c)
  (let ([err (current-error-port)])
    (format err "profane: error in ~a: " name)
    (if (condition? c)
        (display-condition c err)
        (write c err))
    (newline err)
    (flush-output-port err)))

;;; GC is deferred to idle time (plan §1): collection requests only set a flag, and the shell
;;; calls `pf-idle` from a run-loop observer once the frame is done.

(define pf-collect-pending #f)

(collect-request-handler (lambda () (set! pf-collect-pending #t)))

(define (pf-idle)
  (when pf-collect-pending
    (set! pf-collect-pending #f)
    (collect)))

;;; Shell integration. Foreign entries registered by the shell may be absent (C tests).

(define (pf-quit)
  (if (foreign-entry? "pf_app_quit")
      ((foreign-procedure "pf_app_quit" () void))
      (error 'pf-quit "no application shell")))

(when (foreign-entry? "pf_app_quit")
  (exit-handler (lambda args (pf-quit))))

(define (pf-hello-text)
  (format "Hello, profane — ~a" (scheme-version)))

;;; Input from the shell: a key description ("C-f", "<left>", "RET") or committed text (typed
;;; characters, input-method results).
(define (pf-key key) (handle-key key))
(define (pf-insert-text text) (handle-text text))

;;; Key-to-pixel latency of the main view (see pf_renderer_latency): a printable report.
(define (latency-report)
  (let* ([report (foreign-procedure "pf_app_latency_report" (u8* size_t) size_t)]
         [bv (make-bytevector 1024)]
         [n (report bv 1024)])
    (display (utf8->string (bytevector-truncate! bv (min n 1024))))
    (newline)))

(define (latency-reset) ((foreign-procedure "pf_app_latency_reset" () void)))

;;; Called by the shell once its window exists: show *scratch*.
(define (pf-startup)
  (let ([scratch (get-buffer-create "*scratch*")])
    (with-current-buffer scratch
      (when (zero? (buffer-size))
        (insert ";; " (pf-hello-text) "\n"
                ";; This buffer is for notes you don't want to save. Evaluate Scheme with\n"
                ";; profane-client, e.g.: profane-client --eval '(insert \"hi\")'\n\n")
        (set-buffer-unmodified!)))
    (set-buffer scratch)
    (let ([w (selected-window)])
      (when w (set-window-buffer! w scratch)))
    ;; The owner's Emacs setup (plan §2): all on in the default preset.
    (for-each (lambda (m) (set-minor-mode! m #t))
              '(display-line-numbers-mode global-hl-line-mode show-paren-mode))))

;;; Socket REPL sessions, keyed by connection id (an integer chosen by the shell).

(define pf-repl-sessions (make-eqv-hashtable))

(define (pf-repl-open id)
  (hashtable-set! pf-repl-sessions id (make-repl-session)))

(define (pf-repl-input id text)
  (repl-feed! (hashtable-ref pf-repl-sessions id #f) text))

(define (pf-repl-close id)
  (let ([session (hashtable-ref pf-repl-sessions id #f)])
    (hashtable-delete! pf-repl-sessions id)
    (repl-finish! session)))

;;; Hardened-runtime check (M0): generating and running machine code needs the allow-jit
;;; entitlement (Chez maps code segments with MAP_JIT). Exercised on the main thread and on a
;;; second thread, since JIT write protection on Apple Silicon is per thread.

(define (pf-self-test)
  (define (jit-check)
    (let loop ([i 0] [sum 0])
      (if (= i 200)
          sum
          (loop (+ i 1) (+ sum ((compile `(lambda (x) (* x ,i))) 2))))))
  (define expected (* 2 (/ (* 199 200) 2)))
  (let ([main (jit-check)]
        [worker (let ([m (make-mutex)] [cv (make-condition)] [result #f])
                  (fork-thread (lambda ()
                                 (let ([r (jit-check)])
                                   (with-mutex m (set! result r) (condition-signal cv)))))
                  (with-mutex m
                    (let wait () (unless result (condition-wait cv m) (wait))))
                  result)])
    (unless (and (= main expected) (= worker expected))
      (error 'pf-self-test "unexpected JIT result" main worker))
    (format "ok: ~a, threaded ~a, JIT on main and worker threads" (scheme-version) (threaded?))))
