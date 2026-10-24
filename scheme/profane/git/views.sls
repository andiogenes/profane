;;; (profane git views) — diffs, single commits and the log, in section buffers. Unstable API
;;; (plan §10, §8m).
;;;
;;; d opens the diff menu in the status buffer: d the diff at point (a commit, the staged or the
;;; unstaged changes), u unstaged, s staged, w the work tree against HEAD, r a range such as
;;; main..topic, c a commit; -w ignores whitespace, -U sets the context. l opens the log menu:
;;; l the current branch, o another, a all branches; -n sets how many commits. RET on a commit
;;; (status buffer, log, here) shows it; RET on a file or hunk visits the file; + in the log
;;; shows twice as many commits; g refreshes any of these buffers; TAB, n, p ... as in
;;; section-mode. A diff is a tree of files and hunks like the status buffer's, without the
;;; staging commands (the area of its items is `diff`).

(library (profane git views)
  (export)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane keymap) (profane mode) (profane var) (profane face) (profane display)
          (profane files) (profane minibuffer) (profane async) (profane transient)
          (profane git) (profane git status) (profane section) (profane simple))

  (define-major-mode git-diff-mode section-mode "Diff" "Major mode of buffers showing a diff.")
  (define-major-mode git-log-mode section-mode "Log" "Major mode of the commit log.")

  (defvar git-log-limit 100 "How many commits the log buffer shows." '(local))
  (defvar git-view-state #f "What a view buffer shows: a list the refresh function rebuilds it from." '(local))

  ;; ---- helpers ----

  (define (pad s n) (if (< (string-length s) n) (string-append s (make-string (- n (string-length s)) #\space)) s))

  (define (split-lines s)
    (let loop ([i 0] [start 0] [out '()])
      (cond [(= i (string-length s)) (reverse (if (> i start) (cons (substring s start i) out) out))]
            [(char=? (string-ref s i) #\newline) (loop (+ i 1) (+ i 1) (cons (substring s start i) out))]
            [else (loop (+ i 1) start out)])))

  (define (string-prefix? p s)
    (and (<= (string-length p) (string-length s)) (string=? p (substring s 0 (string-length p)))))

  (define (repo-root)
    (or (var-ref 'git-repo-root) (git-root (default-directory)) (error 'git "not inside a git repository")))

  ;; ---- diff trees ----

  (define (file-word f)
    (let ([h (git-diff-file-header f)])
      (cond [(find (lambda (l) (string-prefix? "new file mode" l)) h) "new file"]
            [(find (lambda (l) (string-prefix? "deleted file mode" l)) h) "deleted"]
            [(find (lambda (l) (string-prefix? "rename from" l)) h) "renamed"]
            [else "modified"])))

  (define (hunk-section f h index)
    (new-section 'hunk (list 'hunk 'diff (git-diff-file-path f) index)
                 (list (cons (git-diff-hunk-header h) 'git-diff-hunk-heading))
                 (git-hunk-body-lines h)
                 '() #f
                 (make-git-item 'hunk 'diff (git-diff-file-path f) #f f h #f)))

  (define (file-section f fold?)
    (new-section 'file (list 'file 'diff (git-diff-file-path f))
                 (list (cons (string-append (pad (file-word f) 11)
                                            (if (git-diff-file-old-path f)
                                                (string-append (git-diff-file-old-path f) " -> " (git-diff-file-path f))
                                                (git-diff-file-path f)))
                             'git-diff-file-heading))
                 (if (git-diff-file-binary? f) '("Binary file") '())
                 (let loop ([hs (git-diff-file-hunks f)] [i 0] [out '()])
                   (if (null? hs) (reverse out) (loop (cdr hs) (+ i 1) (cons (hunk-section f (car hs) i) out))))
                 fold?
                 (make-git-item 'file 'diff (git-diff-file-path f) #f f #f #f)))

  (define (changes-root title files)
    (let* ([lines (apply + (map (lambda (f) (apply + (map (lambda (h) (length (git-diff-hunk-lines h)))
                                                          (git-diff-file-hunks f))))
                                files))]
           [fold? (> lines (var-ref 'git-status-diff-line-limit))])
      (new-section 'diff 'diff
                   (format "~a (~a file~a)" title (length files) (if (= (length files) 1) "" "s"))
                   '() (map (lambda (f) (file-section f fold?)) files) #f #f)))

  ;; ---- opening view buffers ----

  ;; Shows the sections BUILD (a procedure of no arguments that reads git and returns a tree) makes
  ;; in the buffer named NAME for the repository ROOT, in MODE. The first read happens before the
  ;; buffer exists, so a failure (an unknown revision) leaves nothing behind; g reads again.
  (define (open-view! name root mode build)
    (let* ([tree (build)]
           [b (get-buffer-create name)])
      (with-current-buffer b
        (unless (eq? (var-ref 'major-mode) mode)
          (set-major-mode! mode)
          (buffer-disable-undo)
          (set-buffer-read-only! #t))
        (var-set! 'git-repo-root root)
        (var-set! 'default-directory (string-append root "/"))
        (var-set! 'section-refresh-function
                  (lambda ()
                    (let ([fresh (build)]) (with-current-buffer b (section-refresh! fresh)))))
        (section-refresh! tree))
      (switch-to-buffer b)
      b))

  (define (diff-args-from-transient)
    (append (if (transient-arg 'ignore-space) '("-w") '())
            (let ([c (transient-arg 'context)]) (if (and c (> (string-length c) 0)) (list (format "-U~a" c)) '()))))

  (define (show-diff! title heading args)
    (let ([root (repo-root)])
      (open-view! (format "*git-diff: ~a*" title) root 'git-diff-mode
                  (lambda () (list (changes-root heading (git-diff-with root args)))))))

  (define-command (magit-diff-unstaged) "Show the unstaged changes."
    (show-diff! "unstaged" "Unstaged changes" (cons "diff" (diff-args-from-transient))))
  (define-command (magit-diff-staged) "Show the staged changes."
    (show-diff! "staged" "Staged changes" (append '("diff" "--cached") (diff-args-from-transient))))
  (define-command (magit-diff-worktree) "Show the work tree against HEAD."
    (show-diff! "HEAD" "Changes since HEAD" (append '("diff" "HEAD") (diff-args-from-transient))))

  (define-command (magit-diff-range)
    "Show the diff of a range, such as main..topic or a single revision against the work tree."
    (let ([args (diff-args-from-transient)])
      (read-from-minibuffer "Diff range: "
                            (lambda (range)
                              (if (string=? range "")
                                  (message "No range")
                                  (show-diff! range (format "Changes in ~a" range) (append '("diff") args (list range))))))))

  ;; ---- one commit ----

  (define (commit-tree rev info files)
    (let* ([f (split-fields info)]
           [hash (list-ref f 0)] [who (list-ref f 1)] [date (list-ref f 2)] [body (list-ref f 3)])
      (list
       (new-section 'commit (list 'commit-header hash)
                    (list "commit " (cons hash 'git-hash))
                    (append (list (list (cons "Author: " 'git-header-label) who)
                                  (list (cons "Date:   " 'git-header-label) date)
                                  "")
                            (map (lambda (l) (string-append "    " l)) (split-lines body)))
                    '() #f #f)
       (changes-root "Changes" files))))

  (define (split-fields s)
    (let loop ([i 0] [start 0] [out '()])
      (cond [(= (length out) 3) (reverse (cons (substring s start (string-length s)) out))]
            [(= i (string-length s)) (reverse (cons (substring s start i) out))]
            [(char=? (string-ref s i) #\x1f) (loop (+ i 1) (+ i 1) (cons (substring s start i) out))]
            [else (loop (+ i 1) start out)])))

  (define (show-commit! rev)
    (let ([root (repo-root)])
      (open-view! (format "*git-commit: ~a*" rev) root 'git-diff-mode
                  (lambda ()
                    (let ([r (await (run-git root (list "log" "-1" "--date=iso" "--format=%H%x1f%an <%ae>%x1f%ad%x1f%B" rev "--")))])
                      (unless (zero? (car r))
                        (error 'magit-show-commit (let ([e (caddr r)]) (if (string=? e "") "unknown revision" e))))
                      (commit-tree rev (cadr r)
                                   (git-diff-with root (list "show" "--format=" "--diff-merges=first-parent" rev))))))))

  (define-command (magit-show-commit)
    "Show a commit: the one at point, else one you name."
    (let* ([s (section-at-point)] [item (and s (section-value s))]
           [c (and item (git-item? item) (git-item-commit item))])
      (if c
          (show-commit! (git-commit-hash c))
          (read-from-minibuffer "Show commit (default HEAD): "
                                (lambda (rev) (show-commit! (if (string=? rev "") "HEAD" rev)))))))

  ;; ---- the log ----

  (define (log-commit-section c)
    (new-section 'commit (list 'commit 'log (git-commit-hash c))
                 (append (list (cons (git-commit-short c) 'git-hash) "  " (git-commit-subject c))
                         (if (string=? (git-commit-refs c) "") '()
                             (list "  " (cons (format "(~a)" (git-commit-refs c)) 'git-branch-local)))
                         (list "  " (cons (format "~a, ~a" (git-commit-author c) (git-commit-date c)) 'git-hash)))
                 '() '() #f
                 (make-git-item 'commit 'log #f #f #f #f c)))

  (define (show-log! title rev limit)
    (let* ([root (repo-root)] [name (format "*git-log: ~a*" title)]
           [b (get-buffer-create name)])
      ;; The limit lives in the buffer, so + can change it and g keeps it.
      (with-current-buffer b (var-set! 'git-log-limit limit))
      (open-view! name root 'git-log-mode
                  (lambda ()
                    (let ([commits (git-log root rev (with-current-buffer b (var-ref 'git-log-limit)))])
                      (list (new-section 'log 'log (format "Commits in ~a (~a)" title (length commits)) '()
                                         (map log-commit-section commits) #f #f)))))))

  (define (limit-from-transient)
    (let ([n (transient-arg 'count)])
      (or (and n (string->number n)) (var-ref 'git-log-limit))))

  (define-command (magit-log-current) "Show the log of the current branch."
    (show-log! "HEAD" #f (limit-from-transient)))
  (define-command (magit-log-all) "Show the log of all branches."
    (show-log! "all" "--all" (limit-from-transient)))
  (define-command (magit-log-other)
    "Show the log of a branch or revision you choose."
    (let* ([root (repo-root)] [limit (limit-from-transient)]
           [names (let ([r (await (run-git root '("for-each-ref" "--format=%(refname:short)" "refs/heads" "refs/remotes" "refs/tags")))])
                    (filter (lambda (n) (> (string-length n) 0)) (split-lines (cadr r))))])
      (completing-read "Log of: " names (lambda (rev) (show-log! rev rev limit)))))

  (define-command (git-log-more) "Show twice as many commits."
    (var-set! 'git-log-limit (* 2 (var-ref 'git-log-limit)))
    (let ([f (var-ref 'section-refresh-function)]) (when f (f))))

  ;; ---- the menus ----

  (define-command (magit-diff-dwim)
    "Show the diff for what point is on: a commit, the staged or the unstaged changes."
    (let* ([s (section-at-point)] [item (and s (section-value s))])
      (cond
       [(and item (git-item? item) (eq? (git-item-kind item) 'commit)) ((command-procedure 'magit-show-commit))]
       [(and item (git-item? item) (eq? (git-item-area item) 'staged)) ((command-procedure 'magit-diff-staged))]
       [else ((command-procedure 'magit-diff-unstaged))])))

  (define-transient (magit-diff)
    "Diff"
    ("Arguments"
     (switch "- w" "-w" ignore-space)
     (option "- u" "-U" context))
    ("Diff"
     (action "d" "dwim" magit-diff-dwim)
     (action "u" "unstaged" magit-diff-unstaged)
     (action "s" "staged" magit-diff-staged)
     (action "w" "work tree vs HEAD" magit-diff-worktree)
     (action "r" "range" magit-diff-range)
     (action "c" "commit" magit-show-commit)))

  (define-transient (magit-log)
    "Log"
    ("Arguments" (option "- n" "-n" count))
    ("Log"
     (action "l" "current branch" magit-log-current)
     (action "o" "other" magit-log-other)
     (action "a" "all branches" magit-log-all)))

  (define bindings
    (begin
      (for-each (lambda (b) (define-key! (mode-keymap 'git-status-mode) (car b) (cdr b)))
                '(("d" . magit-diff) ("l" . magit-log)))
      (for-each (lambda (b) (define-key! (mode-keymap 'git-diff-mode) (car b) (cdr b)))
                '(("RET" . git-visit-thing)))
      (for-each (lambda (b) (define-key! (mode-keymap 'git-log-mode) (car b) (cdr b)))
                '(("RET" . magit-show-commit) ("+" . git-log-more)))
      #t)))
