;;; (profane simple) — basic editing commands and the default global bindings, after Emacs's
;;; simple.el. Unstable API (plan §10). Commands take the prefix argument as a repeat count.

(library (profane simple)
  (export kill-ring kill-new current-kill)
  (import (chezscheme) (profane buffer) (profane keymap) (profane command)
          (profane command-loop) (profane var) (profane mode))

  (define (n) (prefix-numeric-value))

  (define (repeat k thunk) (do ([i 0 (+ i 1)]) ((>= i k)) (thunk)))

  ;; ---- insertion and deletion ----

  ;; ---- electric-pair-mode ----
  ;; Typing an opening bracket or quote inserts its partner and leaves point between them;
  ;; typing the partner when it is next just moves over it; with the region active the pair
  ;; goes around it; DEL between an empty pair deletes both. An opener is not paired before a
  ;; word character, a quote not next to one (so apostrophes and closing quotes stay single).
  ;; There is no syntax table yet, so a quote typed inside a string pairs when it follows a
  ;; space (M5).
  (define-minor-mode electric-pair-mode (global)
    "Insert the closing bracket or quote together with the opening one.")

  (defvar electric-pair-pairs '((#\( . #\)) (#\[ . #\]) (#\{ . #\}) (#\" . #\"))
    "Characters that are typed in pairs: (opener . closer).")

  (define (word-char? c) (and c (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_))))

  (define (electric-pair-insert c)
    (let* ([pairs (var-ref 'electric-pair-pairs)]
           [open (assv c pairs)]
           [closer? (find (lambda (p) (and (char=? (cdr p) c) (not (char=? (car p) c)))) pairs)]
           [next (char-after)] [prev (char-before)])
      (cond
        [(and closer? (eqv? next c)) (forward-char 1) #t]
        [(and open (char=? (car open) (cdr open)))        ; a quote
         (cond [(eqv? next c) (forward-char 1) #t]
               [(or (word-char? prev) (word-char? next)) #f]
               [else (insert (string c c)) (backward-char 1) #t])]
        [(and open (mark) (var-ref 'mark-active) (not (= (mark) (point))))
         (let ([lo (min (mark) (point))] [hi (max (mark) (point))] [back? (< (point) (mark))])
           (goto-char hi) (insert (string (cdr open)))
           (goto-char lo) (insert (string (car open)))
           (set-mark! (if back? (+ hi 1) (+ lo 1)))
           (goto-char (if back? (+ lo 1) (+ hi 1)))
           #t)]
        [(and open (not (word-char? next)))
         (insert (string (car open) (cdr open)))
         (backward-char 1)
         #t]
        [else #f])))

  (define (pair-around-point?)
    (let ([prev (char-before)] [next (char-after)])
      (and prev next
           (let ([p (assv prev (var-ref 'electric-pair-pairs))]) (and p (char=? (cdr p) next))))))

  (define-command (self-insert-command)
    "Insert the typed text, ARG times."
    (let ([text (last-input-text)])
      (unless (and (var-ref 'electric-pair-mode) (= (n) 1) (= (string-length text) 1)
                   (electric-pair-insert (string-ref text 0)))
        (repeat (n) (lambda () (insert text))))))

  (define-command (newline) "Insert a newline, ARG times." (repeat (n) (lambda () (insert "\n"))))

  (define-command (open-line)
    "Insert a newline after point, ARG times, leaving point before it."
    (let ([p (point)]) (repeat (n) (lambda () (insert "\n"))) (goto-char p)))

  (define-command (insert-tab) (repeat (n) (lambda () (insert "\t"))))
  (define-command (delete-char) (delete-char (n)))
  (define-command (delete-backward-char)
    "Delete the character before point; between an empty pair (electric-pair-mode), both."
    (if (and (var-ref 'electric-pair-mode) (= (n) 1) (pair-around-point?))
        (delete-region (- (point) 1) (+ (point) 1))
        (delete-char (- (n)))))

  ;; ---- motion ----

  (define-command (forward-char) (forward-char (n)))
  (define-command (backward-char) (backward-char (n)))
  (define-command (move-beginning-of-line) (forward-line (- (n) 1)))
  (define-command (move-end-of-line)
    (unless (= (n) 1) (forward-line (- (n) 1)))
    (goto-char (line-end-position)))

  (define-command (beginning-of-buffer) (set-mark! (point)) (goto-char (point-min)))
  (define-command (end-of-buffer) (set-mark! (point)) (goto-char (point-max)))

  ;; One key for both ends of the buffer: the end, or the beginning with a negative argument
  ;; (C-- C-M-v), as the owner's edge-of-buffer does.
  (define-command (edge-of-buffer)
    "Go to the end of the buffer, or with a negative argument (C--) to its beginning."
    (set-mark! (point))
    (goto-char (if (eq? (current-prefix-arg) '-) (point-min) (point-max))))

  ;; Line motion keeps the column the run of line moves started from.
  (define goal-column 0)

  (define (move-lines k)
    (unless (memq (last-command) '(next-line previous-line))
      (set! goal-column (- (point) (line-beginning-position))))
    (let ([short (forward-line k)])
      (goto-char (min (+ (line-beginning-position) goal-column) (line-end-position)))
      (unless (zero? short)
        (error (if (> k 0) 'next-line 'previous-line)
               (if (> k 0) "end of buffer" "beginning of buffer")))))

  (define-command (next-line) (move-lines (n)))
  (define-command (previous-line) (move-lines (- (n))))

  ;; ---- mark and region ----

  (define-command (set-mark-command) "Set the mark at point and activate the region."
    (set-mark! (point))
    (var-set! 'mark-active #t)
    (message "Mark set"))

  (define-command (exchange-point-and-mark)
    (let ([m (mark)])
      (unless m (error 'exchange-point-and-mark "no mark set in this buffer"))
      (set-mark! (point))
      (var-set! 'mark-active #t)
      (goto-char m)))

  (define (region)
    (let ([m (mark)])
      (unless m (error 'region "the mark is not set now, so there is no region"))
      (values (min m (point)) (max m (point)))))

  ;; ---- kill ring (within profane; the macOS pasteboard joins in M3, (profane macos)) ----

  (define kill-ring-max-registered
    (define-variable 'kill-ring-max 120 "Maximum length of the kill ring."))
  (define kills '())
  (define yank-index 0)
  (define (kill-ring) kills)

  (define (kill-new text)
    (set! kills (cons text kills))
    (when (> (length kills) (var-ref 'kill-ring-max))
      (set! kills (list-head kills (var-ref 'kill-ring-max))))
    (set! yank-index 0))

  ;; Consecutive kills append to the last kill, as in Emacs.
  (define (kill-append text before?)
    (if (and (memq (last-command) '(kill-region kill-line)) (pair? kills))
        (set-car! kills (if before? (string-append text (car kills)) (string-append (car kills) text)))
        (kill-new text)))

  (define (current-kill)
    (when (null? kills) (error 'yank "kill ring is empty"))
    (list-ref kills (mod yank-index (length kills))))

  (define-command (kill-region)
    (let-values ([(lo hi) (region)])
      (kill-append (buffer-substring lo hi) (< (point) (mark)))
      (delete-region lo hi)))

  (define-command (kill-ring-save)
    (let-values ([(lo hi) (region)])
      (kill-new (buffer-substring lo hi))
      (var-set! 'mark-active #f)
      (message "Saved text")))

  (define-command (kill-line)
    "Kill to the end of the line, or the newline itself at the end of a line."
    (let* ([p (point)]
           [end (if (and (eol?) (not (eob?))) (+ p 1) (line-end-position))])
      (when (= p end) (error 'kill-line "end of buffer"))
      (kill-append (buffer-substring p end) #f)
      (delete-region p end)))

  (define-command (yank)
    (set-mark! (point))
    (insert (current-kill)))

  (define-command (keyboard-quit)
    "Deactivate the region."
    (var-set! 'mark-active #f)
    (message "Quit"))

  ;; ---- undo ----

  (define-command (undo) (repeat (n) undo))
  (define-command (undo-redo) (repeat (n) redo))

  ;; ---- default global bindings (Emacs defaults; the owner's own map is ported in M2) ----

  (define default-bindings
    (for-each (lambda (b) (define-key! (global-map) (car b) (cdr b)))
              '(("C-f" . forward-char) ("<right>" . forward-char)
                ("C-b" . backward-char) ("<left>" . backward-char)
                ("C-n" . next-line) ("<down>" . next-line)
                ("C-p" . previous-line) ("<up>" . previous-line)
                ("C-a" . move-beginning-of-line) ("<home>" . move-beginning-of-line)
                ("C-e" . move-end-of-line) ("<end>" . move-end-of-line)
                ("M-<" . beginning-of-buffer) ("M->" . end-of-buffer)
                ("DEL" . delete-backward-char) ("C-d" . delete-char) ("<deletechar>" . delete-char)
                ("RET" . newline) ("C-o" . open-line) ("TAB" . insert-tab)
                ("C-SPC" . set-mark-command) ("C-x C-x" . exchange-point-and-mark)
                ("C-w" . kill-region) ("M-w" . kill-ring-save) ("C-k" . kill-line) ("C-y" . yank)
                ("C-/" . undo) ("C-_" . undo) ("C-x u" . undo)
                ("C-?" . undo-redo) ("C-M-_" . undo-redo)
                ("C-g" . keyboard-quit)))))
