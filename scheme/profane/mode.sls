;;; (profane mode) — major and minor modes. Unstable API (plan §10).
;;;
;;;   (define-major-mode name parent "Lighter" [doc] body ...)
;;;   (define-minor-mode name (option ...) [doc] body ...)   ; options: global, (lighter "str")
;;;
;;; A major mode has a parent (or #f), a keymap inheriting from the parent's, a hook NAME-hook,
;;; and a command NAME that switches the current buffer to it: buffer-local variables are
;;; killed, bodies run from the root mode down, then hooks in the same order. A minor mode is a
;;; variable NAME (buffer-local unless global) plus a command NAME toggling it; its body runs
;;; after every change, its hook NAME-hook after that. Everything is registered by symbol, so
;;; redefining a mode from the REPL updates it in place.

(library (profane mode)
  (export define-major-mode define-minor-mode register-major-mode! register-minor-mode!
          major-mode set-major-mode! major-mode-parent major-mode-names derived-mode?
          mode-keymap mode-lighter minor-mode-names minor-mode-enabled? enabled-minor-modes
          set-minor-mode! current-active-maps)
  (import (chezscheme) (profane buffer) (profane var) (profane hook) (profane keymap)
          (profane command))

  (define-record-type major
    (fields name parent lighter keymap body)
    (nongenerative profane-major-mode))

  (define-record-type minor
    (fields name lighter global? keymap body)
    (nongenerative profane-minor-mode))

  (define majors (make-eq-hashtable))
  (define minors (make-eq-hashtable))
  (define minor-order '()) ; most recently defined first: earlier in keymap precedence

  (define (hook-name name) (string->symbol (string-append (symbol->string name) "-hook")))

  ;; ---- major modes ----

  ;; (Registrations are wrapped in definitions: a library body allows no expression before its
  ;; last definition.)
  (define major-mode-registered
    (begin (define-variable 'major-mode 'fundamental-mode "The current buffer's major mode."
                            '(local))
           (define-hook 'after-change-major-mode-hook)))

  (define (register-major-mode! name parent lighter doc body)
    (let* ([old (hashtable-ref majors name #f)]
           [parent-map (and parent (mode-keymap parent))]
           [map (if old (major-keymap old) (make-keymap parent-map name))])
      (set-keymap-parent! map parent-map)
      (hashtable-set! majors name (make-major name parent lighter map body))
      (define-hook (hook-name name))
      (register-command! name (lambda () (set-major-mode! name)) doc)
      name))

  (define-syntax define-major-mode
    (lambda (x)
      (syntax-case x ()
        [(_ name parent lighter doc body ...)
         (string? (syntax->datum #'doc))
         #'(define registered
             (register-major-mode! 'name 'parent lighter doc (lambda () body ... (void))))]
        [(_ name parent lighter body ...)
         #'(define registered
             (register-major-mode! 'name 'parent lighter "" (lambda () body ... (void))))])))

  (define (lookup-major who name)
    (or (hashtable-ref majors name #f) (error who "no such major mode" name)))

  (define (major-mode) (var-ref 'major-mode))
  (define (major-mode-parent name) (major-parent (lookup-major 'major-mode-parent name)))
  (define (major-mode-names) (vector->list (hashtable-keys majors)))
  (define (mode-keymap name) (major-keymap (lookup-major 'mode-keymap name)))
  (define (mode-lighter name)
    (cond [(hashtable-ref majors name #f) => major-lighter]
          [(hashtable-ref minors name #f) => minor-lighter]
          [else #f]))

  ;; Root first.
  (define (mode-chain name)
    (let loop ([name name] [acc '()])
      (if name
          (loop (major-parent (lookup-major 'set-major-mode! name)) (cons name acc))
          acc)))

  (define (derived-mode? name ancestor) (and (memq ancestor (mode-chain name)) #t))

  (define (set-major-mode! name)
    (let ([chain (mode-chain name)])
      (kill-all-local-variables)
      (var-set! 'major-mode name)
      (for-each (lambda (m) ((major-body (lookup-major 'set-major-mode! m)))) chain)
      (for-each (lambda (m) (run-hooks (hook-name m))) chain)
      (run-hooks 'after-change-major-mode-hook)
      name))

  (define fundamental-registered
    (register-major-mode! 'fundamental-mode #f "Fundamental" "The basic major mode." void))

  ;; ---- minor modes ----

  (define (register-minor-mode! name options doc body)
    (let* ([global? (and (memq 'global options) #t)]
           [lighter (let ([l (assq 'lighter (filter pair? options))]) (and l (cadr l)))]
           [old (hashtable-ref minors name #f)]
           [map (if old (minor-keymap old) (make-keymap #f name))])
      (define-variable name #f doc (if global? '() '(local)))
      (define-hook (hook-name name))
      (hashtable-set! minors name (make-minor name lighter global? map body))
      (unless old (set! minor-order (cons name minor-order)))
      ;; Interactively: toggle, or on for a positive prefix argument, off otherwise.
      (register-command! name
                         (lambda ()
                           (let ([arg (current-prefix-arg)])
                             (set-minor-mode! name (if arg
                                                       (> (prefix-numeric-value arg) 0)
                                                       (not (minor-mode-enabled? name))))))
                         doc)
      name))

  (define-syntax define-minor-mode
    (lambda (x)
      (syntax-case x ()
        [(_ name (option ...) doc body ...)
         (string? (syntax->datum #'doc))
         #'(define registered
             (register-minor-mode! 'name '(option ...) doc (lambda () body ... (void))))]
        [(_ name (option ...) body ...)
         #'(define registered
             (register-minor-mode! 'name '(option ...) "" (lambda () body ... (void))))])))

  (define (lookup-minor who name)
    (or (hashtable-ref minors name #f) (error who "no such minor mode" name)))

  (define (minor-mode-names) (reverse minor-order))
  (define (minor-mode-enabled? name) (and (var-ref name) #t))
  (define (enabled-minor-modes) (filter minor-mode-enabled? (reverse minor-order)))

  ;; Sets the mode (globally or in the current buffer), then runs its body and hook.
  (define (set-minor-mode! name on?)
    (let ([m (lookup-minor 'set-minor-mode! name)])
      (var-set! name (and on? #t))
      ((minor-body m))
      (run-hooks (hook-name name))
      (and on? #t)))

  ;; ---- keymap precedence ----

  ;; Enabled minor modes' keymaps (most recently defined first), the major mode's, the global.
  (define (current-active-maps)
    (append
     (map (lambda (name) (minor-keymap (hashtable-ref minors name #f)))
          (filter minor-mode-enabled? minor-order))
     (list (mode-keymap (major-mode)) (global-map)))))
