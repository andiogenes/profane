(import (chezscheme) (srfi :64) (profane buffer) (profane keymap) (profane command)
        (profane command-loop) (profane mode) (profane var) (profane window) (profane display)
        (profane themes) (profane simple) (profane section))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane section)))

(test-begin "section")

(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k))) ks))
(define (text) (buffer-substring 0 (buffer-size)))
(define (string-search* s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))
(define (hunk-section n) (section-find (sections) `(hunk ,n)))
(define (line-at) (buffer-substring (line-beginning-position) (line-end-position)))

(define f (select-frame (make-headless-frame 600 400)))
(define b (get-buffer-create "*sections*"))
(switch-to-buffer b)
(set-major-mode! 'section-mode)
(set-buffer-read-only! #t)

(define (hunk n) (new-section 'hunk `(hunk ,n) (format "@@ hunk ~a @@" n)
                              (list (format "+line ~a a" n) (format "-line ~a b" n)) '() #f n))
(define (file name hunks) (new-section 'file `(file ,name) name '() hunks #f name))
(define (tree)
  (list (new-section 'staged 'staged '("Staged changes " ("(2)" . italic)) '()
                     (list (file "a.txt" (list (hunk 1) (hunk 2))) (file "b.txt" (list (hunk 3)))) #f #f)
        (new-section 'untracked 'untracked "Untracked files" '() (list (file "c.txt" '())) #f #f)))

(render-sections! (tree))
(test-equal "rendered text"
  (string-append "Staged changes (2)\n"
                 "a.txt\n"
                 "@@ hunk 1 @@\n+line 1 a\n-line 1 b\n"
                 "@@ hunk 2 @@\n+line 2 a\n-line 2 b\n"
                 "b.txt\n@@ hunk 3 @@\n+line 3 a\n-line 3 b\n"
                 "Untracked files\nc.txt\n")
  (text))
(test-assert "headings are bold, segment faces win"
             (and (eq? (get-text-property 0 'face) 'section-heading)
                  (eq? (get-text-property 16 'face) 'italic)))

(define s0 (car (sections)))
(test-eqv "a section knows its range" 0 (section-start s0))
(test-eq "section-at finds the innermost section" 'hunk
         (begin (goto-char (+ (string-length "Staged changes (2)\na.txt\n@@ hunk 1 @@\n") 3))
                (section-kind (section-at-point))))
(test-equal "and its id and value" '((hunk 1) 1) (let ([s (section-at-point)]) (list (section-id s) (section-value s))))
(test-eq "the parent chain" 'file (section-kind (section-parent (section-at-point))))

;; ---- movement ----
(goto-char 0)
(keys "n")
(test-equal "n: next section" "a.txt" (line-at))
(keys "n")
(test-equal "n again: into the hunk" "@@ hunk 1 @@" (line-at))
(keys "n")
(test-equal "n: the next hunk" "@@ hunk 2 @@" (line-at))
(keys "p")
(test-equal "p: back" "@@ hunk 1 @@" (line-at))
(keys "M-n")
(test-equal "M-n: next sibling" "@@ hunk 2 @@" (line-at))
(keys "M-p")
(test-equal "M-p: previous sibling" "@@ hunk 1 @@" (line-at))
(keys "^")
(test-equal "^: parent" "a.txt" (line-at))
(keys "M-n")
(test-equal "M-n between files" "b.txt" (line-at))
(goto-char (+ (section-start (cadr (section-children (car (sections))))) 3)) ; inside b.txt heading
(keys "p")
(test-equal "p from inside a heading goes to its start" "b.txt" (line-at))
(goto-char (point-max))
(test-assert "n at the end is an error" (guard (e [#t #t]) (section-forward) #f))

;; ---- folding ----
(goto-char 0)
(keys "n")                       ; a.txt
(keys "TAB")
(test-assert "TAB folds a file: its hunks go" (not (string-search* (text) "hunk 1")))
(test-equal "point stays on the heading" "a.txt" (line-at))
(keys "n")
(test-equal "n skips folded content" "b.txt" (line-at))
(keys "p" "TAB")
(test-assert "TAB again unfolds" (string-search* (text) "hunk 1"))

;; Point inside a hunk's body: folding the file puts point on the file heading.
(goto-char (+ (section-start (hunk-section 1)) 15))
(keys "^" "TAB")
(test-equal "folding from the heading, then" "a.txt" (line-at))
(keys "TAB")

;; S-TAB: fold everything below the top, then unfold
(keys "<backtab>")
(test-equal "S-TAB folds every nested section"
            "Staged changes (2)\na.txt\nb.txt\nUntracked files\nc.txt\n" (text))
(keys "<backtab>")
(test-assert "and unfolds them" (string-search* (text) "+line 3 a"))

;; ---- refresh keeps folds and point ----
(goto-char 0)
(keys "n" "TAB")                 ; fold a.txt
(goto-char (section-start (section-find (sections) '(hunk 3))))
(forward-line 1)                  ; "+line 3 a"
(section-refresh! (tree))
(test-equal "refresh: point on the same line of the same hunk" "+line 3 a" (line-at))
(test-assert "refresh: a.txt is still folded" (not (string-search* (text) "hunk 1")))

;; the hunk disappears: point moves to the nearest surviving ancestor
(section-refresh!
 (list (new-section 'staged 'staged "Staged changes" '()
                    (list (file "b.txt" '())) #f #f)))
(test-equal "refresh: point falls back to the parent" "b.txt" (line-at))

;; ids that are new use their own default fold, and a user fold survives
(define (tree-with-folded-default)
  (list (new-section 'staged 'staged "Staged" '() (list (new-section 'file '(file "n") "n.txt" '("body") '() #t #f)) #f #f)))
(render-sections! (tree-with-folded-default))
(test-assert "a section folded by default is folded" (not (string-search* (text) "body")))
(keys "n" "TAB")
(test-assert "the user unfolds it" (string-search* (text) "body"))
(section-refresh! (tree-with-folded-default))
(test-assert "and it stays unfolded over a refresh" (string-search* (text) "body"))

;; g calls the refresh function
(define refreshed 0)
(var-set! 'section-refresh-function (lambda () (set! refreshed (+ refreshed 1))))
(keys "g")
(test-eqv "g runs section-refresh-function" 1 refreshed)

(delete-headless-frame! f)
(test-end "section")
(test-exit)
