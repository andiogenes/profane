;;; (profane hook) — named hooks. Unstable API (plan §10).
;;;
;;; A hook is a symbol naming an ordered list of functions. Functions may be given as symbols,
;;; looked up in the interaction environment each time the hook runs, so redefining one from
;;; the REPL takes effect (keys and hooks bind names, plan §1), or as procedures. An error in
;;; one function is reported and does not stop the others.

(library (profane hook)
  (export define-hook defhook hook-defined? hook-functions add-hook! remove-hook! run-hooks)
  (import (chezscheme))

  (define registry (make-eq-hashtable)) ; symbol -> list of functions

  (define define-hook
    (case-lambda
      [(name) (define-hook name "")]
      [(name doc)
       (unless (hashtable-contains? registry name) (hashtable-set! registry name '()))
       name]))

  ;; (defhook name) — define-hook as a definition form (see defvar).
  (define-syntax defhook
    (syntax-rules ()
      [(_ name) (define registered (define-hook 'name))]))

  (define (hook-defined? name) (hashtable-contains? registry name))

  (define (hook-functions name) (hashtable-ref registry name '()))

  (define add-hook!
    (case-lambda
      [(name f) (add-hook! name f #f)]
      [(name f append?)
       (unless (or (symbol? f) (procedure? f))
         (error 'add-hook! "not a function or function name" f))
       (let ([fs (remove f (hook-functions name))])
         (hashtable-set! registry name (if append? (append fs (list f)) (cons f fs))))]))

  (define (remove-hook! name f)
    (hashtable-set! registry name (remove f (hook-functions name))))

  (define (resolve f)
    (if (symbol? f) (top-level-value f (interaction-environment)) f))

  (define (run-hooks name . args)
    (for-each
     (lambda (f)
       (guard (c [else
                  (let ([err (current-error-port)])
                    (format err "profane: error in ~a (~s): " name f)
                    (if (condition? c) (display-condition c err) (write c err))
                    (newline err))])
         (apply (resolve f) args)))
     (hook-functions name))))
