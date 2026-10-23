;;; (profane var) — the variable registry. Unstable API (plan §10).
;;;
;;; Variables are symbols with a global (default) value and, optionally, per-buffer values, as
;;; in Emacs. Code refers to them by name, so redefining a variable or setting it from the REPL
;;; is seen everywhere. A variable declared `local` becomes buffer-local whenever it is set
;;; (Emacs make-variable-buffer-local); `permanent` locals survive a major-mode change.
;;; Watchers run after every change, e.g. to push a display setting to the C core.

(library (profane var)
  (export define-variable variable-defined? variable-documentation variable-names
          var-ref var-set! var-default var-set-default! var-local-set! var-kill-local!
          var-local? kill-all-local-variables add-var-watcher!)
  (import (chezscheme) (profane buffer))

  (define-record-type variable
    (fields (mutable default) (mutable doc) (mutable auto-local?) (mutable permanent?)
            (mutable watchers))
    (nongenerative profane-variable))

  (define registry (make-eq-hashtable)) ; symbol -> variable

  (define (lookup who name)
    (or (hashtable-ref registry name #f) (error who "undefined variable" name)))

  ;; Options: local (buffer-local when set), permanent (kept by kill-all-local-variables).
  ;; Redefining keeps the current value, like Emacs defvar, but updates doc and options.
  (define define-variable
    (case-lambda
      [(name default) (define-variable name default "" '())]
      [(name default doc) (define-variable name default doc '())]
      [(name default doc options)
       (let ([v (hashtable-ref registry name #f)])
         (if v
             (begin (variable-doc-set! v doc)
                    (variable-auto-local?-set! v (and (memq 'local options) #t))
                    (variable-permanent?-set! v (and (memq 'permanent options) #t)))
             (hashtable-set! registry name
                             (make-variable default doc (and (memq 'local options) #t)
                                            (and (memq 'permanent options) #t) '())))
         name)]))

  (define (variable-defined? name) (hashtable-contains? registry name))
  (define (variable-documentation name) (variable-doc (lookup 'variable-documentation name)))
  (define (variable-names) (vector->list (hashtable-keys registry)))

  (define (locals) (%buffer-locals (current-buffer)))

  (define (var-local? name) (hashtable-contains? (locals) name))

  ;; The value in the current buffer: its local value if it has one, else the default.
  (define (var-ref name)
    (let ([v (lookup 'var-ref name)])
      (hashtable-ref (locals) name (variable-default v))))

  (define (var-default name) (variable-default (lookup 'var-default name)))

  (define (notify v name value where)
    (for-each (lambda (w) (w name value where)) (variable-watchers v)))

  ;; Sets the local value if the variable is local here or auto-local, else the default.
  (define (var-set! name value)
    (let ([v (lookup 'var-set! name)])
      (if (or (variable-auto-local? v) (var-local? name))
          (begin (hashtable-set! (locals) name value) (notify v name value (current-buffer)))
          (begin (variable-default-set! v value) (notify v name value 'global)))
      value))

  (define (var-set-default! name value)
    (let ([v (lookup 'var-set-default! name)])
      (variable-default-set! v value)
      (notify v name value 'global)
      value))

  ;; Emacs setq-local: a local value in the current buffer.
  (define (var-local-set! name value)
    (let ([v (lookup 'var-local-set! name)])
      (hashtable-set! (locals) name value)
      (notify v name value (current-buffer))
      value))

  (define (var-kill-local! name)
    (let ([v (lookup 'var-kill-local! name)])
      (when (var-local? name)
        (hashtable-delete! (locals) name)
        (notify v name (variable-default v) (current-buffer)))))

  ;; Drops the current buffer's non-permanent locals (a major-mode change does this).
  (define (kill-all-local-variables)
    (vector-for-each
     (lambda (name)
       (let ([v (hashtable-ref registry name #f)])
         (unless (and v (variable-permanent? v)) (var-kill-local! name))))
     (hashtable-keys (locals))))

  ;; PROC is called as (proc name new-value where) with where 'global or the buffer.
  (define (add-var-watcher! name proc)
    (let ([v (lookup 'add-var-watcher! name)])
      (unless (memq proc (variable-watchers v))
        (variable-watchers-set! v (append (variable-watchers v) (list proc)))))))
