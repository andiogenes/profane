(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window)
        (profane display) (profane theme) (profane themes) (profane simple))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)))
(load-theme 'profane-light)

(test-begin "wrap")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))

;; A narrow headless frame: 10-point cells, so a few dozen characters fill a row.
(define f (select-frame (make-headless-frame 300 400)))
(define w (selected-window))
(define b (get-buffer-create "wrapped"))
(switch-to-buffer b)
(define long-line (make-string 100 #\x))
(with-current-buffer b
  (insert long-line "\nshort\n")
  (goto-char 0))
(redisplay-prepare!)

(test-eqv "truncated by default: a row is the whole line"
          100 (window-row-end w 5))

;; visual-line-mode wraps this buffer only.
(with-current-buffer b (set-minor-mode! 'visual-line-mode #t))
(define row-end (window-row-end w 5))
(test-assert "wraps at the window width" (< 10 row-end 100))
(test-eqv "the first row starts the line" 0 (window-row-start w 5))
(test-eqv "the next row starts where the first ends" row-end (window-row-start w row-end))
(with-current-buffer (get-buffer-create "other")
  (test-assert "other buffers are not affected" (not (minor-mode-enabled? 'visual-line-mode))))

;; Screen-row motion.
(goto-char 5)
(keys "C-n")
(test-eqv "C-n goes down a row, keeping the column" (+ row-end 5) (point))
(keys "C-n")
(test-assert "and on to the third row" (> (point) (* 2 (- row-end 1))))
(keys "C-p")
(test-eqv "C-p goes back up, to the same column" (+ row-end 5) (point))
(keys "C-a")
(test-eqv "C-a goes to the start of the row" row-end (point))
(keys "C-e")
(test-eqv "C-e goes to the end of the row, before the wrap" (- (window-row-end w row-end) 1) (point))

;; Without the mode, motion is by lines again.
(with-current-buffer b (set-minor-mode! 'visual-line-mode #f))
(goto-char 5)
(keys "C-n")
(test-eqv "by line without visual-line-mode" 106 (point))

;; truncate-lines #f wraps without the motion change; word-wrap is a separate setting.
(with-current-buffer b (var-set! 'truncate-lines #f))
(test-eqv "truncate-lines #f wraps" row-end (window-row-end w 5))
(with-current-buffer b (var-set! 'truncate-lines #t))
(test-eqv "and #t truncates again" 100 (window-row-end w 5))

(delete-headless-frame! f)
(test-end "wrap")
(test-exit)
