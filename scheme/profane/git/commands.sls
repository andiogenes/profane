;;; (profane git commands) — committing, branches and the remote: the transients and commands the
;;; status buffer binds to c, b, P, F and f. Unstable API (plan §10, §8m).
;;;
;;; c opens the commit menu: c commits what is staged (-a: everything tracked), e extends the last
;;; commit with it without changing the message, a amends with a new message, w only rewords. A
;;; message is written in the *git-commit* buffer, with the staged diff beside it; C-c C-c commits
;;; (`git commit -F`, lines starting with # are dropped, an empty message is refused), C-c C-k
;;; gives up. b: checkout, create (and checkout), delete, rename branches. P pushes (to the
;;; upstream, or sets it on the first push), F pulls, f fetches. All of them show git's own answer
;;; in the echo area and the whole output in *git-process*. Passwords: git's credential helper
;;; and ssh-agent; there is no prompt (a command that needs one fails and says so).

(library (profane git commands)
  (export git-diff-text-insert!)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane keymap) (profane mode) (profane var) (profane face) (profane display)
          (profane files) (profane minibuffer) (profane async) (profane transient)
          (profane git) (profane git status) (profane simple))

  (define git-command-faces
    (begin
      (define-face 'git-commit-comment '() "Comment lines in the commit message buffer.")
      #t))

  (defvar git-commit-root #f "The repository a commit message is for." '(local))
  (defvar git-commit-flags '() "The arguments the commit will run with." '(local))
  (defvar git-commit-return #f "The buffer to go back to when the commit is done." '(local))
  (defvar git-commit-diff-buffer #f "The buffer showing the changes being committed." '(local))

  (define-major-mode git-commit-mode fundamental-mode "Commit" "Major mode for writing a commit message.")
  (define-major-mode git-commit-diff-mode fundamental-mode "Diff" "Major mode of the changes shown beside a commit message.")

  ;; ---- helpers ----

  (define (split-lines s)
    (let loop ([i 0] [start 0] [out '()])
      (cond [(= i (string-length s)) (reverse (if (> i start) (cons (substring s start i) out) out))]
            [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s start i) out))]
            [else (loop (+ i 1) start out)])))

  (define (blank? s) (let loop ([i 0]) (or (= i (string-length s)) (and (char-whitespace? (string-ref s i)) (loop (+ i 1))))))

  (define (first-line s) (let ([ls (split-lines s)]) (if (null? ls) "" (car ls))))

  ;; The last line of git's answer that says something: what it printed, else what it complained
  ;; about.
  (define (last-line s)
    (let ([ls (filter (lambda (l) (not (blank? l))) (split-lines s))])
      (if (null? ls) #f (car (reverse ls)))))

  (define (repo-root)
    (or (var-ref 'git-repo-root)
        (git-root (default-directory))
        (error 'git "not inside a git repository")))

  (define (flags-from-args)
    (append (if (transient-arg 'all) '("--all") '())
            (if (transient-arg 'allow-empty) '("--allow-empty") '())
            (if (transient-arg 'signoff) '("--signoff") '())
            (if (transient-arg 'no-verify) '("--no-verify") '())))

  (define (report! root what result)
    (git-refresh-status-buffers! root)
    (if (zero? (car result))
        (message "~a" (or (last-line (caddr result)) (last-line (cadr result)) (string-append what ": done")))
        (message "git: ~a" (or (last-line (caddr result)) (last-line (cadr result)) (string-append what " failed")))))

  ;; Inserts diff text at the end of the current buffer, coloring its lines.
  (define (git-diff-text-insert! text)
    (for-each
     (lambda (line)
       (let ([from (point)] [c (if (string=? line "") #\space (string-ref line 0))])
         (insert line "\n")
         (cond [(or (string-prefix? "diff --git" line) (string-prefix? "+++ " line) (string-prefix? "--- " line)
                    (string-prefix? "index " line))
                (put-text-property from (- (point) 1) 'face 'git-diff-file-heading)]
               [(string-prefix? "@@" line) (put-text-property from (- (point) 1) 'face 'git-diff-hunk-heading)]
               [(char=? c #\+) (put-text-property from (- (point) 1) 'face 'git-diff-added)]
               [(char=? c #\-) (put-text-property from (- (point) 1) 'face 'git-diff-removed)])))
     (split-lines text)))

  (define (string-prefix? p s)
    (and (<= (string-length p) (string-length s)) (string=? p (substring s 0 (string-length p)))))

  ;; ---- committing ----

  (define (commit-comment-block root st all?)
    (string-append
     "\n# Please enter the commit message for your changes. Lines starting\n"
     "# with '#' will be ignored, and an empty message aborts the commit.\n#\n"
     (if (git-status-head st) (format "# On branch ~a\n" (git-status-head st)) "# Not on any branch\n")
     (let ([changes (if all?
                        (filter (lambda (c) (not (char=? (git-change-index c) #\.)))
                                (git-status-staged st))
                        (git-status-staged st))]
           [all-changes (if all? (git-status-unstaged st) '())])
       (string-append
        "# Changes to be committed:\n"
        (apply string-append
               (map (lambda (c) (format "#\t~a\n" (git-change-path c))) (append changes all-changes)))))))

  (define (diff-text root all? amend?)
    (let* ([args (cond [all? '("diff" "--no-color" "HEAD")]
                       [amend? '("diff" "--no-color" "--cached" "HEAD^")]
                       [else '("diff" "--no-color" "--cached")])]
           [r (await (run-git root args))])
      (if (zero? (car r))
          (cadr r)
          (cadr (await (run-git root '("diff" "--no-color" "--cached")))))))

  (define (start-commit! kind flags)
    (let* ([root (repo-root)] [return (current-buffer)]
           [amend? (memq kind '(amend reword))]
           [all? (and (member "--all" flags) #t)]
           [st (git-status root)]
           [checked (when (and (not amend?) (not all?) (null? (git-status-staged st))
                               (not (member "--allow-empty" flags)))
                      (error 'magit-commit "nothing staged (use -a to commit everything, or stage something)"))]
           [initial (if amend?
                        (let ([r (await (run-git root '("log" "-1" "--format=%B")))])
                          (if (zero? (car r)) (let loop ([s (cadr r)]) (if (and (> (string-length s) 0) (char-whitespace? (string-ref s (- (string-length s) 1)))) (loop (substring s 0 (- (string-length s) 1))) s)) ""))
                        "")]
           [diff (diff-text root all? amend?)]
           [mb (get-buffer-create "*git-commit*")]
           [db (get-buffer-create "*git-commit-diff*")])
      (with-current-buffer db
        (set-major-mode! 'git-commit-diff-mode)
        (set-buffer-read-only! #f)
        (erase-buffer)
        (git-diff-text-insert! diff)
        (goto-char (point-min))
        (set-buffer-read-only! #t)
        (buffer-disable-undo))
      (with-current-buffer mb
        (set-major-mode! 'git-commit-mode)
        (erase-buffer)
        (insert initial)
        (let ([comment-start (+ (point) 1)])
          (insert (commit-comment-block root st all?))
          (put-text-property comment-start (point) 'face 'git-commit-comment))
        (var-set! 'git-commit-root root)
        (var-set! 'git-commit-flags (append (if amend? '("--amend") '()) flags))
        (var-set! 'git-commit-return return)
        (var-set! 'git-commit-diff-buffer db)
        (var-set! 'default-directory (string-append root "/"))
        (goto-char (min (string-length initial) (buffer-size)))
        (set-buffer-unmodified!))
      (switch-to-buffer mb)
      (display-buffer-in-other-window db)
      (message "Write the commit message, then C-c C-c to commit or C-c C-k to cancel")))

  (define (finish-up! root mb db return)
    (for-each (lambda (b) (when (buffer-live? b)
                            (for-each (lambda (w) (when (> (length (window-list)) 1) (delete-window w)))
                                      (filter (lambda (w) (eq? (window-buffer w) b)) (window-list)))))
              (list db))
    (when (buffer-live? mb) (kill-buffer mb))
    (when (buffer-live? db) (kill-buffer db))
    (when (and return (buffer-live? return)) (switch-to-buffer return)))

  (define-command (git-commit-finish)
    "Commit with the message in this buffer."
    (let* ([mb (current-buffer)]
           [text (buffer-substring (point-min) (point-max))]
           [root (var-ref 'git-commit-root)] [flags (var-ref 'git-commit-flags)]
           [db (var-ref 'git-commit-diff-buffer)] [return (var-ref 'git-commit-return)])
      (unless root (error 'git-commit-finish "not a commit message buffer"))
      (when (for-all (lambda (l) (or (blank? l) (string-prefix? "#" l))) (split-lines text))
        (error 'git-commit-finish "aborting commit due to empty message"))
      (let* ([file (git-write-temp-file text)]
             [r (await (run-git root (append '("commit") flags (list "--cleanup=strip" "-F" file))))])
        (guard (e [#t #t]) (delete-file file))
        (cond
         [(zero? (car r))
          (finish-up! root mb db return)
          (report! root "commit" r)]
         [else (report! root "commit" r)]))))

  (define-command (git-commit-cancel)
    "Give up on this commit."
    (let ([mb (current-buffer)] [db (var-ref 'git-commit-diff-buffer)] [return (var-ref 'git-commit-return)]
          [root (var-ref 'git-commit-root)])
      (finish-up! root mb db return)
      (message "Commit canceled")))

  (define-command (magit-commit-create) "Commit the staged changes." (start-commit! 'create (flags-from-args)))
  (define-command (magit-commit-amend) "Amend the last commit, editing its message." (start-commit! 'amend (flags-from-args)))
  (define-command (magit-commit-reword) "Change the last commit's message only." (start-commit! 'reword (cons "--only" (flags-from-args))))
  (define-command (magit-commit-extend)
    "Add the staged changes to the last commit, keeping its message."
    (let ([root (repo-root)] [flags (flags-from-args)])
      (report! root "commit" (await (run-git root (append '("commit" "--amend" "--no-edit") flags))))))

  (define-transient (magit-commit)
    "Commit"
    ("Arguments"
     (switch "- a" "--all" all)
     (switch "- e" "--allow-empty" allow-empty)
     (switch "- s" "--signoff" signoff)
     (switch "- n" "--no-verify" no-verify))
    ("Create" (action "c" "Commit" magit-commit-create))
    ("Edit HEAD"
     (action "e" "Extend" magit-commit-extend)
     (action "a" "Amend" magit-commit-amend)
     (action "w" "Reword" magit-commit-reword)))

  ;; ---- branches ----

  (define (branch-names root kinds)
    (let ([r (await (run-git root (append '("for-each-ref" "--format=%(refname:short)") kinds)))])
      (filter (lambda (n) (and (not (blank? n)) (not (string-suffix? "/HEAD" n)))) (split-lines (cadr r)))))

  (define (string-suffix? suf s)
    (and (<= (string-length suf) (string-length s))
         (string=? suf (substring s (- (string-length s) (string-length suf)) (string-length s)))))

  (define-command (magit-branch-checkout)
    "Check out a branch (a remote one gets a tracking branch)."
    (let* ([root (repo-root)]
           [locals (branch-names root '("refs/heads"))]
           [remotes (branch-names root '("refs/remotes"))])
      (completing-read "Checkout: " (append locals remotes)
                       (lambda (name)
                         (report! root "checkout"
                                  (await (run-git root (if (member name remotes)
                                                           (list "checkout" "--track" name)
                                                           (list "checkout" name)))))))))

  (define-command (magit-branch-create-checkout)
    "Create a branch at HEAD and check it out."
    (let ([root (repo-root)])
      (read-from-minibuffer "Create and checkout branch: "
                            (lambda (name)
                              (if (blank? name)
                                  (message "No name")
                                  (report! root "checkout" (await (run-git root (list "checkout" "-b" name)))))))))

  (define-command (magit-branch-create)
    "Create a branch at HEAD without checking it out."
    (let ([root (repo-root)])
      (read-from-minibuffer "Create branch: "
                            (lambda (name)
                              (if (blank? name)
                                  (message "No name")
                                  (report! root "branch" (await (run-git root (list "branch" name)))))))))

  (define-command (magit-branch-rename)
    "Rename the current branch."
    (let ([root (repo-root)])
      (read-from-minibuffer "Rename current branch to: "
                            (lambda (name)
                              (if (blank? name)
                                  (message "No name")
                                  (report! root "branch" (await (run-git root (list "branch" "-m" name)))))))))

  (define-command (magit-branch-delete)
    "Delete a local branch."
    (let* ([root (repo-root)]
           [current (git-status-head (git-status root))]
           [candidates (filter (lambda (n) (not (equal? n current))) (branch-names root '("refs/heads")))])
      (completing-read "Delete branch: " candidates
                       (lambda (name)
                         (read-from-minibuffer
                          (format "Delete branch ~a? (y or n) " name)
                          (lambda (answer)
                            (if (member answer '("y" "yes"))
                                (let ([r (await (run-git root (list "branch" "-d" name)))])
                                  (if (and (not (zero? (car r))) (string-search-in? (caddr r) "not fully merged"))
                                      (read-from-minibuffer
                                       (format "~a is not fully merged; delete anyway? (y or n) " name)
                                       (lambda (a2)
                                         (if (member a2 '("y" "yes"))
                                             (report! root "branch" (await (run-git root (list "branch" "-D" name))))
                                             (message "Cancelled"))))
                                      (report! root "branch" r)))
                                (message "Cancelled"))))))))

  (define (string-search-in? s sub)
    (let ([n (string-length sub)])
      (let loop ([i 0])
        (cond [(> (+ i n) (string-length s)) #f]
              [(string=? (substring s i (+ i n)) sub) #t]
              [else (loop (+ i 1))]))))

  (define-transient (magit-branch)
    "Branch"
    ("Checkout"
     (action "b" "branch/revision" magit-branch-checkout)
     (action "c" "new branch" magit-branch-create-checkout))
    ("Create" (action "n" "new branch (stay)" magit-branch-create))
    ("Do"
     (action "m" "rename" magit-branch-rename)
     (action "k" "delete" magit-branch-delete)))

  ;; ---- the remote ----

  (define (remotes root)
    (filter (lambda (l) (not (blank? l))) (split-lines (cadr (await (run-git root '("remote")))))))

  ;; Calls (K remote) with the remote to use: the only one, or one chosen.
  (define (with-remote root prompt k)
    (let ([rs (remotes root)])
      (cond [(null? rs) (error 'git "this repository has no remotes")]
            [(null? (cdr rs)) (k (car rs))]
            [else (completing-read prompt rs k)])))

  (define (push-args-from-transient)
    (append (if (transient-arg 'force-with-lease) '("--force-with-lease") '())
            (if (transient-arg 'no-verify) '("--no-verify") '())))

  (define (do-push root remote branch flags upstream?)
    (message "Pushing ~a to ~a..." branch remote)
    (report! root "push"
             (await (run-git root (append '("push") flags (if upstream? '("--set-upstream") '())
                                          (list remote branch))))))

  (define-command (magit-push-current)
    "Push the current branch to its upstream, or to a remote chosen the first time."
    (let* ([root (repo-root)] [flags (push-args-from-transient)] [st (git-status root)] [branch (git-status-head st)])
      (unless branch (error 'magit-push "no branch is checked out"))
      (if (git-status-upstream st)
          (begin (message "Pushing ~a..." branch)
                 (report! root "push" (await (run-git root (append '("push") flags)))))
          (with-remote root (format "Push ~a and set upstream to: " branch)
                       (lambda (remote) (do-push root remote branch flags #t))))))

  (define-command (magit-push-elsewhere)
    "Push the current branch to a remote you choose."
    (let* ([root (repo-root)] [flags (push-args-from-transient)] [st (git-status root)] [branch (git-status-head st)])
      (unless branch (error 'magit-push "no branch is checked out"))
      (with-remote root (format "Push ~a to: " branch)
                   (lambda (remote) (do-push root remote branch flags (not (git-status-upstream st)))))))

  (define-transient (magit-push)
    "Push"
    ("Arguments"
     (switch "- f" "--force-with-lease" force-with-lease)
     (switch "- n" "--no-verify" no-verify))
    ("Push"
     (action "p" "to upstream" magit-push-current)
     (action "e" "elsewhere" magit-push-elsewhere)))

  (define-command (magit-pull-upstream)
    "Pull from the upstream of the current branch."
    (let* ([root (repo-root)] [st (git-status root)]
           [flags (append (if (transient-arg 'rebase) '("--rebase") '())
                          (if (transient-arg 'ff-only) '("--ff-only") '()))])
      (unless (git-status-upstream st)
        (error 'magit-pull "the current branch has no upstream: push it first"))
      (message "Pulling...")
      (report! root "pull" (await (run-git root (cons "pull" flags))))))

  (define-transient (magit-pull)
    "Pull"
    ("Arguments"
     (switch "- r" "--rebase" rebase)
     (switch "- f" "--ff-only" ff-only))
    ("Pull" (action "p" "from upstream" magit-pull-upstream)))

  (define (fetch-flags) (if (transient-arg 'prune) '("--prune") '()))

  (define-command (magit-fetch-upstream)
    "Fetch from the remote of the current branch's upstream (else the only remote)."
    (let* ([root (repo-root)] [flags (fetch-flags)] [up (git-status-upstream (git-status root))])
      (message "Fetching...")
      (if up
          (report! root "fetch" (await (run-git root (cons "fetch" flags))))
          (with-remote root "Fetch from: "
                       (lambda (remote) (report! root "fetch" (await (run-git root (append '("fetch") flags (list remote))))))))))

  (define-command (magit-fetch-all) "Fetch from every remote."
    (let ([root (repo-root)])
      (message "Fetching...")
      (report! root "fetch" (await (run-git root (append '("fetch" "--all") (fetch-flags)))))))

  (define-command (magit-fetch-elsewhere) "Fetch from a remote you choose."
    (let ([root (repo-root)] [flags (fetch-flags)])
      (with-remote root "Fetch from: "
                   (lambda (remote)
                     (message "Fetching ~a..." remote)
                     (report! root "fetch" (await (run-git root (append '("fetch") flags (list remote)))))))))

  (define-transient (magit-fetch)
    "Fetch"
    ("Arguments" (switch "- p" "--prune" prune))
    ("Fetch"
     (action "f" "upstream" magit-fetch-upstream)
     (action "e" "elsewhere" magit-fetch-elsewhere)
     (action "a" "all remotes" magit-fetch-all)))

  (define bindings
    (begin
      (for-each (lambda (b) (define-key! (mode-keymap 'git-status-mode) (car b) (cdr b)))
                '(("c" . magit-commit) ("b" . magit-branch) ("P" . magit-push) ("F" . magit-pull)
                  ("f" . magit-fetch)))
      (for-each (lambda (b) (define-key! (mode-keymap 'git-commit-mode) (car b) (cdr b)))
                '(("C-c C-c" . git-commit-finish) ("C-c C-k" . git-commit-cancel)))
      #t)))
