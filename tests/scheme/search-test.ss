(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window)
        (profane display) (profane theme) (profane themes) (profane tab-bar)
        (profane minibuffer) (profane complete) (profane simple) (profane files) (profane async)
        (profane process) (profane search))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane minibuffer) (profane complete)
                           (profane search)))
(load-theme 'profane-light)

(test-begin "search")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))
(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))
(define (minibuffer-text) (with-current-buffer (window-buffer (minibuffer-window)) (buffer-string)))
(define (wait-for pred)
  (let loop ([n 0])
    (cond [(pred) #t] [(> n 300) #f] [else (async-poll! 20) (loop (+ n 1))])))
(define (wait-for-text . subs)
  (wait-for (lambda () (and (minibuffer-active?) (let ([t (minibuffer-text)]) (for-all (lambda (s) (contains? t s)) subs))))))
(define (write-file! path text)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

;; ---- a project ----
(define root
  (let ([d (format "/tmp/pf-search-~a-~a" (time-second (current-time)) (time-nanosecond (current-time)))])
    (mkdir d)
    (mkdir (string-append d "/.git"))
    (mkdir (string-append d "/sub"))
    (write-file! (string-append d "/sub/a.txt") "alpha\n  needle one\nomega\n")
    (write-file! (string-append d "/b.txt") "needle two\n")
    (write-file! (string-append d "/c.txt") "nothing here\n")
    (write-file! (string-append d "/ünï.txt") "héllo wörld needle\n")
    (write-file! (string-append d "/ignored.txt") "needle ignored\n")
    (write-file! (string-append d "/.gitignore") "ignored.txt\n")
    d))

(define f (select-frame (make-headless-frame 800 600)))
(define w (selected-window))
(define start (generate-new-buffer "start"))
(set-window-buffer! w start)
(with-current-buffer start (insert "start buffer text") (var-set! 'default-directory (string-append root "/sub")))
(var-set! 'search-debounce-ms 0)

(test-equal "the project root is the directory holding .git" (string-append root "/")
  (project-root (string-append root "/sub/")))
(test-equal "or the directory itself" "/tmp/" (project-root "/tmp"))

(define buffers-before (length (buffer-list)))
(define (search-command name) ((command-procedure name)))

;; ---- ripgrep ----
(search-command 'consult-ripgrep)
(test-assert "the minibuffer is open" (minibuffer-active?))
(type "ne")
(test-assert "too short a query starts nothing" (null? (process-list)))
(type "edle")
(test-assert "results arrive" (wait-for-text "b.txt:1:needle two" "sub/a.txt:2:  needle one"))
(test-assert "non-ASCII file names and text" (contains? (minibuffer-text) "ünï.txt:1:héllo wörld needle"))
(test-assert ".gitignore is respected" (not (contains? (minibuffer-text) "ignored")))
(test-assert "not matching files are absent" (not (contains? (minibuffer-text) "c.txt")))
(test-assert "the first match is previewed in the window"
  (and (buffer-file-name (window-buffer w)) (contains? (buffer-file-name (window-buffer w)) root)))

;; filter: narrow without searching again
(keys "C-a")
(for-each (lambda (_) (keys "C-d")) '(1 2 3 4 5 6))
(test-equal "emptied" "" (minibuffer-contents))
(type "#needle#two")
(test-assert "the filter narrows" (wait-for (lambda () (and (contains? (minibuffer-text) "b.txt:1:needle two") (not (contains? (minibuffer-text) "a.txt:2"))))))

;; RET jumps to the match, mark where point was
(keys "RET")
(test-assert "closed" (not (minibuffer-active?)))
(test-equal "visits the file" (string-append root "/b.txt") (buffer-file-name (current-buffer)))
(test-eqv "point is at the match" 0 (point))
(test-eq "the window shows it" (current-buffer) (window-buffer w))
(test-eqv "the mark is where point was" 17 (with-current-buffer start (mark)))
(test-assert "no process left" (null? (process-list)))

;; a match in the middle of a line goes to its column; non-ASCII before it counts characters
(set-window-buffer! w start)
(search-command 'consult-ripgrep)
(type "wörld")
(test-assert "found" (wait-for-text "ünï.txt:1:"))
(keys "RET")
(test-eqv "column in characters, not bytes" 6 (point))

;; C-g restores the window and kills preview buffers
(set-window-buffer! w start)
(let ([count (length (buffer-list))])
  (search-command 'consult-ripgrep)
  (type "needle")
  (wait-for-text "b.txt")
  (keys "C-n")
  (async-poll! 20)
  (keys "C-g")
  (test-eq "window back" start (window-buffer w))
  (test-eqv "point back" 17 (window-point w))
  (test-assert "preview buffers are gone" (<= (length (buffer-list)) (+ count 3)))
  (test-assert "no process left" (null? (process-list))))

;; a bad regex shows the error, not an empty list
(search-command 'consult-ripgrep)
(type "((((")
(test-assert "rg's error is the candidate" (wait-for-text "regex parse error"))
(keys "C-g")

;; ---- debounce: typing restarts nothing until it pauses ----
(var-set! 'search-debounce-ms 100)
(set-window-buffer! w start)
(search-command 'consult-ripgrep)
(type "needle")
(test-assert "nothing started yet" (null? (process-list)))
(test-assert "then the search runs" (wait-for-text "b.txt:1:needle two"))
(keys "C-g")
(var-set! 'search-debounce-ms 0)

;; ---- find ----
(define (find-test label)
  (set-window-buffer! w start)
  (search-command 'consult-find)
  (type "a.tx")
  (test-assert (string-append label ": found") (wait-for-text "sub/a.txt"))
  (test-assert (string-append label ": other files absent") (not (contains? (minibuffer-text) "b.txt")))
  (keys "RET")
  (test-equal (string-append label ": visits it") (string-append root "/sub/a.txt") (buffer-file-name (current-buffer)))
  (set-window-buffer! w start)
  (search-command 'consult-find)
  (type "#txt#ünï")
  (test-assert (string-append label ": filter") (wait-for-text "ünï.txt"))
  (keys "C-g")
  (test-assert (string-append label ": no process left") (null? (process-list))))

(test-assert "fd is used when installed" (or (not (executable-find "fd")) (not (null? (find-command "x")))))
(test-assert "fd command" (or (not (executable-find "fd")) (contains? (car (find-command "x")) "fd")))
(find-test "fd")
(var-set! 'search-use-fd #f)
(test-assert "find fallback command" (contains? (car (find-command "x")) "find"))
(find-test "find")

;; ---- programs ----
(test-assert "executable-find" (executable-find "sh"))
(test-eqv "unknown program" #f (executable-find "no-such-program-pf"))
(var-set! 'exec-path '())
(test-eqv "an empty exec-path finds nothing" #f (executable-find "sh"))

(system (string-append "rm -rf " root))
(test-end "search")
(test-exit)
