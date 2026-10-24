(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window) (profane display)
        (profane theme) (profane themes) (profane tab-bar) (profane ace-window) (profane canvas)
        (profane minibuffer) (profane complete) (profane simple))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane ace-window) (profane canvas)
                           (profane minibuffer) (profane complete)))
(load-theme 'profane-light)

(test-begin "init")

(define init-path
  (let loop ([dirs (library-directories)])
    (cond [(null? dirs) (error 'init-test "init.ss not found")]
          [else (let* ([d (if (pair? (car dirs)) (caar dirs) (car dirs))]
                       [p (string-append d "/init.ss")])
                  (if (file-exists? p) p (loop (cdr dirs))))])))

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))

(define f (select-frame (make-headless-frame 800 600)))
(load init-path)

(for-each (lambda (b) (test-eq (car b) (cdr b) (lookup-key (global-map) (kbd (car b)))))
          '(("M-[" . previous-buffer) ("M-]" . next-buffer) ("M-o" . ace-window)
            ("C-M-v" . edge-of-buffer) ("M-g b" . consult-buffer)
            ("M-g y" . consult-yank-from-kill-ring)))

;; edge-of-buffer: the end, or the beginning with C--.
(define b (get-buffer-create "edge"))
(switch-to-buffer b)
(insert "one\ntwo\nthree")
(goto-char 4)
(keys "C-M-v")
(test-eqv "C-M-v goes to the end" (point-max) (point))
(keys "C-- C-M-v")
(test-eqv "C-- C-M-v goes to the beginning" 0 (point))

;; M-[ and M-] cycle buffers.
(let ([first (current-buffer)])
  (keys "M-]")
  (test-assert "M-] shows another buffer" (not (eq? (current-buffer) first)))
  (keys "M-[")
  (test-eq "M-[ comes back" first (current-buffer)))

;; M-g y: the kill ring, newlines shown on one line.
(kill-new "first kill")
(kill-new "two\nlines")
(goto-char (point-max))
(keys "M-g y")
(test-assert "asks" (minibuffer-active?))
(test-eqv "a candidate line per kill, however many lines it has" 3
          (+ 1 (length (filter (lambda (c) (char=? c #\newline))
                               (string->list (with-current-buffer (window-buffer (minibuffer-window))
                                               (buffer-string)))))))
(keys "RET")
(test-assert "closed" (not (minibuffer-active?)))
(test-equal "inserted the selected kill, newline and all" "one\ntwo\nthreetwo\nlines" (buffer-string))

;; C-M-v in the minibuffer: last candidate, first with C--.
(completing-read "N: " '("a" "b" "c") (lambda (s) (set! s s)))
(keys "C-M-v")
(keys "RET")
(test-assert "closed" (not (minibuffer-active?)))
(let ([got #f])
  (completing-read "N: " '("aa" "bb" "cc") (lambda (s) (set! got s)))
  (keys "C-M-v" "RET")
  (test-equal "last candidate" "cc" got)
  (completing-read "N: " '("aa" "bb" "cc") (lambda (s) (set! got s)))
  (keys "C-n" "C-- C-M-v" "RET")
  (test-equal "first with C--" "aa" got))

;; consult-buffer previews and restores on quit.
(let* ([w (selected-window)] [orig (window-buffer w)] [other (get-buffer-create "other-one")])
  (keys "M-g b")
  (test-assert "asks" (minibuffer-active?))
  (type "other-one")
  (test-eq "the window previews the candidate" other (window-buffer w))
  (keys "C-g")
  (test-eq "and is restored on quit" orig (window-buffer w))
  (keys "M-g b")
  (type "other-one")
  (keys "RET")
  (test-eq "RET keeps it" other (window-buffer w)))

(delete-headless-frame! f)
(test-end "init")
(test-exit)
