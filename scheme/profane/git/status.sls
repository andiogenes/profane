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
          git-item-hunk git-item-commit git-status-buffer-refresh! git-refresh-status-buffers!
          make-git-item git-diff-line-segments git-hunk-body-lines)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane keymap) (profane mode) (profane var) (profane face) (profane display)
          (profane files) (profane minibuffer) (profane async) (profane git) (profane section)
          (profane simple))

  (defvar git-repo-root #f "The top directory of the repository a git buffer shows." '(local))
  (defvar git-status-recent-commits 10 "How many recent commits the status buffer lists.")
  (defvar git-status-diff-line-limit 3000
    "When the changes have more diff lines than this, their files start folded.")

  (defvar git-diff-refine #t
    "Emphasize the words that changed inside changed lines of a diff.")

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
                  (git-diff-added-refined () "The words that changed in an added line.")
                  (git-diff-removed-refined () "The words that changed in a removed line.")
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

  (define (git-diff-line-segments line) (diff-line-segments line))

  (define (diff-line-segments line)
    (let ([c (if (string=? line "") #\space (string-ref line 0))])
      (case c
        [(#\+) (list (cons line 'git-diff-added))]
        [(#\-) (list (cons line 'git-diff-removed))]
        [(#\\) (list (cons line 'git-diff-meta))]
        [else (list line)])))

  ;; LINE split at RANGES (character ranges, prefix included): the pieces in the line's face, and
  ;; the ranges in its refined face.
  (define (refined-segments line ranges)
    (let* ([plain (if (char=? (string-ref line 0) #\+) 'git-diff-added 'git-diff-removed)]
           [strong (if (char=? (string-ref line 0) #\+) 'git-diff-added-refined 'git-diff-removed-refined)])
      (let loop ([rs ranges] [at 0] [out '()])
        (cond
         [(null? rs) (reverse (if (< at (string-length line))
                                  (cons (cons (substring line at (string-length line)) plain) out)
                                  out))]
         [else (let ([s (car (car rs))] [e (cdr (car rs))])
                 (loop (cdr rs) e
                       (cons (cons (substring line s e) strong)
                             (if (> s at) (cons (cons (substring line at s) plain) out) out))))]))))

  ;; The body lines of HUNK for a section: colored by prefix, with changed words emphasized.
  (define (git-hunk-body-lines h)
    (let* ([lines (git-diff-hunk-lines h)]
           [ranges (if (var-ref 'git-diff-refine) (git-refine-lines lines) (map (lambda (l) '()) lines))])
      (map (lambda (l r) (if (null? r) (diff-line-segments l) (refined-segments l r))) lines ranges)))

  (define (hunk-section area change file h index folded?)
    (new-section 'hunk (list 'hunk area (git-change-path change) index)
                 (list (cons (git-diff-hunk-header h) 'git-diff-hunk-heading))
                 (git-hunk-body-lines h)
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

  ;; Redraws every status buffer of the repository at ROOT.
  (define (git-refresh-status-buffers! root)
    (for-each (lambda (b) (when (equal? (with-current-buffer b (var-ref 'git-repo-root)) root)
                            (git-status-buffer-refresh! b)))
              (status-buffers)))

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
       [(and item (eq? (git-item-kind item) 'commit))
        (let ([show (command-procedure 'magit-show-commit)])
          (if show (show) (message "Cannot show commits here")))]
       [else (message "Nothing to visit here")])))

;; ---- staging, unstaging and discarding ----
  ;;
  ;; s, u and k act on what point is on: a file, a hunk, a whole section (S and U on all changes),
  ;; or, when the region is active, on the lines it covers: the hunks it touches, in part, or the
  ;; files it covers. Everything is a git command or a patch for `git apply` (core/git builds the
  ;; patches); the buffer is refreshed afterwards, whether or not git complained.

  (define (active-region)
    (and (var-ref 'mark-active) (mark) (not (= (mark) (point)))
         (cons (min (mark) (point)) (max (mark) (point)))))

  (define (sections-where pred)
    (let ([out '()])
      (section-walk (sections) (lambda (s) (when (pred s) (set! out (cons s out)))))
      (reverse out)))

  (define (overlaps? s region) (and (< (section-start s) (cdr region)) (> (section-end s) (car region))))

  (define (kind-of s) (let ([v (section-value s)]) (and v (git-item? v) (git-item-kind v))))

  (define (area-ok? op area)
    (case op
      [(stage) (memq area '(unstaged untracked unmerged))]
      [(unstage) (eq? area 'staged)]
      [else (memq area '(unstaged untracked staged))]))

  (define (check-area! op area)
    (unless (area-ok? op area)
      (error (case op [(stage) 'magit-stage] [(unstage) 'magit-unstage] [else 'magit-discard])
             (case op
               [(stage) "already staged"]
               [(unstage) "not staged"]
               [else "nothing to discard here"]))))

  (define (git-action root . args) (lambda () (await (run-git root args))))

  ;; A hunk section's patch and the flags to apply it with, for OP (and REGION: the lines of the
  ;; hunk the region covers; #f for the whole hunk). #f if the region has no change in it.
  (define (hunk-patch-for op s region)
    (let* ([item (section-value s)] [file (git-item-file item)] [hunk (git-item-hunk item)])
      (if region
          (let* ([hl (line-number-at-pos (section-start s))]
                 [n (length (git-diff-hunk-lines hunk))]
                 [beg (car region)] [end (cdr region)]
                 [last-pos (if (and (> end beg) (string=? (buffer-substring (- end 1) end) "\n")) (- end 1) end)]
                 [from (max 0 (- (line-number-at-pos beg) hl 1))]
                 [to (min n (- (line-number-at-pos last-pos) hl))])
            (and (< from to) (git-hunk-region-patch file hunk from to (not (eq? op 'stage)))))
          (git-hunk-patch file hunk))))

  (define (apply-flags op area)
    (case op
      [(stage) '("--cached")]
      [(unstage) '("--cached" "-R")]
      [else (if (eq? area 'staged) '("--index" "-R") '("-R"))]))

  (define (hunk-plan root op hunks region)
    ;; Last hunk first, so the line numbers of the ones before it stay right.
    (let loop ([hs (reverse hunks)] [actions '()] [count 0])
      (if (null? hs)
          (begin
            (when (null? actions) (error 'magit-stage "no changes selected"))
            (cons (cond [region (format "~a selected change~a" count (if (= count 1) "" "s"))]
                        [else "this hunk"])
                  (reverse actions)))
          (let* ([s (car hs)] [item (section-value s)] [area (git-item-area item)])
            (check-area! op area)
            (let ([patch (hunk-patch-for op s region)])
              (if patch
                  (loop (cdr hs)
                        (cons (let ([flags (apply-flags op area)])
                                (lambda () (await (git-apply-patch root patch flags))))
                              actions)
                        (+ count 1))
                  (loop (cdr hs) actions count)))))))

  (define (file-action root op item)
    (let ([path (git-item-path item)] [area (git-item-area item)]
          [orig (and (git-item-change item) (git-change-orig (git-item-change item)))])
      (check-area! op area)
      (case op
        [(stage) (apply git-action root "add" "--" path (if orig (list orig) '()))]
        [(unstage) (apply git-action root "reset" "-q" "--" path (if orig (list orig) '()))]
        [else
         (cond
          [(eq? area 'untracked) (git-action root "clean" "-fdq" "--" path)]
          [(eq? area 'unstaged) (git-action root "checkout" "--" path)]
          [orig (error 'magit-discard "discarding a staged rename is not supported: unstage it first")]
          [(char=? (git-change-index (git-item-change item)) #\A) (git-action root "rm" "-f" "-q" "--" path)]
          [else (git-action root "checkout" "HEAD" "--" path)])])))

  (define (file-plan root op files)
    (when (null? files) (error 'magit-stage "nothing here to act on"))
    (let ([items (map section-value files)])
      (cons (if (= (length items) 1)
                (let ([i (car items)])
                  (if (eq? (git-item-area i) 'untracked)
                      (format "untracked file ~a" (git-item-path i))
                      (format "changes in ~a" (git-item-path i))))
                (format "~a files" (length items)))
            (map (lambda (i) (file-action root op i)) items))))

  (define (area-plan root op s)
    (case (section-kind s)
      [(unstaged) (if (eq? op 'stage)
                      (cons "all unstaged changes" (list (git-action root "add" "-u")))
                      (error 'magit-discard "discard files one at a time"))]
      [(staged) (if (eq? op 'unstage)
                    (cons "all staged changes" (list (git-action root "reset" "-q")))
                    (error 'magit-discard "discard files one at a time"))]
      [(untracked) (if (eq? op 'stage)
                       (file-plan root op (section-children s))
                       (error 'magit-discard "discard files one at a time"))]
      [else (error 'magit-stage "nothing here to act on")]))

  (define (make-plan root op)
    (let* ([region (active-region)]
           [here (section-at-point)]
           [item (and here (section-value here))]
           [hunks (if region (sections-where (lambda (s) (and (eq? (kind-of s) 'hunk) (overlaps? s region)))) '())])
      (cond
       [(pair? hunks) (hunk-plan root op hunks region)]
       [region (file-plan root op (sections-where (lambda (s) (and (memq (kind-of s) '(file untracked unmerged)) (overlaps? s region)))))]
       [(and item (eq? (git-item-kind item) 'hunk)) (hunk-plan root op (list here) #f)]
       [(and item (memq (git-item-kind item) '(file untracked unmerged))) (file-plan root op (list here))]
       [(and here (memq (section-kind here) '(unstaged staged untracked))) (area-plan root op here)]
       [else (error (if (eq? op 'stage) 'magit-stage (if (eq? op 'unstage) 'magit-unstage 'magit-discard))
                    "nothing here to act on")])))

  ;; Runs the plan's actions in order, then redraws B. Failures are reported together.
  (define (run-plan! b plan)
    (let loop ([as (cdr plan)] [errors '()])
      (cond
       [(pair? as)
        (let ([r ((car as))])
          (loop (cdr as) (if (zero? (car r)) errors (cons (caddr r) errors))))]
       [else
        (git-status-buffer-refresh! b)
        (when (pair? errors)
          (message "git: ~a" (let ([e (car (reverse errors))])
                               (let ([nl (let find ([i 0]) (cond [(= i (string-length e)) i] [(char=? (string-ref e i) #\newline) i] [else (find (+ i 1))]))])
                                 (substring e 0 nl)))))])))

  (define (stage-command op)
    (let* ([b (current-buffer)] [plan (make-plan (var-ref 'git-repo-root) op)])
      (if (eq? op 'discard)
          (read-from-minibuffer (format "Discard ~a? (y or n) " (car plan))
                                (lambda (answer)
                                  (if (member answer '("y" "yes"))
                                      (with-current-buffer b (run-plan! b plan))
                                      (message "Cancelled"))))
          (run-plan! b plan))))

  (define-command (magit-stage) "Stage the file, hunk or selected lines at point." (stage-command 'stage))
  (define-command (magit-unstage) "Unstage the file, hunk or selected lines at point." (stage-command 'unstage))
  (define-command (magit-discard)
    "Discard the changes of the file, hunk or selected lines at point, after asking."
    (stage-command 'discard))

  (define-command (magit-stage-modified) "Stage every change to tracked files."
    (let ([b (current-buffer)])
      (run-plan! b (cons "all" (list (git-action (var-ref 'git-repo-root) "add" "-u"))))))

  (define-command (magit-unstage-all) "Unstage everything."
    (let ([b (current-buffer)])
      (run-plan! b (cons "all" (list (git-action (var-ref 'git-repo-root) "reset" "-q"))))))

  (define bindings
    (begin
      (define-key! (global-map) "C-x g" 'magit-status)
      (for-each (lambda (b) (define-key! (mode-keymap 'git-status-mode) (car b) (cdr b)))
                '(("RET" . git-visit-thing) ("s" . magit-stage) ("u" . magit-unstage)
                  ("k" . magit-discard) ("S" . magit-stage-modified) ("U" . magit-unstage-all)))
      #t)))
