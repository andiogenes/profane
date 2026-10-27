;;; Loaded by pf_scheme_init into the interaction environment, after the C side has defined
;;; `pf-scheme-dir`. Everything C calls is a top-level definition reached through
;;; `pf-ffi-call` by symbol, so any entry point can be redefined live from the REPL.

(library-directories (list (cons pf-scheme-dir pf-scheme-dir)))
(library-extensions '((".sls" . ".so")))

(import (profane repl) (profane buffer) (profane window) (profane var) (profane hook)
        (profane keymap) (profane face) (profane command) (profane mode) (profane command-loop)
        (profane simple) (profane display) (profane theme) (profane themes) (profane tab-bar)
        (profane transpose-frame) (profane ace-window) (profane minibuffer) (profane complete) (profane canvas) (profane eval) (profane transient) (profane avy) (profane mouse) (profane files) (profane async) (profane process) (profane macos) (profane search) (profane secrets) (profane dired) (profane sidebar) (profane buffer-menu) (profane vterm) (profane net) (profane git) (profane section) (profane git status) (profane git commands) (profane git views) (profane ediff) (profane git marks) (profane help) (profane isearch))

;;; Chez invokes a library only when one of its variables is first used; libraries whose body
;;; registers commands, modes and bindings must be invoked explicitly.
(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane transpose-frame) (profane ace-window)
                           (profane minibuffer) (profane complete) (profane canvas) (profane eval) (profane transient) (profane avy) (profane mouse) (profane files) (profane search) (profane dired) (profane sidebar) (profane buffer-menu) (profane vterm) (profane git) (profane section) (profane git status) (profane git commands) (profane git views) (profane ediff) (profane git marks) (profane help) (profane isearch)))

;;; Defaults until the shell reports the macOS appearance: the light theme, the minimal style.
(load-theme 'modus-operandi)
(ui-style 'minimal)

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

;;; The next time slice of a command that outlived its first (see (profane command-loop)); the
;;; shell calls this from its event loop until the command is done or aborted with C-g.
(define (pf-resume) (resume-busy!))

;;; Events posted from other threads are waiting (see (profane async)); the shell calls this on
;;; the main thread after a wake.
(define (pf-async) (async-dispatch!))

;;; Key-to-pixel latency of the main view (see pf_renderer_latency): a printable report.
(define (latency-report)
  (let* ([report (foreign-procedure "pf_app_latency_report" (u8* size_t) size_t)]
         [bv (make-bytevector 1024)]
         [n (report bv 1024)])
    (display (utf8->string (bytevector-truncate! bv (min n 1024))))
    (newline)))

(define (latency-reset) ((foreign-procedure "pf_app_latency_reset" () void)))

;;; The shell reports the macOS appearance ("light" or "dark") and accent color ("#rrggbb");
;;; themes follow them. A trackpad pinch arrives as its magnification.
(define (pf-appearance-changed which) (appearance-changed! (string->symbol which)))
(define (pf-accent-changed color) (system-accent-changed! color))
(define (pf-pinch magnification) (pinch-text-scale (string->number magnification)))

;;; Mouse events from the shell, as one string: "down|drag|up X Y CLICKS" (points, top-left
;;; origin) and "scroll X Y DX DY PRECISE". See (profane mouse).
(define (pf-mouse text)
  (unless (command-busy?)
   (let ([parts (let loop ([cs (string->list text)] [cur '()] [out '()])
                 (cond [(null? cs) (reverse (if (null? cur) out (cons (list->string (reverse cur)) out)))]
                       [(char=? (car cs) #\space) (loop (cdr cs) '() (if (null? cur) out (cons (list->string (reverse cur)) out)))]
                       [else (loop (cdr cs) (cons (car cs) cur) out)]))])
    (let ([kind (string->symbol (car parts))] [nums (map string->number (cdr parts))])
      (if (eq? kind 'scroll)
          (handle-scroll (car nums) (cadr nums) (caddr nums) (cadddr nums) (not (zero? (list-ref nums 4))))
          (handle-mouse kind (car nums) (cadr nums) (caddr nums)))))))

;;; Called by the shell before each redisplay: layout, mode lines, echo area, tab bar.
(define (pf-redisplay) (redisplay-prepare!))

;;; Startup scripts: the shipped init.ss (the owner's port of their Emacs setup), then the user's
;;; own, ~/Library/Application Support/profane/init.ss (PROFANE_INIT overrides it). An error in
;;; either is reported in the echo area and *Messages*; startup goes on.
(define (pf-user-init-path)
  (or (getenv "PROFANE_INIT")
      (let ([home (getenv "HOME")])
        (and home (string-append home "/Library/Application Support/profane/init.ss")))))

(define (pf-load-init-files)
  (for-each
   (lambda (path)
     (when (and path (file-exists? path))
       (guard (c [else (message "init ~a: ~a" path
                                (if (condition? c)
                                    (call-with-string-output-port (lambda (p) (display-condition c p)))
                                    c))])
         (load path))))
   (list (string-append pf-scheme-dir "/init.ss") (pf-user-init-path)))
  (void))

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
              '(display-line-numbers-mode global-hl-line-mode show-paren-mode electric-pair-mode
                diff-hl-mode))
    (pf-load-init-files)))

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
