(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window) (profane display)
        (profane theme) (profane themes) (profane tab-bar) (profane minibuffer) (profane complete)
        (profane simple) (profane help))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane minibuffer) (profane complete) (profane help)))
(load-theme 'profane-light)

(test-begin "help")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))
(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))
(define (help-text) (with-current-buffer (get-buffer "*Help*") (buffer-string)))

(define f (select-frame (make-headless-frame 800 600)))

(define-variable 'help-test-var 42 "A variable for the help tests.\nSecond line." '(local))
(define-command (help-test-command) "Does nothing, for the help tests." (void))
(define-key! (global-map) "C-c h t" 'help-test-command)

(test-eq "C-h f" 'describe-function (lookup-key (global-map) (kbd "C-h f")))
(test-eq "C-h v" 'describe-variable (lookup-key (global-map) (kbd "C-h v")))
(test-eq "C-h m" 'describe-mode (lookup-key (global-map) (kbd "C-h m")))

;; ---- describe-function ----
(keys "C-h f")
(test-assert "asks for a command" (minibuffer-active?))
(type "help-test-command")
(keys "RET")
(test-assert "closed" (not (minibuffer-active?)))
(test-assert "names the command" (contains? (help-text) "help-test-command is an interactive command"))
(test-assert "lists its key" (contains? (help-text) "C-c h t"))
(test-assert "shows the documentation" (contains? (help-text) "Does nothing, for the help tests."))
(test-assert "read-only" (with-current-buffer (get-buffer "*Help*") (buffer-read-only?)))
(test-eq "the buffer stays selected" #t (not (eq? (window-buffer (selected-window)) (get-buffer "*Help*"))))

;; ---- describe-variable ----
(keys "C-h v")
(type "help-test-var")
(keys "RET")
(test-assert "value" (contains? (help-text) "Value: 42"))
(test-assert "documentation" (contains? (help-text) "A variable for the help tests."))
(var-set! 'help-test-var 7)
(keys "C-h v")
(type "help-test-var")
(keys "RET")
(test-assert "local value" (contains? (help-text) "Value: 7"))
(test-assert "says it is local and gives the default"
             (and (contains? (help-text) "local to the current buffer") (contains? (help-text) "Default: 42")))

;; ---- set-variable ----
((command-procedure 'set-variable))
(test-assert "set-variable asks for a name" (minibuffer-active?))
(type "help-test-var")
(keys "RET")
(test-assert "then for a value" (minibuffer-active?))
(test-assert "starting from the current value" (contains? (with-current-buffer (window-buffer (minibuffer-window)) (buffer-string)) "to value: 7"))
(keys "C-a C-k")
(type "(+ 1 2)")
(keys "RET")
(test-eqv "the expression is evaluated" 3 (var-ref 'help-test-var))
(test-eqv "the default is untouched" 42 (var-default 'help-test-var))

;; ---- describe-mode ----
(keys "C-h m")
(test-assert "major mode" (contains? (help-text) "Major mode: Fundamental (fundamental-mode)"))
(with-current-buffer (get-buffer "*Help*")
  (test-eq "the help buffer is in help-mode" 'help-mode (var-ref 'major-mode)))
(switch-to-buffer (get-buffer "*Help*"))
(keys "C-h m")
(test-assert "lists the keys of the mode" (contains? (help-text) "q  help-quit"))

(delete-headless-frame! f)
(test-end "help")
(test-exit)
