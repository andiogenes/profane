;;; (profane buffer-menu) — a list of the buffers, after Emacs's buffer-menu. Unstable API (plan §10).
;;;
;;; buffer-menu shows it in the selected window, list-buffers (C-x C-b, as in Emacs) in another one
;;; without selecting it; the owner's init.ss binds C-x C-b to buffer-menu and C-x 4 C-x C-b to list-buffers:
;;;
;;;   .*%  name          size  mode   file
;;;
;;; (. the buffer you came from, % read-only, * modified). Hidden buffers (names starting with a
;;; space) are left out. Keys: RET f show the buffer here, o in the other window, d k flag it to be
;;; killed, s flag it to be saved, u unflag, x do what is flagged, g refresh, n p move, q leave. Killing
;;; buffers with unsaved changes asks first.

(library (profane buffer-menu)
  (export buffer-menu-buffers)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane keymap)
          (profane mode) (profane var) (profane face) (profane display) (profane minibuffer))

  (defvar buffer-menu-origin #f "The buffer that was current when the list was made." '(local))
  (defvar buffer-menu-entries (vector) "The buffers listed, one per line after the header." '(local))

  (define flag-face
    (begin (define-face 'buffer-menu-flag '((inherit . dired-flagged)) "The D or S of a flagged buffer.") #t))

  (define-major-mode buffer-menu-mode fundamental-mode "Buffer Menu" "Major mode of the buffer list.")

  (define list-name "*Buffer List*")

  (define (hidden? b) (char=? (string-ref (buffer-name b) 0) #\space))
  (define (buffer-menu-buffers) (filter (lambda (b) (not (hidden? b))) (buffer-list)))

  (define (pad-right s n) (if (>= (string-length s) n) s (string-append s (make-string (- n (string-length s)) #\space))))
  (define (pad-left s n) (if (>= (string-length s) n) s (string-append (make-string (- n (string-length s)) #\space) s)))

  (define (mode-name b)
    (with-current-buffer b (let ([l (mode-lighter (var-ref 'major-mode))]) (if (string? l) l "Fundamental"))))

  (define (entry-line b mark width origin)
    (string-append (string mark) (if (eq? b origin) "." " ")
                   (if (with-current-buffer b (buffer-read-only?)) "%" " ")
                   (if (with-current-buffer b (buffer-modified?)) "*" " ")
                   " " (pad-right (buffer-name b) width) "  "
                   (pad-left (number->string (with-current-buffer b (buffer-size))) 8) "  "
                   (pad-right (mode-name b) 12) " "
                   (or (buffer-file-name b) "")))

  (define header "MRM Buffer")

  (define (index) (- (line-number-at-pos) 2))
  (define (entry-at i) (let ([v (var-ref 'buffer-menu-entries)]) (and (>= i 0) (< i (vector-length v)) (vector-ref v i))))
  (define (this-buffer!) (or (entry-at (index)) (error 'buffer-menu "no buffer on this line")))

  (define (line-position i)
    (let ([p (point)]) (goto-char 0) (forward-line (+ i 1)) (let ([pos (point)]) (goto-char p) pos)))

  (define (mark-of i) (char-after (line-position i)))

  (define (draw! marks)
    (let* ([origin (var-ref 'buffer-menu-origin)]
           [bufs (buffer-menu-buffers)]
           [width (fold-left max 6 (map (lambda (b) (string-length (buffer-name b))) bufs))]
           [keep (let ([b (entry-at (index))]) b)])
      (var-set! 'buffer-menu-entries (list->vector bufs))
      (with-inhibit-read-only
       (lambda ()
         (erase-buffer)
         (let ([from (point)])
           (insert (string-append header (make-string (max 0 (- (+ width 28) (string-length header))) #\space) "Size  Mode         File"))
           (put-text-property from (point) 'face 'shadow)
           (insert "\n"))
         (for-each (lambda (b)
                     (let* ([m (let ([e (assq b marks)]) (if e (cdr e) #\space))] [from (point)])
                       (insert (entry-line b m width origin))
                       (unless (char=? m #\space) (put-text-property from (+ from 1) 'face 'buffer-menu-flag))
                       (when (with-current-buffer b (buffer-modified?))
                         (put-text-property (+ from 3) (+ from 4) 'face 'warning))
                       (insert "\n")))
                   bufs)))
      (set-buffer-unmodified!)
      (let ([i (and keep (let loop ([i 0] [bs bufs]) (cond [(null? bs) #f] [(eq? (car bs) keep) i] [else (loop (+ i 1) (cdr bs))])))])
        (goto-char (line-position (or i 0))))))

  (define (current-marks)
    (let ([v (var-ref 'buffer-menu-entries)])
      (let loop ([i 0] [out '()])
        (cond [(= i (vector-length v)) out]
              [(char=? (mark-of i) #\space) (loop (+ i 1) out)]
              [else (loop (+ i 1) (cons (cons (vector-ref v i) (mark-of i)) out))]))))

  ;; The list buffer, made fresh for ORIGIN (a revert keeps the flags).
  (define (make-list-buffer origin)
    (let ([b (get-buffer-create list-name)])
      (with-current-buffer b
        (unless (eq? (var-ref 'major-mode) 'buffer-menu-mode)
          (set-major-mode! 'buffer-menu-mode)
          (var-set! 'display-line-numbers #f)
          (buffer-disable-undo)
          (set-buffer-read-only! #t))
        (var-set! 'buffer-menu-origin origin)
        (draw! '()))
      b))

  (define-command (buffer-menu)
    "Show the list of buffers in the selected window."
    (switch-to-buffer (make-list-buffer (current-buffer))))

  (define-command (list-buffers)
    "Show the list of buffers in another window, without selecting it."
    (display-buffer-in-other-window (make-list-buffer (current-buffer))))

  ;; ---- in the list ----

  (define (move! n)
    (let ([last (- (vector-length (var-ref 'buffer-menu-entries)) 1)])
      (goto-char (line-position (max 0 (min last (+ (index) n)))))))

  (define-command (buffer-menu-next-line) "Move to the next buffer." (move! (prefix-numeric-value)))
  (define-command (buffer-menu-previous-line) "Move to the previous buffer." (move! (- (prefix-numeric-value))))

  (define-command (buffer-menu-this-window) "Show the buffer at point in this window."
    (switch-to-buffer (this-buffer!)))

  (define-command (buffer-menu-other-window) "Show the buffer at point in another window."
    (display-buffer-in-other-window (this-buffer!) #t))

  (define (flag! ch)
    (let ([i (index)])
      (this-buffer!)
      (let ([pos (line-position i)])
        (with-inhibit-read-only
         (lambda ()
           (goto-char pos)
           (delete-char 1)
           (insert (string ch))
           (put-text-property pos (+ pos 1) 'face (if (char=? ch #\space) 'default 'buffer-menu-flag))))
        (set-buffer-unmodified!)
        (goto-char (line-position (min (+ i 1) (- (vector-length (var-ref 'buffer-menu-entries)) 1)))))))

  (define-command (buffer-menu-delete) "Flag the buffer at point to be killed." (flag! #\D))
  (define-command (buffer-menu-save) "Flag the buffer at point to be saved." (flag! #\S))
  (define-command (buffer-menu-unmark) "Remove the flag of the buffer at point." (flag! #\space))

  (define-command (buffer-menu-revert) "Read the list of buffers again."
    (let ([marks (filter (lambda (e) (buffer-live? (car e))) (current-marks))])
      (draw! marks)))

  (define (run-flagged! list-buffer marks)
    (let ([saved 0] [killed 0])
      (for-each (lambda (e)
                  (when (and (char=? (cdr e) #\S) (buffer-live? (car e)) (buffer-file-name (car e)))
                    (with-current-buffer (car e) (save-buffer))
                    (set! saved (+ saved 1))))
                marks)
      (for-each (lambda (e)
                  (when (and (char=? (cdr e) #\D) (buffer-live? (car e)) (not (eq? (car e) list-buffer)))
                    (kill-buffer (car e))
                    (set! killed (+ killed 1))))
                marks)
      (with-current-buffer list-buffer (draw! '()))
      (message "Saved ~a, killed ~a buffer~a" saved killed (if (= killed 1) "" "s"))))

  (define-command (buffer-menu-execute) "Save and kill the flagged buffers."
    (let* ([lb (current-buffer)] [marks (current-marks)]
           [dirty (filter (lambda (e) (and (char=? (cdr e) #\D) (buffer-live? (car e))
                                           (with-current-buffer (car e) (buffer-modified?))
                                           (not (and (assq (car e) marks) (eqv? (cdr (assq (car e) marks)) #\S)))))
                          marks)])
      (cond
        [(null? marks) (message "(No buffers flagged)")]
        [(null? dirty) (run-flagged! lb marks)]
        [else
         (read-from-minibuffer
          (format "~a modified buffer~a will lose changes; kill anyway? (yes or no) " (length dirty) (if (= 1 (length dirty)) "" "s"))
          (lambda (answer)
            (if (member answer '("yes" "y"))
                (run-flagged! lb marks)
                (run-flagged! lb (filter (lambda (e) (not (memq e dirty))) marks)))))])))

  (define-command (buffer-menu-quit) "Leave the buffer list."
    (let ([other (other-buffer (current-buffer))]) (when other (switch-to-buffer other))))

  (define bindings
    (begin
      (define-key! (global-map) "C-x C-b" 'list-buffers) ; Emacs's default; init.ss has the owner's
      (for-each (lambda (b) (define-key! (mode-keymap 'buffer-menu-mode) (car b) (cdr b)))
                '(("RET" . buffer-menu-this-window) ("f" . buffer-menu-this-window) ("o" . buffer-menu-other-window)
                  ("n" . buffer-menu-next-line) ("C-n" . buffer-menu-next-line) ("<down>" . buffer-menu-next-line)
                  ("p" . buffer-menu-previous-line) ("C-p" . buffer-menu-previous-line) ("<up>" . buffer-menu-previous-line)
                  ("d" . buffer-menu-delete) ("k" . buffer-menu-delete) ("s" . buffer-menu-save) ("u" . buffer-menu-unmark)
                  ("x" . buffer-menu-execute) ("g" . buffer-menu-revert) ("q" . buffer-menu-quit)))
      #t)))
