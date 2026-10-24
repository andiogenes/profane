;;; (profane complete) — commands that read input with completion: M-x, C-x b, C-x k and
;;; C-x t RET (after Emacs's execute-extended-command, switch-to-buffer, kill-buffer and
;;; tab-rename; completion is vertico-style, see (profane minibuffer)). Unstable API (plan §10).
;;; Consult-like sources (imenu, ripgrep, find, yank) are built on completing-read as they are
;;; needed.

(library (profane complete)
  (export read-command read-buffer-name)
  (import (chezscheme) (profane buffer) (profane window) (profane keymap) (profane command)
          (profane command-loop) (profane minibuffer) (profane tab-bar) (profane simple))

  (define (hidden? b) (char=? (string-ref (buffer-name b) 0) #\space))

  (define (visible-buffer-names)
    (map buffer-name (filter (lambda (b) (not (hidden? b))) (buffer-list))))

  ;; Marginalia for commands: the first line of the documentation.
  (define (command-note c)
    (let* ([doc (or (command-documentation (string->symbol c)) "")]
           [nl (let loop ([i 0])
                 (cond [(= i (string-length doc)) i] [(char=? (string-ref doc i) #\newline) i]
                       [else (loop (+ i 1))]))])
      (substring doc 0 nl)))

  (define (read-command prompt k)
    (completing-read prompt (sort string<? (map symbol->string (command-names))) k
                     'annotate command-note 'require-match #t 'history 'extended-command))

  ;; Buffers other than the current one come first, as in Emacs (the default is the other buffer).
  (define (read-buffer-name prompt k . opts)
    (let* ([names (visible-buffer-names)]
           [other (let ([o (other-buffer (current-buffer))]) (and o (buffer-name o)))])
      (apply completing-read prompt names k
             'default (or other "")
             'annotate (lambda (n) (let ([b (get-buffer n)])
                                     (if (and b (buffer-file-name b)) (buffer-file-name b) "")))
             opts)))

  (define-command (execute-extended-command)
    "Read a command name and run it."
    (let ([arg (current-prefix-arg)])
      (read-command "M-x "
                    (lambda (name)
                      (let ([c (string->symbol name)])
                        (%set-prefix-arg! arg)
                        (%set-this-command! c)
                        ((command-procedure c))
                        (%set-prefix-arg! #f))))))

  (define-command (switch-to-buffer)
    "Switch the selected window to a buffer chosen by name, creating it if it is new."
    (read-buffer-name "Switch to buffer: "
                      (lambda (name) (switch-to-buffer (get-buffer-create name)))))

  ;; consult-buffer: like C-x b, with the window showing the selected candidate as you move
  ;; (live preview) and restoring its buffer if you quit.
  (define-command (consult-buffer)
    "Switch buffer with a live preview of the selected candidate."
    (let* ([w (selected-window)] [orig (window-buffer w)])
      (read-buffer-name "Buffer: "
                        (lambda (name) (switch-to-buffer (get-buffer-create name)))
                        'preview (lambda (name)
                                   (let ([b (get-buffer name)] [cur (current-buffer)])
                                     (when b (set-window-buffer! w b))
                                     (set-buffer cur)))
                        'quit (lambda () (set-window-buffer! w orig)))))

  ;; consult-yank-from-kill-ring: pick an earlier kill to insert. Newlines show as a symbol
  ;; so every kill takes one candidate line.
  (define (one-line s)
    (let ([t (list->string (map (lambda (c) (if (char=? c #\newline) #\x21B5 c)) (string->list s)))])
      (if (> (string-length t) 200) (substring t 0 200) t)))

  (define-command (consult-yank-from-kill-ring)
    "Insert a kill chosen from the kill ring, with a preview of what it is."
    (let ([kills (map (lambda (k) (cons (one-line k) k)) (kill-ring))])
      (when (null? kills) (error 'consult-yank-from-kill-ring "kill ring is empty"))
      (completing-read "Yank from kill ring: " (map car kills)
                       (lambda (shown)
                         (set-mark! (point))
                         (insert (cdr (assoc shown kills))))
                       'require-match #t)))

  (define-command (kill-buffer)
    "Kill a buffer chosen by name (default: the current one)."
    (let ([cur (buffer-name (current-buffer))])
      (completing-read "Kill buffer: " (visible-buffer-names)
                       (lambda (name) (kill-buffer name))
                       'default cur 'require-match #t)))

  (define-command (tab-rename)
    "Give the current tab a name (empty: back to the automatic one)."
    (read-from-minibuffer "Tab name: " (lambda (name) (tab-rename name))))

  (define bindings
    (for-each (lambda (b) (define-key! (global-map) (car b) (cdr b)))
              '(("M-x" . execute-extended-command) ("C-x b" . switch-to-buffer)
                ("C-x k" . kill-buffer) ("C-x t RET" . tab-rename)))))
