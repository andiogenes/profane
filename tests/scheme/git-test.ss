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

;; ---- log ----
(let ([commits (git-log dir #f 3)])
  (test-eqv "log: newest first, limited" 3 (length commits))
  (test-equal "log: subject of the newest" "x" (git-commit-subject (car commits)))
  (test-assert "log: hashes" (and (= 40 (string-length (git-commit-hash (car commits))))
                                  (< (string-length (git-commit-short (car commits))) 40)))
  (test-assert "log: refs on the head commit" (contains? (git-commit-refs (car commits)) "main"))
  (test-assert "log: author and date" (and (> (string-length (git-commit-author (car commits))) 0)
                                           (> (string-length (git-commit-date (car commits))) 0))))
(test-equal "log: a range" '("x" "third" "rename" "second") (map git-commit-subject (git-log dir "origin/main..HEAD" 10)))
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
