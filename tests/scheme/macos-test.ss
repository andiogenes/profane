(import (chezscheme) (srfi :64) (profane buffer) (profane keymap) (profane command)
        (profane command-loop) (profane var) (profane simple) (profane macos))

(invoke-library '(profane simple))

(test-begin "macos")

;; A fake pasteboard: a string and a change count that rises on every write, by us or "another app".
(define board #f)
(define count 0)
(define (external-copy! text) (set! board text) (set! count (+ count 1)))
(set-pasteboard-backend! (lambda () board)
                         (lambda (text) (external-copy! text) count)
                         (lambda () count))

(test-eqv "set returns the change count" 1 (pasteboard-set! "x"))
(test-equal "get" "x" (pasteboard-string))
(test-eqv "count" 1 (pasteboard-change-count))

;; ---- kills go to the pasteboard ----
(kill-new "killed")
(test-equal "kill-new writes the pasteboard" "killed" board)
(test-equal "and our own write is not read back in" '("killed") (kill-ring))
(test-equal "yank takes it from the ring" "killed" (current-kill))
(test-eqv "once" 1 (length (kill-ring)))

(set-buffer (generate-new-buffer "k"))
(insert "one two\n")
(goto-char 0)
(for-each handle-key '("C-k"))
(for-each handle-key '("C-k"))
(test-equal "consecutive kills append, and the pasteboard follows" "one two\n" board)

;; ---- what another app copied is taken in once, at the next yank ----
(external-copy! "from elsewhere")
(test-equal "yank sees an outside copy" "from elsewhere" (current-kill))
(test-equal "it joined the ring" '("from elsewhere" "one two\n" "killed") (kill-ring))
(test-equal "taken once" "from elsewhere" (current-kill))
(test-eqv "no duplicate" 3 (length (kill-ring)))
(external-copy! "from elsewhere")
(current-kill)
(test-eqv "the same text again is not pushed twice" 3 (length (kill-ring)))
(external-copy! "")
(current-kill)
(test-eqv "an empty pasteboard is ignored" 3 (length (kill-ring)))

;; the ring still wins when the pasteboard has not changed since (yank, then kill, then yank)
(kill-new "newest")
(test-equal "newest first" "newest" (current-kill))

;; ---- select-enable-clipboard off: the ring stays private ----
(var-set! 'select-enable-clipboard #f)
(kill-new "private")
(test-equal "not written" "newest" board)
(external-copy! "ignored")
(test-equal "not read" "private" (current-kill))
(var-set! 'select-enable-clipboard #t)

;; ---- yank inserts the pasteboard's text ----
(erase-buffer)
(external-copy! "pasted text")
(for-each handle-key '("C-y"))
(test-equal "C-y yanks what was copied elsewhere" "pasted text" (buffer-string))

;; ---- no pasteboard at all: the ring works alone ----
(set-pasteboard-backend! #f)
(test-eqv "no backend" #f (pasteboard-change-count))
(kill-new "alone")
(test-equal "ring only" "alone" (current-kill))

;; ---- shell-only calls say so without the shell ----
(define (fails? thunk) (guard (c [else #t]) (thunk) #f))
(test-assert "open-url" (fails? (lambda () (open-url "https://example.com"))))
(test-assert "run-applescript" (fails? (lambda () (run-applescript "return 1"))))
(test-assert "app-window-bounds" (fails? (lambda () (app-window-bounds "Finder"))))

(test-end "macos")
(test-exit)
