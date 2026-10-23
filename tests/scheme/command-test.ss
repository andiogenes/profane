(import (chezscheme) (srfi :64) (profane buffer) (profane command))

(test-begin "command")

(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))
(define (keys . ks) (for-each handle-key ks))

(set-buffer (generate-new-buffer "cmd"))

(type "hello")
(test-equal "typing inserts" "hello" (buffer-string))
(keys "C-b" "C-b" "DEL")
(test-equal "motion and backspace" "helo" (buffer-string))
(test-eqv "point" 2 (point))
(keys "C-a")
(test-eqv "C-a" 0 (point))
(keys "C-e" "RET")
(type "second line")
(test-equal "newline" "helo\nsecond line" (buffer-string))

;; Goal column survives a short line in between.
(keys "M-<")
(type "x")
(keys "RET")
;; "x" / "helo" / "second line": from the end of the long line, up twice and down twice.
(keys "M->" "<up>" "<up>")
(test-eqv "clamped to the short line" 1 (point))
(keys "<down>" "<down>")
(test-eqv "goal column kept across short lines" 11 (- (point) (line-beginning-position)))

;; Unbound keys and failing commands beep instead of escaping.
(keys "C-c" "M-<" "C-b")
(test-eqv "error at buffer start is contained" 0 (point))
(test-eqv "unbound key leaves no command" #f (begin (keys "<f12>") (last-command)))

;; Typing is undone in runs of self-insert-amalgamation characters.
(set-buffer (generate-new-buffer "amalgamation"))
(type (make-string 25 #\a))
(handle-key "C-/")
(test-eqv "first undo removes the last 5 typed" 20 (buffer-size))
(handle-key "C-/")
(test-eqv "then the run of 20" 0 (buffer-size))
(handle-key "C-?")
(test-eqv "undo-redo" 20 (buffer-size))
(type "b")
(keys "C-f")
(type "c")
(handle-key "C-_")
(test-equal "a motion command ends the typing run" (string-append (make-string 20 #\a) "b")
            (buffer-string))

;; Keys bind command names: redefining a command changes every key bound to it.
(define-command (insert-tab) (insert "<tab>"))
(handle-key "TAB")
(test-assert "redefined command runs" (string=? "<tab>" (buffer-substring (- (point) 5) (point))))
(global-set-key "C-t" 'insert-tab)
(handle-key "C-t")
(test-eq "key-binding" 'insert-tab (key-binding "C-t"))
(test-error "bindings must be symbols" #t (global-set-key "C-t" (lambda () #f)))

(test-end "command")
(test-exit)
