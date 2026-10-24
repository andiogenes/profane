(import (chezscheme) (srfi :64) (profane buffer) (profane keymap) (profane command)
        (profane command-loop) (profane async) (profane mode) (profane var) (profane window) (profane display)
        (profane themes) (profane files) (profane simple) (profane section) (profane git)
        (profane git status))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane files) (profane section) (profane git) (profane git status)))

(test-begin "git-status")

;; Commands that wait for git park; pump the event queue until they are done.
(define (settle!)
  (let loop ([n 0])
    (when (and (command-busy?) (< n 2000))
      (async-poll! 5)
      (resume-busy!)
      (loop (+ n 1)))))
(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k)) (settle!)) ks))
(define (text) (buffer-substring 0 (buffer-size)))
(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))
(define (line-at) (buffer-substring (line-beginning-position) (line-end-position)))
(define (sh fmt . args) (system (apply format fmt args)))

(define dir (let ([p (format "/tmp/pf-gst-~a" (random 1000000000))])
              (sh "rm -rf ~a ~a.git ~a-other; mkdir -p ~a" p p p p)
              p))
(define remote (string-append dir "-remote.git"))
(sh "rm -rf ~a" remote)
(define (git . args) (sh "cd ~a && git -c user.email=t@t -c user.name=t ~a >/dev/null 2>&1" dir
                         (apply string-append (map (lambda (a) (format "'~a' " a)) args))))
(sh "git init -q --bare ~a" remote)
(sh "cd ~a && git init -q -b main && git remote add origin ~a" dir remote)
(sh "cd ~a && printf 'one\\ntwo\\nthree\\nfour\\nfive\\nsix\\nseven\\neight\\nnine\\nten\\n' > a.txt && printf 'x\\n' > b.txt" dir)
(git "add" "-A")
(git "commit" "-m" "first")
(git "push" "-u" "origin" "main")
(sh "cd ~a && printf 'more\\n' >> b.txt" dir)
(git "commit" "-am" "local work")

(define f (select-frame (make-headless-frame 800 600)))
(define scratch (current-buffer))
(var-set! 'default-directory (string-append dir "/"))

;; ---- a clean tree ----
(keys "C-x g")
(define b (current-buffer))
(test-assert "C-x g makes a status buffer" (contains? (buffer-name b) "magit: pf-gst-"))
(test-eq "in git-status-mode" 'git-status-mode (var-ref 'major-mode))
(test-assert "read-only" (with-current-buffer b (buffer-read-only?)))
(test-assert "head and upstream lines"
             (and (contains? (text) "Head:     main  local work")
                  (contains? (text) "Upstream: origin/main  first")))
(test-assert "the unpushed commit, with its count" (contains? (text) "Unmerged into origin/main (1)"))
(test-assert "recent commits" (and (contains? (text) "Recent commits (2)") (contains? (text) "  first")))
(test-assert "no empty sections" (not (or (contains? (text) "Unstaged") (contains? (text) "Staged") (contains? (text) "Untracked"))))
(test-assert "a blank line separates the top sections" (contains? (text) "first\n\nUnmerged"))

;; ---- changes ----
(sh "cd ~a && sed -i '' 's/^one$/ONE/; s/^ten$/TEN/' a.txt && printf 'new\\n' > c.txt && printf 'ins\\n' >> b.txt" dir)
(git "add" "b.txt")
(sh "cd ~a && printf 'more\\n' >> b.txt" dir)
(keys "g")
(test-assert "unstaged changes with a count" (contains? (text) "Unstaged changes (2)"))
(test-assert "a file heading with its status word" (contains? (text) "modified   a.txt"))
(test-assert "hunks with their headers"
             (and (contains? (text) "@@ -1,4 +1,4 @@") (contains? (text) "@@ -7,4 +7,4 @@")))
(test-assert "removed and added lines" (and (contains? (text) "-one\n+ONE\n") (contains? (text) "-ten\n+TEN\n")))
(test-assert "staged changes" (and (contains? (text) "Staged changes (1)") (contains? (text) "+ins")))
(test-assert "untracked files" (and (contains? (text) "Untracked files (1)") (contains? (text) "\nc.txt\n")))

;; faces
(define (face-at-line-start prefix)
  (let loop ([i 0])
    (cond [(> (+ i (string-length prefix)) (buffer-size)) #f]
          [(string=? (buffer-substring i (+ i (string-length prefix))) prefix) (get-text-property i 'face)]
          [else (loop (+ i 1))])))
(test-eq "added lines" 'git-diff-added (face-at-line-start "+ONE"))
(test-eq "removed lines" 'git-diff-removed (face-at-line-start "-one"))
(test-eq "hunk headings" 'git-diff-hunk-heading (face-at-line-start "@@ -1,4"))
(test-eq "file headings" 'git-diff-file-heading (face-at-line-start "modified   a.txt"))
(test-eq "branch names" 'git-branch-local (face-at-line-start "main  local"))

;; section values
(define (find-kind kind area)
  (let ([found #f])
    (section-walk (sections) (lambda (s) (let ([v (section-value s)])
                                           (when (and (not found) v (git-item? v) (eq? (git-item-kind v) kind) (eq? (git-item-area v) area))
                                             (set! found s)))))
    found))
(let* ([hunk (find-kind 'hunk 'unstaged)] [item (section-value hunk)])
  (test-equal "a hunk section carries its file and hunk" '("a.txt" "@@ -1,4 +1,4 @@")
              (list (git-item-path item) (substring (git-diff-hunk-header (git-item-hunk item)) 0 15)))
  (test-equal "and the change" #\M (git-change-worktree (git-item-change item))))

;; ---- folding and refresh keep their place ----
(goto-char (section-start (find-kind 'file 'unstaged)))
(keys "TAB")
(test-assert "TAB folds a file" (not (contains? (text) "-one")))
(goto-char (section-start (find-kind 'file 'staged)))
(keys "g")
(test-equal "refresh keeps point on the same file" "modified   b.txt" (line-at))
(test-assert "and the fold" (not (contains? (text) "-one")))

;; ---- visiting ----
(goto-char (section-start (find-kind (quote file) (quote unstaged))))
(keys "TAB")                                   ; unfold a.txt again so its hunks show
(let ([hunk (find-kind 'hunk 'unstaged)])
  (goto-char (section-start hunk))
  (forward-line 3)                              ; a line inside the hunk
  (keys "RET")
  (test-assert "RET visits the file" (equal? (buffer-name (current-buffer)) "a.txt"))
  (test-assert "at the line in the hunk" (>= (line-number-at-pos (point)) 1)))
(switch-to-buffer b)
(goto-char (section-start (find-kind 'untracked 'untracked)))
(keys "RET")
(test-equal "RET on an untracked file visits it" "c.txt" (buffer-name (current-buffer)))
(switch-to-buffer b)

;; ---- unpulled commits and folding of big diffs ----
(sh "cd ~a && git clone -q ~a ~a-other && cd ~a-other && printf 'r\\n' > r.txt && git add r.txt && git -c user.email=t@t -c user.name=t commit -q -m 'remote work' && git push -q origin main" dir remote dir dir)
(git "fetch")
(keys "g")
(test-assert "unpulled commits" (and (contains? (text) "Unpulled from origin/main (1)") (contains? (text) "remote work")))
(var-set! 'git-status-diff-line-limit 2)
(switch-to-buffer scratch)
(kill-buffer b)                                ; remembered folds would win over the default
(keys "C-x g")
(set! b (current-buffer))
(test-assert "when the diff is big, files start folded" (and (contains? (text) "modified   a.txt") (not (contains? (text) "-one"))))
(var-set! 'git-status-diff-line-limit 3000)

;; reusing the buffer
(switch-to-buffer scratch)
(keys "C-x g")
(test-eq "C-x g again reuses the buffer" b (current-buffer))

;; outside a repository
(switch-to-buffer scratch)
(var-set! 'default-directory "/tmp/")
(keys "C-x g")
(test-eq "not in a repository: stays put" scratch (current-buffer))

(sh "rm -rf ~a ~a ~a-other" dir remote dir)
(delete-headless-frame! f)
(test-end "git-status")
(test-exit)
