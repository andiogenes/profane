(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window)
        (profane display) (profane theme) (profane themes) (profane tab-bar)
        (profane minibuffer) (profane complete) (profane simple) (profane files) (profane fs)
        (profane macos) (profane dired))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane minibuffer) (profane complete)
                           (profane files) (profane dired)))
(load-theme 'profane-light)

(test-begin "dired")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))
(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))
(define (write-file! p text) (call-with-output-file p (lambda (port) (put-string port text)) 'replace))
(define (read-file p) (call-with-input-file p get-string-all))
(define (lines)
  (let loop ([s (buffer-string)] [cur '()] [out '()])
    (cond [(string=? s "") (reverse (if (null? cur) out (cons (list->string (reverse cur)) out)))]
          [(char=? (string-ref s 0) #\newline) (loop (substring s 1 (string-length s)) '() (cons (list->string (reverse cur)) out))]
          [else (loop (substring s 1 (string-length s)) (cons (string-ref s 0) cur) out)])))
;; the file names of the listing, in order (without the header)
(define (names)
  (let ([col (var-ref 'dired-name-column)])
    (map (lambda (l) (substring l col (string-length l))) (cdr (lines)))))
(define (marks) (map (lambda (l) (string-ref l 0)) (cdr (lines))))
(define (current-name) (let ([l (with-current-buffer (current-buffer) (buffer-substring (line-beginning-position) (line-end-position)))])
                         (substring l (var-ref 'dired-name-column) (string-length l))))
(define (goto-name! n) (goto-char 0) (forward-line 1) (let loop () (unless (string=? (current-name) n) (forward-line 1) (loop))))
(define (answer s) (type s) (keys "RET"))
;; read-file-name starts at the proposed directory: clear it, type PATH, finish
(define (answer-path p) (keys "C-a" "C-k") (type p) (keys "RET"))

(define root (format "/tmp/pf-dired-~a-~a" (time-second (current-time)) (time-nanosecond (current-time))))
(define (path . parts) (apply string-append root (map (lambda (p) (string-append "/" p)) parts)))
(make-directory root)
(make-directory (path "sub"))
(make-directory (path "zdir"))
(write-file! (path "alpha.txt") "a")
(write-file! (path "Beta.txt") "bbbbbbbbbb")
(write-file! (path ".hidden") "h")
(write-file! (path "sub" "inner.txt") "inner")
(system (string-append "ln -s alpha.txt " (path "link")))

(define f (select-frame (make-headless-frame 800 600)))
(define w (selected-window))
(define start (generate-new-buffer "start"))
(set-window-buffer! w start)

;; ---- the listing ----
(dired root)
(test-eq "a dired buffer" 'dired-mode (var-ref 'major-mode))
(test-equal "named after the directory" (file-name-nondirectory root) (buffer-name (current-buffer)))
(test-assert "read-only" (buffer-read-only?))
(test-equal "header" (string-append "  " root ":") (car (lines)))
(test-equal "directories first, then by name without regard to case; . and .. on top"
  '("." ".." "sub" "zdir" ".hidden" "alpha.txt" "Beta.txt" "link -> alpha.txt") (names))
(test-assert "permissions, owner and size are shown" (contains? (cadr (lines)) "drwx"))
(test-assert "a file's size" (contains? (list-ref (lines) 7) "10  "))
(test-equal "point starts on the first entry after . and .." "sub" (current-name))
(test-equal "default-directory follows" (string-append root "/") (var-ref 'default-directory))
(test-assert "typing is refused" (guard (c [else #t]) (insert "x") #f))

;; ---- moving ----
(handle-text "n")
(test-equal "n (typed text) moves down" "zdir" (current-name))
(keys "p")
(test-equal "p (a key) moves up" "sub" (current-name))
(keys "p" "p" "p" "p")
(test-equal "stops at the top" "." (current-name))
(keys "n" "n")
(test-equal "back" "sub" (current-name))

;; ---- marks ----
(handle-text "m")
(test-equal "m marks and moves down" '(#\space #\space #\* #\space #\space #\space #\space #\space) (marks))
(test-equal "on to the next" "zdir" (current-name))
(keys "d")
(test-equal "d flags" '(#\space #\space #\* #\D #\space #\space #\space #\space) (marks))
(keys "p" "p" "u")
(test-equal "u unmarks" '(#\space #\space #\space #\D #\space #\space #\space #\space) (marks))
(keys "t")
(test-equal "t toggles every file (not . and ..); a flag counts as a mark" '(#\space #\space #\* #\space #\* #\* #\* #\*) (marks))
(keys "U")
(test-equal "U clears" (make-list 8 #\space) (marks))
(keys "<home>")
(test-assert "marking . is refused" (begin (goto-char 0) (forward-line 1) (guard (c [else #t]) ((command-procedure 'dired-mark)) #f)))

;; ---- opening ----
(dired root)
(goto-name! "sub")
(keys "RET")
(test-equal "RET on a directory shows it in dired" (string-append root "/sub/") (var-ref 'dired-directory))
(test-equal "its files" '("." ".." "inner.txt") (names))
(keys "^")
(test-equal "^ goes up" (string-append root "/") (var-ref 'dired-directory))
(test-equal "to where we came from" "sub" (current-name))
(goto-name! "alpha.txt")
(test-equal "a regular file" "alpha.txt" (current-name))
(keys "RET")
(test-equal "RET opens a file" (path "alpha.txt") (buffer-file-name (current-buffer)))
(switch-to-buffer (find-file-noselect (path "alpha.txt")))
(dired root)
(test-eq "dired reuses the buffer" (current-buffer) (get-buffer (file-name-nondirectory root)))
(test-eqv "one dired buffer per directory" 1 (length (filter (lambda (b) (equal? (buffer-name b) (file-name-nondirectory root))) (buffer-list))))

;; a file shows its directory with point on it
(dired (path "Beta.txt"))
(test-equal "dired on a file" "Beta.txt" (current-name))

;; find-file on a directory
(switch-to-buffer start)
(keys "C-x C-f")
(answer-path (path "sub/"))
(test-equal "find-file on a directory opens dired" (string-append root "/sub/") (var-ref 'dired-directory))
(keys "^")

;; C-x d
(switch-to-buffer start)
(keys "C-x d")
(answer-path (path "zdir/"))
(test-equal "C-x d" (string-append root "/zdir/") (var-ref 'dired-directory))
(dired root)

;; ---- copying names ----
(goto-name! "Beta.txt")
(keys "w")
(test-equal "w copies the name" "Beta.txt" (car (kill-ring)))
(keys "W")
(test-equal "W copies the full path" (path "Beta.txt") (car (kill-ring)))
(goto-char 0)
(keys "W")
(test-equal "W on the header copies the directory" root (car (kill-ring)))

;; ---- sorting ----
(dired root)
(keys "s")
(test-equal "by time, directories still first" "Sorted by time" (current-message))
(keys "s")
(test-equal "by size, largest first" '("." ".." "sub" "zdir" "Beta.txt" "link -> alpha.txt" ".hidden" "alpha.txt") (names))
(keys "s")
(test-equal "and back to names" "alpha.txt" (list-ref (names) 5))

;; ---- creating a directory ----
(dired root)
(keys "+")
(answer-path (path "made"))
(test-assert "created" (file-info-directory? (file-attributes (path "made"))))
(test-assert "listed, point on it" (and (member "made" (names)) (string=? (current-name) "made")))

;; ---- copying ----
(goto-name! "alpha.txt")
(keys "C")
(answer-path (path "copy.txt"))
(test-equal "copied" "a" (read-file (path "copy.txt")))
(test-assert "and listed" (member "copy.txt" (names)))
(test-assert "the original stays" (file-attributes (path "alpha.txt")))

;; into a directory: all marked files
(dired root)
(goto-name! "alpha.txt") (keys "m")
(goto-name! "copy.txt") (keys "m")
(keys "C")
(answer-path (path "zdir/"))
(test-equal "both copied into the directory" "a" (read-file (path "zdir" "copy.txt")))
(test-assert "alpha too" (file-attributes (path "zdir" "alpha.txt")))

;; an existing target asks first
(dired root)
(goto-name! "alpha.txt")
(write-file! (path "zdir" "alpha.txt") "old")
(keys "C")
(answer-path (path "zdir/"))
(test-assert "asks to overwrite" (minibuffer-active?))
(answer "no")
(test-equal "no: untouched" "old" (read-file (path "zdir" "alpha.txt")))
(keys "C")
(answer-path (path "zdir/"))
(answer "yes")
(test-equal "yes: replaced" "a" (read-file (path "zdir" "alpha.txt")))

;; many files need a directory
(dired root)
(goto-name! ".hidden") (keys "m")
(goto-name! "alpha.txt") (keys "m")
(keys "C")
(answer-path (path "nothing"))
(test-assert "to a name that is not a directory: refused" (contains? (current-message) "must be a directory"))
(test-eqv "nothing was created" #f (file-attributes (path "nothing")))
(keys "U")

;; ---- renaming ----
(dired root)
(goto-name! "copy.txt")
(keys "R")
(answer-path (path "renamed.txt"))
(test-assert "gone from the listing, new one there" (and (not (member "copy.txt" (names))) (member "renamed.txt" (names))))
(test-equal "moved" "a" (read-file (path "renamed.txt")))
(test-eqv "the old one is gone" #f (file-attributes (path "copy.txt")))
(goto-name! "renamed.txt")
(keys "R")
(answer-path (path "made/"))
(test-equal "moved into a directory" "a" (read-file (path "made" "renamed.txt")))

;; other dired buffers showing the target are refreshed too
(dired (path "made"))
(test-assert "the other listing has it" (member "renamed.txt" (names)))
(keys "^")

;; ---- deleting ----
(goto-name! "alpha.txt")
(keys "D")
(test-assert "asks" (minibuffer-active?))
(answer "no")
(test-assert "no: still there" (file-attributes (path "alpha.txt")))
(keys "D")
(answer "yes")
(test-eqv "yes: deleted" #f (file-attributes (path "alpha.txt")))
(test-assert "not listed" (not (member "alpha.txt" (names))))
(test-assert "the link to it is shown as it is" (member "link -> alpha.txt" (names)))

;; flagged
(goto-name! "Beta.txt") (keys "d")
(goto-name! "zdir") (keys "d")
(keys "x")
(test-assert "asks about the flagged" (minibuffer-active?))
(test-assert "and says how many" (contains? (with-current-buffer (window-buffer (minibuffer-window)) (buffer-string)) "2 files"))
(answer "yes")
(test-eqv "flagged file deleted" #f (file-attributes (path "Beta.txt")))
(test-eqv "flagged directory deleted with its contents" #f (file-attributes (path "zdir")))
(keys "x")
(test-equal "nothing flagged" "(No deletions requested)" (current-message))

;; the link is deleted, not what it points to
(write-file! (path "target.txt") "t")
(system (string-append "ln -s target.txt " (path "ln2")))
(keys "g")
(goto-name! "ln2 -> target.txt")
(keys "D")
(answer "yes")
(test-eqv "the link is gone" #f (file-attributes (path "ln2")))
(test-assert "its target is not" (file-attributes (path "target.txt")))

;; ---- refresh and quit ----
(write-file! (path "late.txt") "l")
(test-assert "not listed until refreshed" (not (member "late.txt" (names))))
(keys "g")
(test-assert "g refreshes" (member "late.txt" (names)))
(goto-name! "late.txt") (keys "m")
(keys "g")
(test-equal "marks survive a refresh" #\*
  (list-ref (marks) (let loop ([n (names)] [i 0]) (if (string=? (car n) "late.txt") i (loop (cdr n) (+ i 1))))))
(let ([b (current-buffer)])
  (switch-to-buffer start)
  (set-window-buffer! w b)
  (keys "q")
  (test-assert "q leaves the buffer, which stays alive" (and (not (eq? (current-buffer) b)) (buffer-live? b))))

(system (string-append "rm -rf " root))
(test-end "dired")
(test-exit)
