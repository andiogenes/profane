(import (chezscheme) (srfi :64) (profane buffer) (profane command) (profane command-loop)
        (profane async) (profane var) (profane git))

(test-begin "git")

(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))
(define (sh fmt . args) (system (apply format fmt args)))

(define dir (let ([p (format "/tmp/pf-git-~a" (random 1000000000))]) (sh "rm -rf ~a ~a-remote.git; mkdir -p ~a" p p p) p))
(define remote (string-append dir "-remote.git"))
(define (git . args) (sh "cd ~a && git -c user.email=t@t -c user.name=t ~a >/dev/null 2>&1" dir
                         (apply string-append (map (lambda (a) (format "'~a' " a)) args))))

(sh "git init -q --bare ~a" remote)
(sh "cd ~a && git init -q -b main && git remote add origin ~a" dir remote)
(sh "cd ~a && printf 'one\\ntwo\\nthree\\nfour\\nfive\\nsix\\nseven\\neight\\nnine\\nten\\n' > a.txt && printf 'x\\n' > b.txt && printf 'y\\n' > \"sp ace.txt\"" dir)
(git "add" "-A")
(git "commit" "-m" "init")
(git "push" "-u" "origin" "main")

(test-equal "git-root finds the repository from inside it" dir (git-root dir))
(sh "mkdir -p ~a/sub/deeper" dir)
(test-equal "and from a subdirectory" dir (git-root (string-append dir "/sub/deeper/")))
(test-eq "outside any repository: #f" #f (git-root "/tmp/pf-no-such-dir-xyz"))

;; ---- run-git ----
(let ([r (await (run-git dir '("rev-parse" "--abbrev-ref" "HEAD")))])
  (test-equal "run-git: code and output" '(0 "main\n") (list (car r) (cadr r))))
(let ([r (await (run-git dir '("no-such-command")))])
  (test-assert "failure: nonzero code, message on stderr" (and (not (zero? (car r))) (contains? (caddr r) "not a git command"))))
(let ([log (with-current-buffer (git-process-buffer) (buffer-substring 0 (buffer-size)))])
  (test-assert "commands and results are logged" (and (contains? log "$ git rev-parse") (contains? log "[exit 0,") (contains? log "[exit 1") )))
(let ([r (await (run-git dir '("commit" "--allow-empty")))])
  (test-assert "an editor is never opened (GIT_EDITOR=true aborts an empty message)" (not (zero? (car r)))))

;; ---- status ----
(let ([st (git-status dir)])
  (test-equal "clean: branch" "main" (git-status-head st))
  (test-equal "upstream" "origin/main" (git-status-upstream st))
  (test-equal "ahead and behind" '(0 0) (list (git-status-ahead st) (git-status-behind st)))
  (test-equal "no changes" '() (git-status-changes st)))

(sh "cd ~a && sed -i '' 's/^two$/TWO/' a.txt && printf 'new\\n' > c.txt && printf 'z\\n' >> b.txt" dir)
(git "add" "b.txt")
(sh "cd ~a && printf 'more\\n' >> b.txt && mv \"sp ace.txt\" \"sp ace2.txt\"" dir)
(git "add" "-N" "sp ace2.txt")
(sh "cd ~a && printf 'o\\n' > \"new file.txt\"" dir)
(let* ([st (git-status dir)]
       [paths (lambda (cs) (sort string<? (map git-change-path cs)))])
  (test-equal "unstaged (the renamed file under its new name)" '("a.txt" "b.txt" "sp ace2.txt") (paths (git-status-unstaged st)))
  (test-equal "a rename in the tree keeps its original path, spaces and all" "sp ace.txt"
              (git-change-orig (find (lambda (c) (string=? (git-change-path c) "sp ace2.txt")) (git-status-changes st))))
  (test-equal "staged" '("b.txt") (paths (git-status-staged st)))
  (test-equal "untracked, with spaces in a name" '("c.txt" "new file.txt") (paths (git-status-untracked st)))
  (let ([b (find (lambda (c) (string=? (git-change-path c) "b.txt")) (git-status-changes st))])
    (test-equal "b.txt is modified in the index and the tree" '(#\M #\M)
                (list (git-change-index b) (git-change-worktree b)))))

;; commits ahead and behind
(git "add" "-A")
(git "commit" "-m" "second")
(let ([st (git-status dir)])
  (test-equal "one commit ahead" '(1 0) (list (git-status-ahead st) (git-status-behind st))))

;; a rename shows its original path
(sh "cd ~a && git mv a.txt renamed.txt" dir)
(let* ([st (git-status dir)] [c (car (git-status-staged st))])
  (test-equal "rename: new path and original" '("renamed.txt" "a.txt") (list (git-change-path c) (git-change-orig c))))
(git "commit" "-m" "rename")

;; detached head
(git "checkout" "--detach")
(test-eq "detached: no branch name" #f (git-status-head (git-status dir)))
(git "checkout" "main")

;; ---- diff ----
(sh "cd ~a && sed -i '' 's/^one$/ONE/; s/^ten$/TEN/' renamed.txt" dir)
(let* ([files (git-diff dir #f)] [f (car files)])
  (test-equal "one file changed" '("renamed.txt") (map git-diff-file-path files))
  (test-eqv "two hunks (changes far apart)" 2 (length (git-diff-file-hunks f)))
  (let ([h (car (git-diff-file-hunks f))])
    (test-equal "hunk range" '(1 4 1 4)
                (list (git-diff-hunk-old-start h) (git-diff-hunk-old-len h)
                      (git-diff-hunk-new-start h) (git-diff-hunk-new-len h)))
    (test-assert "hunk lines keep their prefixes" (and (member "-one" (git-diff-hunk-lines h)) (member "+ONE" (git-diff-hunk-lines h)) (member " TWO" (git-diff-hunk-lines h))))
    (test-assert "header line" (contains? (git-diff-hunk-header h) "@@ -1,4 +1,4 @@")))
  (test-assert "file header holds the diff line and the ---/+++ lines"
               (let ([hd (git-diff-file-header f)])
                 (and (contains? (car hd) "diff --git") (member "--- a/renamed.txt" hd) (member "+++ b/renamed.txt" hd)))))
(test-equal "staged diff is empty so far" '() (git-diff dir #t))
(git "add" "renamed.txt")
(test-eqv "staged diff has it" 1 (length (git-diff dir #t)))
(test-equal "and a path filter limits it" '() (git-diff dir #t '("b.txt")))

;; new, deleted, binary, no-newline, mode
(sh "cd ~a && printf 'n\\n' > added.txt && git add added.txt && git rm -q b.txt && printf 'a\\000b' > bin.dat && git add bin.dat" dir)
(let ([files (git-diff dir #t)])
  (test-equal "new and deleted files get their paths"
              '("added.txt" "b.txt" "bin.dat" "renamed.txt")
              (sort string<? (map git-diff-file-path files)))
  (test-assert "binary files have no hunks and are flagged"
               (let ([b (find (lambda (f) (string=? (git-diff-file-path f) "bin.dat")) files)])
                 (and (git-diff-file-binary? b) (null? (git-diff-file-hunks b))))))
(git "commit" "-m" "third")
(sh "cd ~a && printf 'no newline' > nonl.txt && git add nonl.txt && git commit -q -m x >/dev/null 2>&1; printf 'changed' > nonl.txt" dir)
(let* ([f (car (git-diff dir #f))] [h (car (git-diff-file-hunks f))])
  (test-assert "\"\\ No newline\" lines are kept" (member "\\ No newline at end of file" (git-diff-hunk-lines h))))

;; ---- word-level refinement ----
(let-values ([(o n) (git-word-diff "let x = foo(a, b);" "let x = bar(a, b, c);")])
  (test-equal "word diff: the changed word on the old side" '((8 . 11)) o)
  (test-equal "and the changed word and the insertion on the new side" '((8 . 11) (16 . 19)) n))
(let-values ([(o n) (git-word-diff "abc" "xyz")])
  (test-equal "texts with nothing in common are not refined" '(() ()) (list o n)))
(let-values ([(o n) (git-word-diff "same line" "same line")])
  (test-equal "equal texts have no changes" '(() ()) (list o n)))
(test-equal "refining a hunk: one removed line against one added"
            '(() ((5 . 8)) ((5 . 6)) ())
            (git-refine-lines '(" ctx" "-one two three" "+one 2 three" " end")))
(test-equal "blocks of equal size are compared line by line"
            '(((3 . 4)) ((3 . 4)) ((3 . 4)) ((3 . 4)))
            (git-refine-lines '("-a b" "-c d" "+a B" "+c D")))
(test-equal "blocks of different sizes are compared as a whole"
            '(() ((6 . 8)))
            (git-refine-lines '("-a b c" "+a b c d")))
(test-equal "added or removed lines alone have nothing to compare" '(() ())
            (git-refine-lines '("+only added" "+two")))
(let ([r (git-refine-lines '("-foo bar" "-baz qux" "+foo BAR baz qux"))])
  (test-equal "a whole-block comparison clips ranges to their lines: bar, not the next line" '((5 . 8)) (car r))
  (test-equal "and leaves unchanged lines alone" '() (cadr r))
  (test-assert "the added line has the changed word" (and (find (lambda (rg) (and (<= (car rg) 5) (>= (cdr rg) 8))) (caddr r)) #t)))

;; ---- patches: stage and unstage hunks and lines ----
(sh "cd ~a && git reset -q --hard && printf 'a\\nb\\nc\\nd\\ne\\nf\\ng\\nh\\ni\\nj\\nk\\nl\\n' > p.txt && git add p.txt && git -c user.email=t@t -c user.name=t commit -q -m p && sed -i '' 's/^b$/B/; s/^c$/C/; s/^l$/L/' p.txt" dir)
(define (staged-diff) (cadr (await (run-git dir '("diff" "--cached" "-U0")))))
(define (unstaged-diff) (cadr (await (run-git dir '("diff" "-U0")))))
(let* ([f (car (git-diff dir #f))] [hunks (git-diff-file-hunks f)])
  (test-eqv "two hunks in p.txt" 2 (length hunks))
  ;; the first hunk is a,B,C,d..: lines: " a" "-b" "-c" "+B" "+C" " d" ...
  (let ([first (car hunks)])
    (test-assert "the whole-hunk patch applies to the index"
                 (zero? (car (await (git-apply-patch dir (git-hunk-patch f first) '("--cached"))))))
    (test-assert "that hunk is staged and the other is not"
                 (and (contains? (staged-diff) "+B") (not (contains? (staged-diff) "+L"))
                      (contains? (unstaged-diff) "+L") (not (contains? (unstaged-diff) "+B"))))
    ;; unstage it again, as a whole hunk
    (let* ([sf (car (git-diff dir #t))] [sh1 (car (git-diff-file-hunks sf))])
      (test-assert "reverse-applying the staged hunk unstages it"
                   (zero? (car (await (git-apply-patch dir (git-hunk-patch sf sh1) '("--cached" "-R"))))))
      (test-equal "nothing staged" "" (staged-diff))))
  ;; one line of a hunk: stage only "-b"/"+B"
  (let* ([first (car (git-diff-file-hunks f))]
         [lines (git-diff-hunk-lines first)]
         [idx (lambda (s) (let loop ([l lines] [i 0]) (cond [(null? l) #f] [(string=? (car l) s) i] [else (loop (cdr l) (+ i 1))])))])
    (test-eq "no change in the range: no patch" #f (git-hunk-region-patch f first 0 1 #f))
    (let ([patch (git-hunk-region-patch f first (idx "-b") (+ (idx "-b") 1) #f)])
      (test-assert "the partial patch keeps the selected -b, turns -c into context, drops +B and +C"
                   (and (contains? patch "-b\n") (contains? patch " c\n")
                        (not (contains? patch "+B")) (not (contains? patch "+C")) (not (contains? patch "-c\n"))))
      (test-assert "its counts add up" (contains? patch "@@ -1,6 +1,5 @@"))
      (test-assert "it applies" (zero? (car (await (git-apply-patch dir patch '("--cached"))))))
      (test-assert "only that removal is staged" (and (contains? (staged-diff) "-b") (not (contains? (staged-diff) "-c"))
                                                       (not (contains? (staged-diff) "+B")))))
    ;; additions: stage "+C" alone (an addition whose removal is not staged)
    (let ([patch (git-hunk-region-patch f first (idx "+C") (+ (idx "+C") 1) #f)])
      (test-assert "a lone addition: removals become context, other additions drop"
                   (and (contains? patch "+C\n") (contains? patch " b\n") (contains? patch " c\n")
                        (not (contains? patch "+B")) (not (contains? patch "-b")))))
    ;; unstage just "+B/-b" again from the staged diff, as a region
    (let* ([sf (car (git-diff dir #t))] [sh1 (car (git-diff-file-hunks sf))]
           [patch (git-hunk-region-patch sf sh1 0 (length (git-diff-hunk-lines sh1)) #t)])
      (test-assert "the whole staged hunk as a region, reversed, unstages it"
                   (zero? (car (await (git-apply-patch dir patch '("--cached" "-R"))))))
      (test-equal "index is clean again" "" (staged-diff))))
  ;; discard one line in the worktree: reverse-apply "+C" only
  (let* ([f2 (car (git-diff dir #f))] [h (car (git-diff-file-hunks f2))]
         [lines (git-diff-hunk-lines h)]
         [i (let loop ([l lines] [i 0]) (if (string=? (car l) "+C") i (loop (cdr l) (+ i 1))))]
         [patch (git-hunk-region-patch f2 h i (+ i 1) #t)])
    (test-assert "a worktree line is discarded with -R"
                 (zero? (car (await (git-apply-patch dir patch '("-R"))))))
    (test-assert "+C is gone, +B stays" (and (not (contains? (unstaged-diff) "+C")) (contains? (unstaged-diff) "+B")))))
(let ([f (car (git-diff dir #f))])
  (test-equal "a bad patch fails with git's message" #t
              (let ([r (await (git-apply-patch dir "diff --git a/zzz b/zzz\n--- a/zzz\n+++ b/zzz\n@@ -1 +1 @@\n-x\n+y\n" '("--cached")))])
                (and (not (zero? (car r))) (> (string-length (caddr r)) 0)))))
(sh "cd ~a && git checkout -q -- ." dir)

;; ---- log ----
(let ([commits (git-log dir #f 3)])
  (test-eqv "log: newest first, limited" 3 (length commits))
  (test-equal "log: subject of the newest" "p" (git-commit-subject (car commits)))
  (test-assert "log: hashes" (and (= 40 (string-length (git-commit-hash (car commits))))
                                  (< (string-length (git-commit-short (car commits))) 40)))
  (test-assert "log: refs on the head commit" (contains? (git-commit-refs (car commits)) "main"))
  (test-assert "log: author and date" (and (> (string-length (git-commit-author (car commits))) 0)
                                           (> (string-length (git-commit-date (car commits))) 0))))
(test-equal "log: a range" '("p" "x" "third" "rename" "second") (map git-commit-subject (git-log dir "origin/main..HEAD" 10)))
(test-equal "log: a bad range is empty" '() (git-log dir "no-such-ref..HEAD" 10))

;; ---- backends ----
(test-equal "the cli backend is registered" '(cli) (git-backend-names))
(define-git-backend! 'fake (list (cons 'status (lambda (root) 'fake-status)) (cons 'diff (lambda (root s p) '())) (cons 'log (lambda (r a l) '()))))
(var-set! 'git-read-backend 'fake)
(test-eq "a selected backend answers" 'fake-status (git-status dir))
(var-set! 'git-read-backend 'nothing)
(test-assert "an unknown backend is an error" (guard (e [#t #t]) (git-status dir) #f))
(var-set! 'git-read-backend 'cli)

(sh "rm -rf ~a ~a" dir remote)
(test-end "git")
(test-exit)
