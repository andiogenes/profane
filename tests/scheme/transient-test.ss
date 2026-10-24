(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window) (profane display)
        (profane theme) (profane themes) (profane tab-bar) (profane canvas) (profane minibuffer)
        (profane transient) (profane simple))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane canvas) (profane minibuffer)
                           (profane transient)))
(load-theme 'profane-light)

(test-begin "transient")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))

(define f (select-frame (make-headless-frame 800 600)))
(define fh (%frame-handle f))
(define (overlay) (%cvs-overlay-redisplay fh))

(define (open-it) ((command-procedure 'test-menu)))
(define ran '())
(register-command! 'test-commit (lambda () (set! ran (cons (cons 'commit (transient-args)) ran))) "")
(register-command! 'test-log (lambda () (set! ran (cons (cons 'log (transient-args)) ran))) "")

(define-transient (test-menu)
  "Test"
  ("Arguments"
   (switch "- a" "--all" all)
   (switch "- v" "--verbose" verbose #t)
   (option "- m" "--message=" message))
  ("Actions"
   (action "c" "Commit" test-commit)
   (action "l" "Log" test-log stay)))

(test-assert "defined as a command" (command? 'test-menu))
(test-equal "listed" '(test-menu) (transient-names))
(overlay)

(define b (get-buffer-create "menu-target"))
(switch-to-buffer b)

;; ---- opening ----
(open-it)
(test-assert "open" (transient-open?))
(test-assert "the panel is on the overlay" (> (overlay) 10))
(test-assert "keys are keys now (the shell sends plain keys as keys)" (transient-map-active?))

;; ---- switches ----
(keys "- a")
(test-equal "toggled on, defaults kept" '((all . #t) (verbose . #t))
  (begin (keys "c") (cdr (car ran))))
(test-assert "an action closes it" (not (transient-open?)))
(test-eqv "and removes the panel" 0 (overlay))
(test-assert "no longer in the way" (not (transient-map-active?)))

(set! ran '())
(open-it)
(keys "- v")
(keys "c")
(test-equal "a switch that starts on toggles off" '((commit)) ran)
(set! ran '())

;; ---- options read in the minibuffer ----
(open-it)
(keys "- m")
(test-assert "the minibuffer asks" (minibuffer-active?))
(test-assert "the menu's keys are off meanwhile" (not (transient-map-active?)))
(type "c- fix")                       ; menu keys typed here are text, not commands
(test-equal "typed into the minibuffer" "c- fix" (minibuffer-contents))
(keys "RET")
(test-assert "back to the menu" (and (transient-open?) (transient-map-active?)))
(test-assert "nothing leaked into the buffer" (string=? (buffer-string) ""))
(keys "c")
(test-equal "the option reaches the command" '((commit (verbose . #t) (message . "c- fix"))) ran)
(set! ran '())

;; C-g in the option prompt returns to the menu
(open-it)
(keys "- m")
(keys "C-g")
(test-assert "quitting the prompt keeps the menu" (and (transient-open?) (transient-map-active?)))
(keys "- m")
(test-equal "an empty value clears it" "" (minibuffer-contents))
(keys "RET")
(keys "c")
(test-equal "unset options are left out" '((commit (verbose . #t))) ran)
(set! ran '())

;; ---- stay, quit, unbound ----
(open-it)
(keys "l")
(test-assert "stay keeps it open" (transient-open?))
(test-equal "and ran" '((log (verbose . #t))) ran)
(keys "z")
(test-assert "unbound keys complain and stay" (and (transient-open?) (string=? (current-message) "z is undefined")))
(keys "-")
(keys "C-g")
(test-assert "C-g in the middle of a sequence cancels the sequence only" (transient-open?))
(keys "C-g")
(test-assert "C-g closes" (not (transient-open?)))
(test-eqv "panel gone" 0 (overlay))
(open-it)
(keys "ESC")
(test-assert "ESC closes" (not (transient-open?)))
(test-assert "ordinary typing works again" (begin (type "ok") (string=? (buffer-string) "ok")))

;; ---- reopening starts from the defaults; a second menu replaces the first ----
(set! ran '())
(open-it)
(keys "- a")
(keys "C-g")
(open-it)
(keys "c")
(test-equal "values do not carry over" '((commit (verbose . #t))) ran)

(delete-headless-frame! f)
(test-end "transient")
(test-exit)
