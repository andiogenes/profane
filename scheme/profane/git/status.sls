;;; (profane git status) — the repository status buffer, after Magit's magit-status. Unstable API
;;; (plan §10, §8m).
;;;
;;; C-x g (magit-status) shows the repository of the current directory as sections: the head and
;;; its upstream, untracked files, unstaged and staged changes (files, and under them hunks with
;;; their lines colored), unmerged paths, commits not yet pushed or pulled, and recent commits.
;;; Keys, on top of section-mode (TAB n p M-n M-p ^ S-TAB): g refreshes, RET visits the file (on a
;;; hunk line, at that line), q leaves. The sections' values are git-item records, which the
;;; staging commands act on.

(library (profane git status)
  (export git-item? git-item-kind git-item-area git-item-path git-item-change git-item-file
          git-item-hunk git-item-commit git-status-buffer-refresh!)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane keymap) (profane mode) (profane var) (profane face) (profane display)
          (profane files) (profane git) (profane section) (profane simple))

  (defvar git-repo-root #f "The top directory of the repository a git buffer shows." '(local))
  (defvar git-status-recent-commits 10 "How many recent commits the status buffer lists.")
  (defvar git-status-diff-line-limit 3000
    "When the changes have more diff lines than this, their files start folded.")

  (define git-faces
    (begin
      (for-each (lambda (f) (define-face (car f) (cadr f) (caddr f)))
                '((git-header-label ((weight . bold)) "Labels like Head: in the status buffer.")
                  (git-branch-local () "Local branch names.")
                  (git-branch-remote () "Remote branch names.")
                  (git-hash () "Abbreviated commit hashes.")
                  (git-diff-file-heading ((weight . bold)) "File headings in diffs.")
                  (git-diff-hunk-heading () "Hunk headings in diffs.")
                  (git-diff-added () "Added lines in diffs.")
                  (git-diff-removed () "Removed lines in diffs.")
                  (git-diff-meta () "Notes in diffs, like No newline at end of file.")))
      #t))

  (define-major-mode git-status-mode section-mode "Git" "Major mode of the repository status buffer.")

  ;; What a section stands for. KIND: file, hunk, untracked, unmerged, commit, header. AREA:
  ;; unstaged, staged, untracked, unmerged, or #f. CHANGE: the git-change; FILE and HUNK: the
  ;; git-diff-file and git-diff-hunk (or #f); COMMIT: a git-commit.
  (define-record-type git-item (fields kind area path change file hunk commit))

  ;; ---- building the tree ----

  (define (pad s n) (if (< (string-length s) n) (string-append s (make-string (- n (string-length s)) #\space)) s))

  (define (status-word ch)
    (case ch
      [(#\M) "modified"] [(#\A) "new file"] [(#\D) "deleted"] [(#\R) "renamed"] [(#\C) "copied"]
      [(#\T) "typechange"] [(#\U) "unmerged"] [else "changed"]))

  (define (diff-line-segments line)
    (let ([c (if (string=? line "") #\space (string-ref line 0))])
      (case c
        [(#\+) (list (cons line 'git-diff-added))]
        [(#\-) (list (cons line 'git-diff-removed))]
        [(#\\) (list (cons line 'git-diff-meta))]
        [else (list line)])))

  (define (hunk-section area change file h index folded?)
    (new-section 'hunk (list 'hunk area (git-change-path change) index)
                 (list (cons (git-diff-hunk-header h) 'git-diff-hunk-heading))
                 (map diff-line-segments (git-diff-hunk-lines h))
                 '() folded?
                 (make-git-item 'hunk area (git-change-path change) change file h #f)))

  (define (file-section area change file fold?)
    (let* ([ch (if (eq? area 'staged) (git-change-index change) (git-change-worktree change))]
           [path (git-change-path change)]
           [label (string-append (pad (status-word ch) 11)
                                 (if (git-change-orig change)
                                     (string-append (git-change-orig change) " -> " path)
                                     path))]
           [hunks (if file (git-diff-file-hunks file) '())])
      (new-section 'file (list 'file area path)
                   (list (cons label 'git-diff-file-heading))
                   (if (and file (git-diff-file-binary? file)) '("Binary file") '())
                   (let loop ([hs hunks] [i 0] [out '()])
                     (if (null? hs)
                         (reverse out)
                         (loop (cdr hs) (+ i 1) (cons (hunk-section area change file (car hs) i #f) out))))
                   fold?
                   (make-git-item 'file area path change file #f #f))))

  (define (diff-of files path)
    (find (lambda (f) (string=? (git-diff-file-path f) path)) files))

  (define (changes-section area title changes files)
    (let* ([lines (apply + (map (lambda (f) (apply + (map (lambda (h) (length (git-diff-hunk-lines h)))
                                                          (git-diff-file-hunks f))))
                                files))]
           [fold? (> lines (var-ref 'git-status-diff-line-limit))])
      (new-section area area (format "~a (~a)" title (length changes)) '()
                   (map (lambda (c) (file-section area c (diff-of files (git-change-path c)) fold?)) changes)
                   #f #f)))

  (define (commit-section area c)
    (new-section 'commit (list 'commit area (git-commit-hash c))
                 (append (list (cons (git-commit-short c) 'git-hash) "  " (git-commit-subject c))
                         (if (string=? (git-commit-refs c) "") '()
                             (list "  " (cons (format "(~a)" (git-commit-refs c)) 'git-branch-local))))
                 '() '() #f
                 (make-git-item 'commit area #f #f #f #f c)))

  (define (commits-section area title commits)
    (new-section area area (format "~a (~a)" title (length commits)) '()
                 (map (lambda (c) (commit-section area c)) commits) #f #f))

  (define (header-section id label name face subject)
    (new-section 'header id
                 (list (cons (pad label 10) 'git-header-label) (cons name face)
                       (if subject (string-append "  " subject) ""))
                 '() '() #f #f))

  ;; All reading happens here, before any buffer is touched (a command may wait between slices).
  (define (read-everything root)
    (let* ([st (git-status root)]
           [unstaged (git-diff root #f)]
           [staged (git-diff root #t)]
           [upstream (git-status-upstream st)]
           [recent (git-log root #f (var-ref 'git-status-recent-commits))]
           [unpushed (if upstream (git-log root (string-append upstream "..HEAD") 256) '())]
           [unpulled (if upstream (git-log root (string-append "HEAD.." upstream) 256) '())]
           [up-head (if upstream (git-log root upstream 1) '())])
      (list st unstaged staged recent unpushed unpulled up-head)))

  (define (build-tree data)
    (let* ([st (list-ref data 0)] [unstaged (list-ref data 1)] [staged (list-ref data 2)]
           [recent (list-ref data 3)] [unpushed (list-ref data 4)] [unpulled (list-ref data 5)]
           [up-head (list-ref data 6)]
           [upstream (git-status-upstream st)]
           [untracked (git-status-untracked st)]
           [unmerged (git-status-unmerged st)])
      (append
       (list (header-section 'head "Head:" (or (git-status-head st) "(detached)") 'git-branch-local
                             (if (pair? recent) (git-commit-subject (car recent)) "(no commits yet)")))
       (if upstream
           (list (header-section 'upstream "Upstream:" upstream 'git-branch-remote
                                 (and (pair? up-head) (git-commit-subject (car up-head)))))
           '())
       (if (pair? untracked)
           (list (new-section 'untracked 'untracked (format "Untracked files (~a)" (length untracked)) '()
                              (map (lambda (c)
                                     (new-section 'untracked (list 'untracked (git-change-path c)) (git-change-path c)
                                                  '() '() #f
                                                  (make-git-item 'untracked 'untracked (git-change-path c) c #f #f #f)))
                                   untracked)
                              #f #f))
           '())
       (if (pair? unmerged)
           (list (new-section 'unmerged 'unmerged (format "Unmerged paths (~a)" (length unmerged)) '()
                              (map (lambda (c)
                                     (new-section 'unmerged (list 'unmerged (git-change-path c)) (git-change-path c)
                                                  '() '() #f
                                                  (make-git-item 'unmerged 'unmerged (git-change-path c) c #f #f #f)))
                                   unmerged)
                              #f #f))
           '())
       (if (pair? (git-status-unstaged st))
           (list (changes-section 'unstaged "Unstaged changes" (git-status-unstaged st) unstaged))
           '())
       (if (pair? (git-status-staged st))
           (list (changes-section 'staged "Staged changes" (git-status-staged st) staged))
           '())
       (if (pair? unpulled)
           (list (commits-section 'unpulled (format "Unpulled from ~a" upstream) unpulled))
           '())
       (if (pair? unpushed)
           (list (commits-section 'unpushed (format "Unmerged into ~a" upstream) unpushed))
           '())
       (if (pair? recent)
           (list (commits-section 'recent "Recent commits" recent))
           '()))))

  ;; ---- the buffer ----

  (define (status-buffers)
    (filter (lambda (b) (with-current-buffer b (eq? (var-ref 'major-mode) 'git-status-mode))) (buffer-list)))

  (define (find-status-buffer root)
    (find (lambda (b) (with-current-buffer b (equal? (var-ref 'git-repo-root) root))) (status-buffers)))

  (define (buffer-name-for root)
    (format "magit: ~a" (file-name-nondirectory (if (string=? root "/") root root))))

  ;; Reads the repository and redraws buffer B, keeping folds and point.
  (define (git-status-buffer-refresh! b)
    (let* ([root (with-current-buffer b (var-ref 'git-repo-root))]
           [data (read-everything root)] ; may wait: no buffer is current-buffer-sensitive here
           [tree (build-tree data)])
      (with-current-buffer b (section-refresh! tree))))

  (define-command (magit-status)
    "Show the status of the git repository containing the current directory."
    (let* ([dir (or (let ([f (buffer-file-name (current-buffer))])
                      (and f (file-name-directory f)))
                    (default-directory))]
           [root (and dir (git-root dir))])
      (unless root (error 'magit-status "not inside a git repository" dir))
      (let ([b (or (find-status-buffer root)
                   (let ([nb (generate-new-buffer (buffer-name-for root))])
                     (with-current-buffer nb
                       (set-major-mode! 'git-status-mode)
                       (var-set! 'git-repo-root root)
                       (var-set! 'default-directory (string-append root "/"))
                       (var-set! 'section-separate-roots #t)
                       (var-set! 'section-refresh-function (lambda () (git-status-buffer-refresh! nb)))
                       (buffer-disable-undo)
                       (set-buffer-read-only! #t))
                     nb))])
        (switch-to-buffer b)
        (git-status-buffer-refresh! b))))

  ;; ---- visiting ----

  ;; The line in the file's new version that point is on within hunk section S.
  (define (hunk-line-at s)
    (let* ([h (git-item-hunk (section-value s))]
           [offset (- (line-number-at-pos (point)) (line-number-at-pos (section-start s)))])
      (let loop ([lines (git-diff-hunk-lines h)] [i 1] [n (git-diff-hunk-new-start h)])
        (cond [(or (null? lines) (>= i offset)) n]
              [(and (> (string-length (car lines)) 0) (char=? (string-ref (car lines) 0) #\-)) (loop (cdr lines) (+ i 1) n)]
              [else (loop (cdr lines) (+ i 1) (+ n 1))]))))

  (define-command (git-visit-thing)
    "Visit the file at point, at the line of the hunk line point is on."
    (let* ([s (section-at-point)] [item (and s (section-value s))])
      (cond
       [(and item (memq (git-item-kind item) '(file hunk untracked unmerged)))
        (let* ([root (var-ref 'git-repo-root)]
               [path (string-append root "/" (git-item-path item))]
               [line (and (eq? (git-item-kind item) 'hunk) (hunk-line-at s))])
          (switch-to-buffer (find-file-noselect path))
          (when line
            (goto-char (point-min))
            (forward-line (- line 1))))]
       [else (message "Nothing to visit here")])))

  (define bindings
    (begin
      (define-key! (global-map) "C-x g" 'magit-status)
      (define-key! (mode-keymap 'git-status-mode) "RET" 'git-visit-thing)
      #t)))
