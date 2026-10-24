(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window) (profane display)
        (profane theme) (profane themes) (profane tab-bar) (profane minibuffer) (profane files)
        (profane simple))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane minibuffer) (profane files)))
(load-theme 'profane-light)

(test-begin "files")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))
(define (mini-text) (with-current-buffer (window-buffer (minibuffer-window)) (buffer-string)))

(define f (select-frame (make-headless-frame 800 600)))

;; ---- names ----
(define home (getenv "HOME"))
(test-equal "~ is the home directory" (string-append home "/x") (expand-file-name "~/x" "/"))
(test-equal "relative names use the directory" "/a/b/c" (expand-file-name "c" "/a/b"))
(test-equal ". and .. are resolved" "/a/b/d/" (expand-file-name "../d/./" "/a/b/c/"))
(test-equal "a trailing slash is kept" "/a/b/" (expand-file-name "b/" "/a"))
(test-equal "repeated slashes" "/a/b" (expand-file-name "a//b" "/"))
(test-equal ".. above the root stays at it" "/x" (expand-file-name "../../x" "/"))
(test-equal "the root" "/" (expand-file-name "/" "/anything"))
(test-equal "abbreviating" "~/x/y" (abbreviate-file-name (string-append home "/x/y")))
(test-equal "the home itself" "~" (abbreviate-file-name home))
(test-equal "other paths are left" "/etc/hosts" (abbreviate-file-name "/etc/hosts"))
(test-equal "directory part" "/a/b/" (file-name-directory "/a/b/c.txt"))
(test-equal "no directory part" "" (file-name-directory "c.txt"))
(test-equal "nondirectory part" "c.txt" (file-name-nondirectory "/a/b/c.txt"))

;; ---- a scratch directory ----
(define root (let ([d (format "/tmp/pf-files-~a" (time-nanosecond (current-time)))]) (mkdir d) d))
(define (path . parts) (apply string-append root (map (lambda (p) (string-append "/" p)) parts)))
(mkdir (path "alpha"))
(mkdir (path "beta"))
(mkdir (path "alpha" "inner"))
(define (write-text p text)
  (call-with-output-file p (lambda (o) (display text o)) 'truncate))
(write-text (path "readme.txt") "hello\n")
(write-text (path "notes.org") "* notes\n")
(write-text (path "alpha" "a.txt") "a\n")
(write-text (path ".hidden") "h\n")

(test-equal "entries: directories marked, sorted"
  '(".hidden" "alpha/" "beta/" "notes.org" "readme.txt")
  (directory-entries root))
(test-equal "an unreadable directory has none" '() (directory-entries "/nonexistent-dir"))

(var-set! 'default-directory (string-append root "/"))
(test-equal "default-directory" (string-append root "/") (default-directory))

;; ---- read-file-name ----
(define got #f)
(read-file-name "File: " (lambda (p) (set! got p)) (string-append root "/"))
(test-assert "asking" (minibuffer-active?))
(test-equal "everything in the directory, directories first, shown by name"
  (string-append "File: " root "/\n"  "alpha/\nbeta/\n.hidden\nnotes.org\nreadme.txt")
  (mini-text))
(test-assert "nothing selected: RET finishes with the directory" (begin (keys "RET") (not (minibuffer-active?))))
(test-equal "an absolute path, with the slash" (string-append root "/") got)

(read-file-name "File: " (lambda (p) (set! got p)) (string-append root "/"))
(type "rea")
(test-equal "filtered, the match is selected" (string-append "File: " root "/rea\nreadme.txt") (mini-text))
(keys "RET")
(test-equal "RET on a file finishes with it" (path "readme.txt") got)

;; entering a directory
(read-file-name "File: " (lambda (p) (set! got p)) (string-append root "/"))
(type "alp")
(keys "RET")
(test-assert "RET on a directory goes in" (minibuffer-active?))
(test-equal "the input is now the directory" (string-append root "/alpha/") (minibuffer-contents))
(test-assert "and shows its entries" (let ([t (mini-text)]) (and (> (string-length t) 0) (string=? (substring t (- (string-length t) 13) (string-length t)) "\ninner/\na.txt") )))
(keys "C-n" "RET")
(test-assert "C-n from the prompt selects the first: a directory again" (minibuffer-active?))
(test-equal "inner/" (string-append root "/alpha/inner/") (minibuffer-contents))
;; DEL right after a slash removes the component
(keys "DEL")
(test-equal "DEL after / deletes the component" (string-append root "/alpha/") (minibuffer-contents))
(keys "DEL")
(test-equal "again" (string-append root "/") (minibuffer-contents))
(keys "DEL")
(test-equal "and the directory above" "/tmp/" (minibuffer-contents))
(type "xy")
(keys "DEL")
(test-equal "ordinary DEL elsewhere deletes one character" "/tmp/x" (minibuffer-contents))
(keys "C-g")

;; M-DEL
(read-file-name "File: " (lambda (p) (set! got p)) (string-append root "/alpha/inn"))
(keys "M-DEL")
(test-equal "M-DEL deletes the partly typed component" (string-append root "/alpha/") (minibuffer-contents))
(keys "M-DEL")
(test-equal "and then the directory" (string-append root "/") (minibuffer-contents))
(keys "C-g")

;; a new file: nothing matches, RET takes the input
(read-file-name "File: " (lambda (p) (set! got p)) (string-append root "/"))
(type "brand-new.txt")
(keys "RET")
(test-equal "a path nothing matches is taken as typed" (path "brand-new.txt") got)

;; TAB completes
(read-file-name "File: " (lambda (p) (set! got p)) (string-append root "/b"))
(keys "TAB")
(test-equal "TAB completes a directory name" (string-append root "/beta/") (minibuffer-contents))
(keys "C-g")

;; relative input and ~
(var-set! 'default-directory (string-append root "/alpha/"))
(read-file-name "File: " (lambda (p) (set! got p)) "")
(type "a.txt")
(keys "RET")
(test-equal "relative names are taken from the buffer's directory" (path "alpha" "a.txt") got)

;; ---- the default directory follows the file ----
(var-set! 'default-directory #f)
(define b (find-file-noselect (path "readme.txt")))
(with-current-buffer b (test-equal "a buffer's file gives it a directory" (string-append root "/") (default-directory)))

;; ---- find-file ----
(var-set! 'default-directory (string-append root "/"))
(keys "C-x C-f")
(test-assert "C-x C-f asks" (minibuffer-active?))
(type "notes.org")
(keys "RET")
(test-equal "visits the file" "notes.org" (buffer-name (current-buffer)))
(test-equal "and reads it" "* notes\n" (buffer-string))
(test-equal "remembering its name" (path "notes.org") (buffer-file-name (current-buffer)))

(keys "C-x C-f")
(type "does-not-exist.txt")
(keys "RET")
(test-equal "a new file gets an empty buffer" "" (buffer-string))
(test-equal "that visits the file" (path "does-not-exist.txt") (buffer-file-name (current-buffer)))

;; ---- save-buffer and write-file ----
(insert "created\n")
(keys "C-x C-s")
(test-equal "C-x C-s writes it" (format "Wrote ~a" (path "does-not-exist.txt")) (current-message))
(test-equal "to disk" "created\n" (call-with-input-file (path "does-not-exist.txt") get-string-all))
(keys "C-x C-s")
(test-equal "nothing to save" "(No changes need to be saved)" (current-message))

(switch-to-buffer (get-buffer-create "no-file"))
(insert "text")
(keys "C-x C-s")
(test-assert "a buffer with no file asks where" (minibuffer-active?))
(type (path "written.txt"))
(keys "RET")
(test-equal "visits and names the buffer" "written.txt" (buffer-name (current-buffer)))
(test-equal "writes it" "text" (call-with-input-file (path "written.txt") get-string-all))

(keys "C-x C-f")
(type "alpha/")
(keys "RET")
(test-assert "a directory is not opened as a file" (let ([m (current-message)]) (and m (> (string-length m) 14) (let loop ([i 0]) (and (<= (+ i 14) (string-length m)) (or (string=? (substring m i (+ i 14)) "is a directory") (loop (+ i 1))))))))

(define (rm-rf p)
  (if (file-directory? p)
      (begin (for-each (lambda (n) (rm-rf (string-append p "/" n))) (directory-list p))
             (delete-directory p))
      (delete-file p)))
(rm-rf root)

(delete-headless-frame! f)
(test-end "files")
(test-exit)
