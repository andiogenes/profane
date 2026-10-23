;;; (profane command) — the command registry, prefix arguments and messages. Unstable API
;;; (plan §10).
;;;
;;; Commands live in a registry keyed by symbol and keys bind symbols, so redefining a command
;;; (define-command again, from the REPL) takes effect for every key bound to it. A command is
;;; a procedure of no arguments; it reads the prefix argument with (current-prefix-arg) or
;;; (prefix-numeric-value), as Emacs commands do with an interactive "p" spec. The command loop
;;; itself is (profane command-loop).

(library (profane command)
  (export define-command register-command! command-procedure command-documentation
          command-names command?
          current-prefix-arg prefix-numeric-value %set-prefix-arg!
          this-command last-command %set-this-command! %set-last-command!
          message current-message %set-message-sink!)
  (import (chezscheme) (profane buffer))

  (define-record-type cmd
    (fields proc doc)
    (nongenerative profane-command))

  (define registry (make-eq-hashtable))

  (define (register-command! name proc doc)
    (hashtable-set! registry name (make-cmd proc doc))
    name)

  ;; (define-command (name) [doc] body ...). Expands to a definition (of a fresh, hygienic
  ;; name) so it can appear among other definitions in a library body.
  (define-syntax define-command
    (lambda (x)
      (syntax-case x ()
        [(_ (name) doc body0 body ...)
         (string? (syntax->datum #'doc))
         #'(define registered (register-command! 'name (lambda () body0 body ...) doc))]
        [(_ (name) body ...)
         #'(define registered (register-command! 'name (lambda () body ...) ""))])))

  (define (command? name) (hashtable-contains? registry name))
  (define (command-procedure name) (let ([c (hashtable-ref registry name #f)]) (and c (cmd-proc c))))
  (define (command-documentation name)
    (let ([c (hashtable-ref registry name #f)]) (and c (cmd-doc c))))
  (define (command-names) (vector->list (hashtable-keys registry)))

  ;; ---- prefix argument (C-u, M-digits), set by the command loop for the running command ----
  ;; Raw values as in Emacs: #f, a list (4) / (16) for C-u's, an integer, or the symbol -.

  (define prefix-arg #f)
  (define (current-prefix-arg) prefix-arg)
  (define (%set-prefix-arg! v) (set! prefix-arg v))

  (define prefix-numeric-value
    (case-lambda
      [() (prefix-numeric-value prefix-arg)]
      [(raw) (cond [(not raw) 1]
                   [(pair? raw) (car raw)]
                   [(eq? raw '-) -1]
                   [else raw])]))

  (define this-command-value #f)
  (define last-command-value #f)
  (define (this-command) this-command-value)
  (define (last-command) last-command-value)
  (define (%set-this-command! v) (set! this-command-value v))
  (define (%set-last-command! v) (set! last-command-value v))

  ;; ---- messages ----
  ;; (message fmt arg ...) shows a line in the echo area (once windows have one) and appends it
  ;; to *Messages*. (message #f) clears the echo area.

  (define echo #f)
  (define (current-message) echo)
  (define sink (lambda (text) (void))) ; the echo area, installed by the display side
  (define (%set-message-sink! proc) (set! sink proc))

  (define (message fmt . args)
    (if (not fmt)
        (begin (set! echo #f) (sink #f) #f)
        (let ([text (apply format fmt args)])
          (set! echo text)
          (with-current-buffer (get-buffer-create "*Messages*")
            (let ([p (point)] [at-end? (= (point) (point-max))])
              (goto-char (point-max))
              (insert text "\n")
              (undo-boundary)
              (unless at-end? (goto-char p))))
          (sink text)
          text))))
