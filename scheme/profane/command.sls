;;; (profane command) — commands, the global keymap and the command loop. Unstable API (plan §10).
;;;
;;; Commands live in a registry keyed by symbol and keys bind symbols, so redefining a command
;;; (define-command again, from the REPL) takes effect for every key bound to it. Keys are
;;; Emacs-style descriptions produced by the shell: "a", "C-f", "M-<", "C-M-_", "<left>", "RET",
;;; "DEL", "TAB", "SPC", "s-x". M1 has one global keymap and no prefix keys; M2 brings keymap
;;; registries, prefix maps and modes.

(library (profane command)
  (export define-command command-procedure command-names
          global-set-key global-unset-key key-binding
          handle-key handle-text
          this-command last-command last-input-text
          self-insert-amalgamation)
  (import (chezscheme) (profane buffer) (profane window))

  ;; ---- registry ----

  (define commands (make-eq-hashtable)) ; symbol -> procedure

  ;; Expands to a definition (of a fresh, hygienic name) so it can appear among definitions.
  (define-syntax define-command
    (syntax-rules ()
      [(_ (name) body ...)
       (define registered
         (begin (hashtable-set! commands 'name (lambda () body ...)) 'name))]))

  (define (command-procedure name) (hashtable-ref commands name #f))
  (define (command-names) (vector->list (hashtable-keys commands)))

  (define global-map (make-hashtable string-hash string=?)) ; key -> command symbol

  (define (global-set-key key command)
    (unless (symbol? command) (error 'global-set-key "keys bind command names (symbols)" command))
    (hashtable-set! global-map key command))

  (define (global-unset-key key) (hashtable-delete! global-map key))
  (define (key-binding key) (hashtable-ref global-map key #f))

  ;; ---- command loop ----

  (define this-command-value #f)
  (define last-command-value #f)
  (define (this-command) this-command-value)
  (define (last-command) last-command-value)

  (define input-text "")
  (define (last-input-text) input-text)

  ;; Typed characters are undone in groups of this many, as in Emacs.
  (define self-insert-amalgamation 20)
  (define insert-run 0)

  (define (beep)
    (when (foreign-entry? "pf_app_beep")
      ((foreign-procedure "pf_app_beep" () void))))

  (define (report who c)
    (let ([err (current-error-port)])
      (format err "profane: ~a: " who)
      (if (condition? c) (display-condition c err) (write c err))
      (newline err)
      (flush-output-port err)))

  ;; Runs command NAME in the selected window's buffer, with undo boundaries between commands
  ;; (but not inside a run of up to self-insert-amalgamation typed characters).
  (define (run-command name)
    (let ([proc (command-procedure name)]
          [w (selected-window)])
      (when (and w (window-buffer w) (buffer-live? (window-buffer w)))
        (set-buffer (window-buffer w)))
      (if (and (eq? name 'self-insert-command) (eq? last-command-value 'self-insert-command)
               (< insert-run self-insert-amalgamation))
          (set! insert-run (+ insert-run 1))
          (begin (undo-boundary) (set! insert-run 1)))
      (set! this-command-value name)
      (guard (c [else (beep) (report name c)])
        (if proc (proc) (error name "no such command")))
      (set! last-command-value name)))

  (define (handle-key key)
    (let ([name (key-binding key)])
      (if name
          (run-command name)
          (begin (beep) (set! last-command-value #f)))))

  (define (handle-text text)
    (set! input-text text)
    (run-command 'self-insert-command))

  ;; ---- basic commands ----

  (define-command (self-insert-command) (insert (last-input-text)))
  (define-command (newline) (insert "\n"))
  (define-command (insert-tab) (insert "\t"))
  (define-command (forward-char) (forward-char 1))
  (define-command (backward-char) (backward-char 1))
  (define-command (delete-char) (delete-char 1))
  (define-command (delete-backward-char) (delete-char -1))
  (define-command (move-beginning-of-line) (goto-char (line-beginning-position)))
  (define-command (move-end-of-line) (goto-char (line-end-position)))
  (define-command (beginning-of-buffer) (goto-char (point-min)))
  (define-command (end-of-buffer) (goto-char (point-max)))
  (define-command (undo) (undo))
  (define-command (undo-redo) (redo))
  (define-command (keyboard-quit) (beep))

  ;; Line motion keeps the column the run of line moves started from.
  (define goal-column 0)

  (define (move-lines n)
    (unless (memq last-command-value '(next-line previous-line))
      (set! goal-column (- (point) (line-beginning-position))))
    (let ([short (forward-line n)])
      (goto-char (min (+ (line-beginning-position) goal-column) (line-end-position)))
      (unless (zero? short)
        (error (if (> n 0) 'next-line 'previous-line)
               (if (> n 0) "end of buffer" "beginning of buffer")))))

  (define-command (next-line) (move-lines 1))
  (define-command (previous-line) (move-lines -1))

  (define default-bindings
   (for-each (lambda (b) (global-set-key (car b) (cdr b)))
            '(("C-f" . forward-char) ("<right>" . forward-char)
              ("C-b" . backward-char) ("<left>" . backward-char)
              ("C-n" . next-line) ("<down>" . next-line)
              ("C-p" . previous-line) ("<up>" . previous-line)
              ("C-a" . move-beginning-of-line) ("<home>" . move-beginning-of-line)
              ("C-e" . move-end-of-line) ("<end>" . move-end-of-line)
              ("M-<" . beginning-of-buffer) ("M->" . end-of-buffer)
              ("DEL" . delete-backward-char) ("C-d" . delete-char) ("<deletechar>" . delete-char)
              ("RET" . newline) ("TAB" . insert-tab)
              ("C-/" . undo) ("C-_" . undo) ("C-?" . undo-redo) ("C-M-_" . undo-redo)
              ("C-g" . keyboard-quit)))))
