(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window) (profane display)
        (profane theme) (profane themes) (profane tab-bar) (profane canvas) (profane avy)
        (profane simple))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane canvas) (profane avy)))
(load-theme 'profane-light)

(test-begin "avy")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))

(define f (select-frame (make-headless-frame 800 600)))
(define fh (%frame-handle f))
(define (overlay) (%cvs-overlay-redisplay fh))
(define w1 (selected-window))

;; ---- labels ----
(test-equal "one key each while they last" '("a" "s" "d") (avy-labels 3 '("a" "s" "d" "f")))
(test-equal "more candidates than keys: two keys each" '("aa" "as" "ad" "sa" "ss")
  (avy-labels 5 '("a" "s" "d")))
(test-equal "exactly as many as keys" '("a" "s") (avy-labels 2 '("a" "s")))

;; ---- the window can say where a character is ----
(define b (get-buffer-create "avy-text"))
(switch-to-buffer b)
(insert "foo bar baz\nfab far\n _fz\n")
(goto-char 0)
(redisplay-prepare!)
(%frm-redisplay fh)
(test-equal "a character's cell (10 pt cells, 20 pt lines, pad 1 and 2)" '(1.0 2.0 10.0 20.0)
  (window-pos-rect w1 0))
(test-equal "second line" '(31.0 22.0 10.0 20.0) (window-pos-rect w1 15))
(test-assert "not visible past the buffer" (not (window-pos-rect w1 400)))

(overlay)

;; ---- avy-goto-word-1 ----
;; "foo bar baz\nfab far\n _fz\n": f-words are foo 0, fab 12, far 16 (the f of _fz is not a word start)
(define (run cmd) ((command-procedure cmd)))
(run 'avy-goto-word-1)
(test-equal "waits for a character" "Word start char: " (current-message))
(type "f")
(test-assert "labels are shown" (> (overlay) 0))
(keys "s")
(test-eqv "the second nearest f-word" 12 (point))
(test-eqv "labels are gone" 0 (overlay))
(test-eqv "the mark stays where we were" 0 (mark))

(goto-char 0)
(run 'avy-goto-word-1)
(type "f")
(keys "a")
(test-eqv "the nearest has the first label (here: the word at point)" 0 (point))

(run 'avy-goto-word-1)
(type "b")
(keys "s")
(test-eqv "bar, baz: the second nearest" 8 (point))

(goto-char 0)
(run 'avy-goto-word-1)
(type "z")
(test-equal "no word starts with z" "No visible match" (current-message))
(test-eqv "stays" 0 (point))

;; ---- cancelling ----
(run 'avy-goto-word-1)
(type "f")
(keys "C-g")
(test-eqv "C-g cancels" 0 (point))
(test-eqv "and removes the labels" 0 (overlay))
(test-assert "keys work normally again" (begin (keys "C-f") (= (point) 1)))
(goto-char 0)
(run 'avy-goto-word-1)
(type "f")
(keys "x")
(test-equal "a key that is no label" "No such label" (current-message))
(test-eqv "cancels" 0 (point))
(test-eqv "labels gone" 0 (overlay))

;; ---- avy-goto-char and avy-goto-line ----
(goto-char 0)
(run 'avy-goto-char)
(type "_")
(test-eqv "a single candidate is jumped to at once" 21 (point))
(goto-char 0)
(run 'avy-goto-line)
(keys "d")
(test-eqv "lines: 0, 12, 20, 25 get a s d f" 20 (point))

;; ---- longer labels ----
(var-set! 'avy-keys '("a" "s"))
(goto-char 0)
(run 'avy-goto-word-1)
(type "f")
(keys "s")
(test-assert "the first of two keys keeps the labels up" (> (overlay) 0))
(keys "a")
(test-eqv "foo aa, fab as, far sa" 16 (point))
(var-set! 'avy-keys '("a" "s" "d" "f" "g" "h" "j" "k" "l"))

;; ---- other windows ----
(define other (get-buffer-create "avy-other"))
(with-current-buffer other (insert "xyz xx"))
(split-window w1)
(define w2 (cadr (window-list)))
(set-window-buffer! w2 other)
(goto-char 0)
(run 'avy-goto-word-1)
(type "x")
(keys "s")
(test-eq "the other window is selected" w2 (selected-window))
(test-eqv "at that word" 4 (point))
(select-window w1)
(test-eqv "and the mark was left behind in the first" 0 (mark))

;; ---- through the key and the binding ----
(select-window w1)
(test-eq "C-x C-j is not bound here (init.ss is not loaded)" #f (lookup-key (global-map) (kbd "C-x C-j")))

(delete-headless-frame! f)
(test-end "avy")
(test-exit)
