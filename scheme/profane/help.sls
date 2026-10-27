;;; (profane help) — describe-function (C-h f), describe-variable (C-h v), describe-mode (C-h m)
;;; and set-variable. Unstable API (plan §10).
;;;
;;; The descriptions go to a read-only *Help* buffer shown in another window, without selecting
;;; it (q leaves it). Functions are commands: the description lists the keys that run one in the
;;; current buffer. A variable's description shows its value here, whether that is buffer-local,
;;; and the default. set-variable reads a name, then a Scheme expression that is evaluated, as in
;;; Emacs; the value is set the way var-set! does (buffer-local for variables declared local).

(library (profane help)
  (export describe-command-text describe-variable-text describe-mode-text command-keys)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane keymap)
          (profane mode) (profane var) (profane minibuffer) (profane complete))

  (define-major-mode help-mode fundamental-mode "Help" "Major mode of the *Help* buffer.")

  (define help-name "*Help*")

  (define (join strings sep)
    (if (null? strings)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car strings) (cdr strings))))

  (define (first-line s)
    (let loop ([i 0])
      (cond [(= i (string-length s)) s]
            [(char=? (string-ref s i) #\newline) (substring s 0 i)]
            [else (loop (+ i 1))])))

  (define (show s) (format "~s" s))

  ;; ---- keys ----

  ;; Every (key-sequence . binding) reachable from MAP and its parents, prefix keymaps entered;
  ;; the first binding of a key sequence wins, so a child shadows its parent.
  (define (flatten-keymap map)
    (let ([seen (make-hashtable string-hash string=?)] [out '()])
      (let walk ([map map] [prefix '()])
        (let loop ([m map])
          (when m
            (for-each
             (lambda (b)
               (let* ([keys (append prefix (list (car b)))] [name (key-description keys)])
                 (cond [(keymap? (cdr b)) (walk (cdr b) keys)]
                       [(and (cdr b) (not (hashtable-contains? seen name)))
                        (hashtable-set! seen name #t)
                        (set! out (cons (cons name (cdr b)) out))])))
             (sort (lambda (a b) (string<? (car a) (car b))) (keymap-bindings m)))
            (loop (keymap-parent m)))))
      (reverse out)))

  ;; The key sequences that run command NAME in the current buffer.
  (define (command-keys name)
    (let ([seen (make-hashtable string-hash string=?)])
      (let loop ([maps (current-active-maps)] [out '()])
        (if (null? maps)
            (reverse out)
            (loop (cdr maps)
                  (fold-left (lambda (acc b)
                               (if (and (eq? (cdr b) name) (not (hashtable-contains? seen (car b))))
                                   (begin (hashtable-set! seen (car b) #t) (cons (car b) acc))
                                   acc))
                             out (flatten-keymap (car maps))))))))

  ;; ---- texts ----

  (define (describe-command-text name)
    (let ([doc (command-documentation name)] [keys (command-keys name)])
      (string-append
       (format "~a is an interactive command.\n\n" name)
       (if (null? keys)
           "It is not on any key.\n"
           (format "It is on ~a.\n" (join keys ", ")))
       (if (and doc (not (string=? doc ""))) (string-append "\n" doc "\n") "\n(not documented)\n"))))

  (define (describe-variable-text name)
    (let ([doc (variable-documentation name)])
      (string-append
       (format "~a is a variable.\n\n" name)
       (format "Value: ~a\n" (show (var-ref name)))
       (if (var-local? name)
           (format "This value is local to the current buffer.\nDefault: ~a\n" (show (var-default name)))
           "")
       (if (string=? doc "") "\n(not documented)\n" (string-append "\n" doc "\n")))))

  (define (describe-mode-text)
    (let* ([major (major-mode)]
           [lighter (mode-lighter major)]
           [doc (command-documentation major)]
           [minors (enabled-minor-modes)])
      (string-append
       (format "Major mode: ~a (~a)\n" (if (string? lighter) lighter major) major)
       (if (and doc (not (string=? doc ""))) (string-append "\n" doc "\n") "")
       (if (null? minors)
           ""
           (apply string-append "\nEnabled minor modes:\n"
                  (map (lambda (m)
                         (let ([l (mode-lighter m)] [d (or (command-documentation m) "")])
                           (format "  ~a~a~a\n" m (if (string? l) (format " (~a)" l) "")
                                   (if (string=? d "") "" (string-append " - " (first-line d))))))
                       minors)))
       (let ([bindings (flatten-keymap (mode-keymap major))])
         (if (null? bindings)
             ""
             (let ([width (fold-left max 0 (map (lambda (b) (string-length (car b))) bindings))])
               (apply string-append "\nKey bindings of this mode:\n"
                      (map (lambda (b)
                             (format "  ~a~a  ~a\n" (car b)
                                     (make-string (- width (string-length (car b))) #\space) (cdr b)))
                           bindings))))))))

  ;; ---- the buffer ----

  (define (show-help! text)
    (let ([b (get-buffer-create help-name)])
      (with-current-buffer b
        (unless (eq? (var-ref 'major-mode) 'help-mode)
          (set-major-mode! 'help-mode)
          (var-set! 'display-line-numbers #f)
          (buffer-disable-undo))
        (with-inhibit-read-only
         (lambda () (erase-buffer) (insert text)))
        (set-buffer-read-only! #t)
        (set-buffer-unmodified!)
        (goto-char 0))
      (display-buffer-in-other-window b)))

  (define-command (help-quit) "Leave the help buffer."
    (let ([other (other-buffer (current-buffer))]) (when other (switch-to-buffer other))))

  ;; ---- commands ----

  (define (variable-note v)
    (let ([n (string->symbol v)])
      (if (variable-defined? n) (first-line (variable-documentation n)) "")))

  (define (read-variable-name prompt k)
    (completing-read prompt (sort string<? (map symbol->string (variable-names))) k
                     'annotate variable-note 'require-match #t 'history 'variable))

  (define-command (describe-function) "Show the documentation of a command, and its keys."
    (let ([buffer (current-buffer)])
      (read-command "Describe function: "
                    (lambda (name)
                      (show-help! (with-current-buffer buffer
                                    (describe-command-text (string->symbol name))))))))

  (define-command (describe-variable) "Show the value and documentation of a variable."
    (let ([buffer (current-buffer)])
      (read-variable-name "Describe variable: "
                          (lambda (name)
                            (show-help! (with-current-buffer buffer
                                          (describe-variable-text (string->symbol name))))))))

  (define-command (describe-mode) "Show the major and minor modes of this buffer, and the keys of the major mode."
    (show-help! (describe-mode-text)))

  (define-command (set-variable) "Set a variable to the value of a Scheme expression."
    (let ([buffer (current-buffer)])
      (read-variable-name
       "Set variable: "
       (lambda (name)
         (let ([sym (string->symbol name)])
           (read-from-minibuffer
            (format "Set ~a to value: " name)
            (lambda (text)
              (guard (c [else (message "Cannot set ~a: ~a" name
                                       (if (message-condition? c) (condition-message c) "error"))])
                (let ([value (eval (read (open-string-input-port text)) (interaction-environment))])
                  (with-current-buffer buffer (var-set! sym value))
                  (message "~a set to ~a" name (show value)))))
            (with-current-buffer buffer (show (var-ref sym)))))))))

  (define bindings
    (begin
      (for-each (lambda (b) (define-key! (global-map) (car b) (cdr b)))
                '(("C-h f" . describe-function) ("C-h v" . describe-variable)
                  ("C-h m" . describe-mode)))
      (define-key! (mode-keymap 'help-mode) "q" 'help-quit)
      #t)))
