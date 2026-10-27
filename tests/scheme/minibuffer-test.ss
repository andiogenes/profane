(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window)
        (profane display) (profane theme) (profane themes) (profane tab-bar)
        (profane minibuffer) (profane complete) (profane simple))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane minibuffer) (profane complete)))
(load-theme 'profane-light)

(test-begin "minibuffer")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))

(define f (select-frame (make-headless-frame 800 600)))
(define w (selected-window))
(define scratch (window-buffer w))

;; ---- read-from-minibuffer ----
(define got #f)
(read-from-minibuffer "Name: " (lambda (s) (set! got s)))
(test-assert "active" (minibuffer-active?))
(test-assert "shows the minibuffer buffer" (string=? (buffer-name (window-buffer (minibuffer-window))) " *Minibuf-1*"))
(type "abc")
(test-equal "typed input" "abc" (minibuffer-contents))
(test-equal "the window's buffer is untouched" "" (with-current-buffer scratch (buffer-string)))
(keys "DEL DEL DEL DEL")
(test-equal "DEL stops at the prompt" "" (minibuffer-contents))
(test-equal "prompt is kept" "Name: " (with-current-buffer (window-buffer (minibuffer-window)) (buffer-string)))
(type "xy")
(keys "RET")
(test-equal "RET finishes" "xy" got)
(test-assert "closed" (not (minibuffer-active?)))
(test-equal "echo area back" " *Echo Area*" (buffer-name (window-buffer (minibuffer-window))))
(test-eq "keys go to the window again" scratch (current-buffer))

;; ---- C-j ----
(set! got #f)
(read-from-minibuffer "Name: " (lambda (s) (set! got s)))
(type "j")
(keys "C-j")
(test-equal "C-j finishes like RET" "j" got)
(test-assert "C-j closed" (not (minibuffer-active?)))

;; ---- C-g ----
(set! got #f)
(define quit? #f)
(completing-read "Pick: " '("a") (lambda (s) (set! got s)) 'quit (lambda () (set! quit? #t)))
(keys "C-g")
(test-assert "C-g closes without calling k" (and (not got) quit? (not (minibuffer-active?))))
(test-eq "and the window's buffer is current again (regression: it stayed the minibuffer)" scratch (current-buffer))

;; ---- completion ----
(test-equal "orderless: any order, case-insensitive"
  '("forward-word" "word-forward")
  (completion-candidates '("forward-word" "word-forward" "backward-char") "word fo"))
(test-equal "case-sensitive with capitals" '("Foo") (completion-candidates '("foo" "Foo") "Fo"))
(test-equal "prefix first, then shorter"
  '("kill-line" "kill-buffer" "backward-kill")
  (completion-candidates '("backward-kill" "kill-buffer" "kill-line") "kill"))
(test-equal "procedure collections" '("x1") (completion-candidates (lambda (in) (list (string-append "x" in))) "1"))

(completing-read "Cmd: " '("apple" "apricot" "banana") (lambda (s) (set! got s)))
(define (mini-text) (with-current-buffer (window-buffer (minibuffer-window)) (buffer-string)))
(test-equal "candidates listed below the input" "Cmd: \napple\nbanana\napricot" (mini-text))
(type "ap")
(test-equal "filtered" "Cmd: ap\napple\napricot" (mini-text))
(keys "C-n")
(keys "RET")
(test-equal "RET takes the selected candidate" "apricot" got)

(completing-read "Cmd: " '("apple" "banana") (lambda (s) (set! got s)) 'require-match #t)
(type "zzz")
(keys "RET")
(test-assert "match required keeps it open" (minibuffer-active?))
(test-equal "and says so" "[No match]" (let ([t (mini-text)]) (substring t (- (string-length t) 10) (string-length t))))
(keys "C-g")

(completing-read "Cmd: " '("apple") (lambda (s) (set! got s)))
(type "zzz")
(keys "RET")
(test-equal "no candidates: the input" "zzz" got)
(completing-read "Cmd: " '("apple") (lambda (s) (set! got s)))
(type "app")
(keys "M-RET")
(test-equal "M-RET: the input as typed" "app" got)

(completing-read "Cmd: " '("apple" "banana") (lambda (s) (set! got s)) 'default "banana")
(keys "RET")
(test-equal "empty input takes the default" "banana" got)
(completing-read "Cmd: " '("apple" "banana" "cherry") (lambda (s) (set! got s))
                 'preselect (lambda (cands) 2))
(keys "RET")
(test-equal "preselect" "cherry" got)

(completing-read "Cmd: " '("apple" "banana") (lambda (s) (set! got s)) 'annotate (lambda (c) (string-append "<" c ">")))
(test-equal "annotations" "Cmd: \napple  <apple>\nbanana  <banana>" (mini-text))
(keys "TAB")
(test-equal "TAB completes the selected candidate" "apple" (minibuffer-contents))
(keys "C-g")

(define previews '())
(completing-read "Cmd: " '("apple" "banana") (lambda (s) (void))
                 'preview (lambda (c) (set! previews (cons c previews))))
(keys "C-n")
(test-equal "preview follows the selection" '("banana" "apple") previews)
(keys "C-g")

(define-variable 'vertico-count 5)
(completing-read "N: " (map number->string (iota 20)) (lambda (s) (set! got s)))
(test-eqv "five rows" 6 (+ 1 (length (filter (lambda (c) (char=? c #\newline)) (string->list (mini-text))))))
(keys "C-g")

;; ---- history ----
(read-from-minibuffer "H: " (lambda (s) (void)))
(type "one") (keys "RET")
(set! got #f)
(read-from-minibuffer "H: " (lambda (s) (set! got s)) "")
(keys "C-g")
(test-assert "recursive minibuffers are refused"
  (begin (read-from-minibuffer "A: " void)
         (guard (c [else #t]) (read-from-minibuffer "B: " void) #f)))
(keys "C-g")

;; ---- commands ----
(set! got #f)
(keys "M-x")
(type "undo")
(test-assert "M-x lists commands" (member "undo" (completion-candidates (map symbol->string (command-names)) "undo")))
(keys "M-RET")
(test-assert "M-x ran it (no error, closed)" (not (minibuffer-active?)))

(keys "C-x b")
(type "other buf")
(keys "M-RET")
(test-equal "C-x b creates and shows" "other buf" (buffer-name (window-buffer w)))
(test-eq "current" (window-buffer w) (current-buffer))

(keys "C-x k")
(test-assert "C-x k asks" (minibuffer-active?))
(keys "RET")
(test-assert "C-x k killed it" (not (get-buffer "other buf")))

(keys "C-x t RET")
(type "work")
(keys "RET")
(test-assert "C-x t RET renamed" (not (minibuffer-active?)))

(delete-headless-frame! f)
(test-end "minibuffer")
(test-exit)
