(import (chezscheme) (srfi :64) (profane buffer) (profane keymap) (profane command)
        (profane command-loop) (profane simple))

(invoke-library '(profane simple)) ; registers commands and bindings (see boot.ss)

(test-begin "command")

(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))
(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))

(set-buffer (generate-new-buffer "cmd"))

(type "hello")
(test-equal "typing inserts" "hello" (buffer-string))
(keys "C-b C-b DEL")
(test-equal "motion and backspace" "helo" (buffer-string))
(keys "C-a")
(test-eqv "C-a" 0 (point))
(keys "C-e RET")
(type "second line")

;; "x" / "helo" / "second line": the goal column survives short lines.
(keys "M-<")
(type "x")
(keys "RET M-> <up> <up>")
(test-eqv "clamped to the short line" 1 (point))
(keys "<down> <down>")
(test-eqv "goal column kept" 11 (- (point) (line-beginning-position)))

;; Errors and unbound keys are contained, reported in *Messages*.
(keys "M-< C-b")
(test-eqv "error at buffer start is contained" 0 (point))
(keys "<f12>")
(test-eqv "unbound key" #f (last-command))
(test-equal "reported" "<f12> is undefined" (current-message))

;; ---- prefix keys ----
(keys "C-x")
(test-equal "prefix waits" '("C-x") (pending-keys))
(test-equal "prefix echoed" "C-x-" (current-message))
(keys "C-x")
(test-eq "C-x C-x" 'exchange-point-and-mark (last-command))
(keys "C-x C-g")
(test-equal "C-g cancels a prefix" '() (pending-keys))
(test-equal "quit" "Quit" (current-message))
(keys "C-x C-q")
(test-equal "undefined sequence" "C-x C-q is undefined" (current-message))

;; ---- prefix arguments ----
(set-buffer (generate-new-buffer "args"))
(keys "C-u")
(type "a")
(test-equal "C-u repeats 4 times" "aaaa" (buffer-string))
(keys "C-u C-u")
(type "b")
(test-eqv "C-u C-u: 16" 20 (buffer-size))
(keys "C-u")
(type "12")
(type "c")
(test-eqv "C-u 12" 32 (buffer-size))
(keys "M-3")
(type "d")
(test-eqv "M-3" 35 (buffer-size))
(keys "M-< C-u 3 C-f")
(test-eqv "C-u 3 C-f" 3 (point))
(keys "C-- C-f")
(test-eqv "C-- moves backward" 2 (point))
(type "x")
(test-eqv "argument used up" 36 (buffer-size))

;; ---- typing runs and undo ----
;; Regression: the run of the previous buffer ("x" above) used to continue here, so the first
;; undo took 6 characters.
(set-buffer (generate-new-buffer "amalgamation"))
(type (make-string 25 #\a))
(keys "C-/")
(test-eqv "first undo removes the last 5 typed" 20 (buffer-size))
(keys "C-/")
(test-eqv "then the run of 20" 0 (buffer-size))
(keys "C-?")
(test-eqv "undo-redo" 20 (buffer-size))

;; ---- kill ring ----
(set-buffer (generate-new-buffer "kills"))
(type "one two")
(keys "RET")
(type "three")
(keys "M-< C-k")
(test-equal "kill-line" "\nthree" (buffer-string))
(keys "C-k")
(test-equal "consecutive kills append" "one two\n" (car (kill-ring)))
(keys "C-e C-y")
(test-equal "yank" "threeone two\n" (buffer-string))
(keys "M-< C-SPC C-e M-w")
(test-equal "kill-ring-save copies the region" "threeone two" (car (kill-ring)))

;; ---- live redefinition: keys bind names ----
(define-command (insert-tab) (insert "<tab>"))
(keys "TAB")
(test-assert "redefined command runs" (string=? "<tab>" (buffer-substring (- (point) 5) (point))))
(define-key! (global-map) "C-c t" 'insert-tab)
(keys "C-c t")
(test-eq "two-key binding" 'insert-tab (last-command))

(test-end "command")
(test-exit)
