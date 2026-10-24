(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane keymap)
        (profane command) (profane command-loop) (profane mode) (profane window)
        (profane display) (profane theme) (profane themes) (profane tab-bar)
        (profane minibuffer) (profane complete) (profane simple) (profane files) (profane fs)
        (profane async) (profane process) (profane search) (profane dired) (profane sidebar))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane tab-bar) (profane minibuffer) (profane complete)
                           (profane files) (profane dired) (profane sidebar)))
(load-theme 'profane-light)

(test-begin "sidebar")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
;; commands that wait (git) park; run them to the end
(define (settle!)
  (let loop ([n 0])
    (when (and (command-busy?) (< n 500))
      (async-poll! 10)
      (resume-busy!)
      (loop (+ n 1)))))
(define (press . ks) (apply keys ks) (settle!))
(define (write-file! p text) (call-with-output-file p (lambda (port) (put-string port text)) 'replace))
(define (lines)
  (let loop ([s (buffer-string)] [cur '()] [out '()])
    (cond [(string=? s "") (reverse (if (null? cur) out (cons (list->string (reverse cur)) out)))]
          [(char=? (string-ref s 0) #\newline) (loop (substring s 1 (string-length s)) '() (cons (list->string (reverse cur)) out))]
          [else (loop (substring s 1 (string-length s)) (cons (string-ref s 0) cur) out)])))
(define (sidebar-lines) (with-current-buffer (get-buffer "*Sidebar*") (lines)))
(define (current-line) (buffer-substring (line-beginning-position) (line-end-position)))
(define (goto-line-containing! text)
  (goto-char 0)
  (let loop ()
    (cond [(let ([l (current-line)] [n (string-length text)])
             (let find ([i 0]) (and (<= (+ i n) (string-length l)) (or (string=? (substring l i (+ i n)) text) (find (+ i 1))))))
           #t]
          [(= 0 (forward-line 1)) (loop)]
          [else #f])))

;; ---- a project: a git repository with ignored and hidden files ----
(define root (format "/tmp/pf-sidebar-~a-~a" (time-second (current-time)) (time-nanosecond (current-time))))
(define (path . parts) (apply string-append root (map (lambda (p) (string-append "/" p)) parts)))
(make-directory root)
(for-each make-directory (list (path "src") (path "src" "util") (path "build")))
(write-file! (path "README.md") "readme")
(write-file! (path "src" "main.c") "int main;")
(write-file! (path "src" "util" "helper.c") "helper")
(write-file! (path "build" "out.o") "obj")
(write-file! (path "debug.log") "log")
(write-file! (path ".hidden") "h")
(write-file! (path ".gitignore") "build/\n*.log\n")
(system (string-append "git -C " root " init -q"))

(define f (select-frame (make-headless-frame 800 600)))
(define main (selected-window))
(define start (generate-new-buffer "start"))
(set-window-buffer! main start)
(with-current-buffer start (var-set! 'default-directory (string-append (path "src") "/")))
(define-key! (global-map) "M-g t" 'sidebar-toggle)
(set-minor-mode! 'display-line-numbers-mode #t)

;; ---- opening (through the key: the command waits for git while the editor lives) ----
(keys "M-g t")
(test-assert "the command waits for git" (command-busy?))
(settle!)
(define side (sidebar-window))
(test-assert "a sidebar window" side)
(test-eq "selected" side (selected-window))
(test-eqv "two windows" 2 (length (window-list)))
(test-assert "dedicated" (window-dedicated? side))
(test-equal "on the left, 30 columns" '(0.0 0.0 300.0 576.0) (window-edges side))
(test-eqv "no line numbers there" 0 (%win-option (%window-handle side) 1))
(test-assert "read-only" (with-current-buffer (get-buffer "*Sidebar*") (buffer-read-only?)))
(test-equal "the project root, ignored and hidden files left out; directories first"
  (list (string-append (file-name-nondirectory root) "/") "\x25B8; src" "  README.md") (sidebar-lines))
(test-equal "point on the first entry" "\x25B8; src" (current-line))

;; ---- expanding ----
(press "RET")
(test-equal "RET expands a directory"
  (list (string-append (file-name-nondirectory root) "/") "\x25BE; src" "  \x25B8; util" "    main.c" "  README.md") (sidebar-lines))
(test-equal "point stays on it" "\x25BE; src" (current-line))
(press "n" "TAB")
(test-equal "TAB expands the directory at point"
  (list (string-append (file-name-nondirectory root) "/") "\x25BE; src" "  \x25BE; util" "      helper.c" "    main.c" "  README.md") (sidebar-lines))
(press "TAB")
(test-eqv "and collapses it again" 5 (length (sidebar-lines)))
(press "p")
(test-equal "p moves up" "\x25BE; src" (current-line))
(press "p" "p" "p")
(test-equal "and stops at the top entry" "\x25BE; src" (current-line))

;; ---- opening a file in the main window ----
(press "n" "n")
(test-equal "on main.c" "    main.c" (current-line))
(press "RET")
(test-eq "the file opens in the main window" main (selected-window))
(test-equal "visiting it" (path "src" "main.c") (buffer-file-name (window-buffer main)))
(test-equal "the sidebar still shows the tree" "*Sidebar*" (buffer-name (window-buffer side)))

;; ---- hidden files ----
(select-window side)
(press "H")
(test-assert "H shows hidden and ignored files"
  (let ([ls (sidebar-lines)])
    (for-all (lambda (n) (exists (lambda (l) (string=? l n)) ls)) '("  .hidden" "  .gitignore" "  debug.log" "\x25B8; build" "\x25B8; .git"))))
(press "H")
(test-assert "and hides them again" (not (exists (lambda (l) (string=? l "  .hidden")) (sidebar-lines))))

;; ---- refresh ----
(write-file! (path "NEW.txt") "n")
(test-assert "a new file is not listed until refreshed" (not (exists (lambda (l) (string=? l "  NEW.txt")) (sidebar-lines))))
(press "g")
(test-assert "g refreshes" (exists (lambda (l) (string=? l "  NEW.txt")) (sidebar-lines)))
(test-assert "keeping what was expanded" (exists (lambda (l) (string=? l "\x25BE; src")) (sidebar-lines)))
(write-file! (path "late.log") "ignored by *.log")
(press "g")
(test-assert "ignored files stay hidden after a refresh" (not (exists (lambda (l) (string=? l "  late.log")) (sidebar-lines))))

;; ---- changing the root ----
(goto-line-containing! "util")
(press "C")
(test-equal "C makes the directory the root" "util/" (car (sidebar-lines)))
(test-equal "its files" '("util/" "  helper.c") (sidebar-lines))
(press "U")
(test-equal "U goes up" "src/" (car (sidebar-lines)))
(press "U")
(test-equal "and up again" (string-append (file-name-nondirectory root) "/") (car (sidebar-lines)))

;; ---- dired from the tree ----
(goto-line-containing! "src")
(press "d")
(test-eq "dired opens in the main window" main (selected-window))
(test-eq "as a dired buffer" 'dired-mode (var-ref 'major-mode))
(test-equal "on that directory" (string-append (path "src") "/") (var-ref 'dired-directory))

;; ---- hiding and showing again ----
(select-window side)
(press "q")
(test-assert "q hides the tree" (not (sidebar-window)))
(test-eqv "one window" 1 (length (window-list)))
(press "M-g t")
(test-assert "M-g t shows it again" (sidebar-window))
(test-assert "with what was expanded" (exists (lambda (l) (string=? l "\x25BE; src")) (sidebar-lines)))
(press "M-g t")
(test-assert "and hides it" (not (sidebar-window)))

;; ---- no git: only dotfiles are hidden ----
(define plain-root (format "~a-plain" root))
(make-directory plain-root)
(write-file! (string-append plain-root "/a.txt") "a")
(write-file! (string-append plain-root "/b.log") "b")
(write-file! (string-append plain-root "/.dot") "d")
(with-current-buffer start (var-set! 'default-directory (string-append plain-root "/")))
(select-window main)
(switch-to-buffer start)
(press "M-g t")
(test-equal "a directory outside any repository: only dotfiles are hidden" '("  a.txt" "  b.log")
  (let ([ls (sidebar-lines)]) (cdr ls)))
(press "q")

(system (string-append "rm -rf " root " " plain-root))
(test-end "sidebar")
(test-exit)
