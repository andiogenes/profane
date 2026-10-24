;;; (profane git) — running git and reading its state. Unstable API (plan §10).
;;;
;;;   (await (run-git root '("add" "a.txt")))      ; => (code stdout stderr), logged to *git-process*
;;;   (git-status root)    ; => a git-status record (branch, upstream, ahead/behind, file changes)
;;;   (git-diff root #f)   ; => list of git-diff-file, each with its git-diff-hunks (#t: staged)
;;;
;;; Everything here runs inside a command and waits for git with `await`, so the editor stays
;;; responsive. Mutations always go through run-git; the readers go through the backend named by
;;; git-read-backend (plan §8m): `cli` parses git's own output, and a backend that reads with
;;; libgit2 on a worker can be registered with define-git-backend! and selected from Scheme
;;; without changing the porcelain.

(library (profane git)
  (export run-git git-root git-process-buffer git-executable
          git-status? git-status-root git-status-head git-status-oid git-status-upstream
          git-status-ahead git-status-behind git-status-changes
          git-change? git-change-path git-change-orig git-change-index git-change-worktree
          git-change-kind git-status-staged git-status-unstaged git-status-untracked
          git-status-unmerged
          git-diff-file? git-diff-file-path git-diff-file-old-path git-diff-file-header
          git-diff-file-hunks git-diff-file-binary?
          git-diff-hunk? git-diff-hunk-header git-diff-hunk-old-start git-diff-hunk-old-len
          git-diff-hunk-new-start git-diff-hunk-new-len git-diff-hunk-lines
          git-status git-diff git-log define-git-backend! git-backend-names
          git-hunk-patch git-hunk-region-patch git-apply-patch
          git-commit? git-commit-hash git-commit-short git-commit-subject git-commit-author
          git-commit-date git-commit-refs
          parse-git-status parse-git-diff parse-git-log)
  (import (chezscheme) (profane buffer) (profane process) (profane async) (profane var)
          (profane fs))

  (defvar git-read-backend 'cli
    "Where git-status and git-diff get their data: a backend registered with define-git-backend!.")
  (defvar git-executable-name "git" "The git program (found on exec-path).")
  (defvar git-process-log-limit 400000 "Characters *git-process* keeps before dropping the oldest half.")

  ;; ---- small string helpers ----

  (define (split-on s ch)
    (let loop ([i 0] [start 0] [out '()])
      (cond [(= i (string-length s)) (reverse (cons (substring s start i) out))]
            [(char=? (string-ref s i) ch) (loop (+ i 1) (+ i 1) (cons (substring s start i) out))]
            [else (loop (+ i 1) start out)])))

  (define (string-prefix? p s)
    (and (<= (string-length p) (string-length s)) (string=? p (substring s 0 (string-length p)))))

  (define (drop-right-char s ch)
    (let ([n (string-length s)])
      (if (and (> n 0) (char=? (string-ref s (- n 1)) ch)) (substring s 0 (- n 1)) s)))

  ;; ---- running git ----

  (define (git-executable) (or (executable-find (var-ref 'git-executable-name)) "git"))

  (define (git-process-buffer) (get-buffer-create "*git-process*"))

  (define (log! . strings)
    (let ([b (git-process-buffer)])
      (with-current-buffer b
        (with-inhibit-read-only
         (lambda ()
           (when (> (buffer-size) (var-ref 'git-process-log-limit))
             (delete-region 0 (quotient (buffer-size) 2)))
           (goto-char (point-max))
           (apply insert strings))))))

  (define (now-ms) (let ([t (current-time)]) (+ (* 1000 (time-second t)) (quotient (time-nanosecond t) 1000000))))

  ;; Runs `git ARGS...` in directory ROOT. Returns a promise of (code stdout stderr); the command
  ;; and its result go to *git-process*. Git never prompts or opens an editor: a command that needs
  ;; either fails and says so in stderr.
  (define (run-git root args . rest)
    (let* ([extra (if (null? rest) '() (car rest))]
           [argv (append (list (git-executable) "-c" "core.quotepath=false" "--no-pager") args)]
           [start (now-ms)]
           [result (make-promise)])
      (log! "$ git " (apply string-append (map (lambda (a) (string-append a " ")) args))
            "  (" root ")\n")
      (promise-then
       (run-process argv
                    (append `((cwd . ,root)
                              (env . (("GIT_TERMINAL_PROMPT" . "0") ("GIT_OPTIONAL_LOCKS" . "0")
                                      ("GIT_EDITOR" . "true") ("GIT_PAGER" . "cat")
                                      ("LC_MESSAGES" . "C"))))
                            extra))
       (lambda (done)
         (define r (promise-value done))
         (log! (cadr r) (if (string=? (caddr r) "") "" (caddr r))
               (format "[exit ~a, ~a ms]\n\n" (car r) (- (now-ms) start)))
         (promise-resolve! result r)))
      result))

  ;; The top directory of the repository containing DIR, or #f. Looks for a .git entry upward, so
  ;; it needs no process.
  (define (git-root dir)
    (let loop ([d (let ([s dir]) (if (and (> (string-length s) 1) (char=? (string-ref s (- (string-length s) 1)) #\/))
                                     (substring s 0 (- (string-length s) 1))
                                     s))])
      (cond [(file-info-or-false (string-append d "/.git")) (if (string=? d "") "/" d)]
            [(or (string=? d "") (string=? d "/")) #f]
            [else (let ([up (let find ([i (- (string-length d) 1)])
                              (cond [(< i 0) ""] [(char=? (string-ref d i) #\/) (substring d 0 i)]
                                    [else (find (- i 1))]))])
                    (loop up))])))

  (define (file-info-or-false path)
    (guard (e [#t #f]) (file-attributes path)))

  ;; ---- status ----

  (define-record-type (git-status-record make-git-status git-status?)
    (fields (immutable root git-status-root) (immutable head git-status-head)
            (immutable oid git-status-oid) (immutable upstream git-status-upstream)
            (immutable ahead git-status-ahead) (immutable behind git-status-behind)
            (immutable changes git-status-changes))
    (nongenerative profane-git-status))

  ;; index and worktree are the status letters of `git status` (#\. : unchanged), kind is one of
  ;; changed, untracked, unmerged.
  (define-record-type git-change
    (fields path orig index worktree kind)
    (nongenerative profane-git-change))

  (define (git-status-staged st)
    (filter (lambda (c) (and (eq? (git-change-kind c) 'changed) (not (char=? (git-change-index c) #\.))))
            (git-status-changes st)))
  (define (git-status-unstaged st)
    (filter (lambda (c) (and (eq? (git-change-kind c) 'changed) (not (char=? (git-change-worktree c) #\.))))
            (git-status-changes st)))
  (define (git-status-untracked st)
    (filter (lambda (c) (eq? (git-change-kind c) 'untracked)) (git-status-changes st)))
  (define (git-status-unmerged st)
    (filter (lambda (c) (eq? (git-change-kind c) 'unmerged)) (git-status-changes st)))

  ;; Field I (0-based) of the space-separated line, with the rest of the line from field N-1 on as
  ;; one last field (paths may contain spaces).
  (define (fields-of line n)
    (let loop ([i 0] [start 0] [out '()] [k 1])
      (cond [(= k n) (reverse (cons (substring line start (string-length line)) out))]
            [(= i (string-length line)) (reverse (cons (substring line start i) out))]
            [(char=? (string-ref line i) #\space)
             (loop (+ i 1) (+ i 1) (cons (substring line start i) out) (+ k 1))]
            [else (loop (+ i 1) start out k)])))

  ;; Parses `git status --porcelain=v2 --branch -z` output.
  (define (parse-git-status root text)
    (let loop ([recs (filter (lambda (r) (not (string=? r ""))) (split-on text #\nul))]
               [head #f] [oid #f] [upstream #f] [ahead 0] [behind 0] [changes '()])
      (define (done)
        (make-git-status root head oid upstream ahead behind (reverse changes)))
      (cond
       [(null? recs) (done)]
       [else
        (let ([r (car recs)])
          (cond
           [(string-prefix? "# branch.head " r)
            (let ([h (substring r 14 (string-length r))])
              (loop (cdr recs) (if (string=? h "(detached)") #f h) oid upstream ahead behind changes))]
           [(string-prefix? "# branch.oid " r)
            (let ([o (substring r 13 (string-length r))])
              (loop (cdr recs) head (if (string=? o "(initial)") #f o) upstream ahead behind changes))]
           [(string-prefix? "# branch.upstream " r)
            (loop (cdr recs) head oid (substring r 18 (string-length r)) ahead behind changes)]
           [(string-prefix? "# branch.ab " r)
            (let ([f (split-on (substring r 12 (string-length r)) #\space)])
              (loop (cdr recs) head oid upstream
                    (string->number (substring (car f) 1 (string-length (car f))))
                    (string->number (substring (cadr f) 1 (string-length (cadr f))))
                    changes))]
           [(string-prefix? "# " r) (loop (cdr recs) head oid upstream ahead behind changes)]
           [(string-prefix? "1 " r)
            (let* ([f (fields-of r 9)] [xy (cadr f)])
              (loop (cdr recs) head oid upstream ahead behind
                    (cons (make-git-change (list-ref f 8) #f (string-ref xy 0) (string-ref xy 1) 'changed)
                          changes)))]
           [(string-prefix? "2 " r)
            (let* ([f (fields-of r 10)] [xy (cadr f)])
              (loop (if (pair? (cdr recs)) (cddr recs) '()) head oid upstream ahead behind
                    (cons (make-git-change (list-ref f 9) (and (pair? (cdr recs)) (cadr recs))
                                           (string-ref xy 0) (string-ref xy 1) 'changed)
                          changes)))]
           [(string-prefix? "u " r)
            (let* ([f (fields-of r 11)] [xy (cadr f)])
              (loop (cdr recs) head oid upstream ahead behind
                    (cons (make-git-change (list-ref f 10) #f (string-ref xy 0) (string-ref xy 1) 'unmerged)
                          changes)))]
           [(string-prefix? "? " r)
            (loop (cdr recs) head oid upstream ahead behind
                  (cons (make-git-change (substring r 2 (string-length r)) #f #\? #\? 'untracked) changes))]
           [else (loop (cdr recs) head oid upstream ahead behind changes)]))])))

  ;; ---- diff ----

  (define-record-type git-diff-file
    (fields path old-path header hunks binary?)
    (nongenerative profane-git-diff-file))

  ;; header is the "@@ -a,b +c,d @@ context" line; lines are the hunk's lines with their leading
  ;; " ", "+", "-" or "\" kept.
  (define-record-type git-diff-hunk
    (fields header old-start old-len new-start new-len lines)
    (nongenerative profane-git-diff-hunk))

  (define (parse-range s) ; "12,3" or "12" => (values 12 3)
    (let ([p (split-on s #\,)])
      (values (string->number (car p)) (if (null? (cdr p)) 1 (string->number (cadr p))))))

  (define (parse-hunk-header h)
    ;; @@ -a,b +c,d @@ ...
    (let* ([f (split-on h #\space)]
           [old (cadr f)] [new (caddr f)])
      (let-values ([(os ol) (parse-range (substring old 1 (string-length old)))]
                   [(ns nl) (parse-range (substring new 1 (string-length new)))])
        (values os ol ns nl))))

  (define (strip-tab s) (car (split-on s #\tab)))

  (define (header-path header diff-line)
    (define (after prefix)
      (let loop ([hs header])
        (cond [(null? hs) #f]
              [(string-prefix? prefix (car hs))
               (strip-tab (substring (car hs) (string-length prefix) (string-length (car hs))))]
              [else (loop (cdr hs))])))
    (define (strip-ab s) (if (and s (> (string-length s) 2) (member (substring s 0 2) '("a/" "b/")))
                             (substring s 2 (string-length s))
                             s))
    (let ([new (after "+++ ")] [old (after "--- ")])
      (values
       (cond [(and new (not (string=? new "/dev/null"))) (strip-ab new)]
             [(after "rename to ") => values]
             [(and old (not (string=? old "/dev/null"))) (strip-ab old)]
             [else ;; "diff --git a/P b/P" with equal paths
              (let* ([rest (substring diff-line 11 (string-length diff-line))]
                     [l (quotient (- (string-length rest) 5) 2)])
                (if (and (>= l 0) (= (string-length rest) (+ 5 (* 2 l)))) (substring rest 2 (+ 2 l)) rest))])
       (cond [(after "rename from ") => values]
             [else #f]))))

  (define (make-file diff-line header hunks)
    (let-values ([(path old) (header-path header diff-line)])
      (make-git-diff-file path old (reverse header) (reverse hunks)
                          (and (find (lambda (l) (string-prefix? "Binary files " l)) header) #t))))

  (define (make-hunk header lines)
    (let-values ([(os ol ns nl) (parse-hunk-header header)])
      (make-git-diff-hunk header os ol ns nl (reverse lines))))

  ;; Parses unified diff output (git diff --no-color) into git-diff-files.
  (define (parse-git-diff text)
    (let* ([lines (let ([ls (split-on text #\newline)])
                    (if (and (pair? ls) (string=? (car (reverse ls)) "")) (reverse (cdr (reverse ls))) ls))])
      (let loop ([ls lines] [files '()] [dl #f] [header '()] [hunks '()] [hh #f] [hl '()])
        (define (close-hunk) (if hh (cons (make-hunk hh hl) hunks) hunks))
        (define (close-file) (if dl (cons (make-file dl header (close-hunk)) files) files))
        (cond
         [(null? ls) (reverse (close-file))]
         [(string-prefix? "diff --git " (car ls))
          (loop (cdr ls) (close-file) (car ls) (list (car ls)) '() #f '())]
         [(not dl) (loop (cdr ls) files dl header hunks hh hl)]
         [(and (string-prefix? "@@ " (car ls)))
          (loop (cdr ls) files dl header (close-hunk) (car ls) '())]
         [hh (loop (cdr ls) files dl header hunks hh (cons (car ls) hl))]
         [else (loop (cdr ls) files dl (cons (car ls) header) hunks hh hl)]))))

  ;; ---- patches ----
  ;; What staging, unstaging and discarding hunks and lines feed to `git apply`.

  (define (join-lines lines)
    (apply string-append (map (lambda (l) (string-append l "\n")) lines)))

  ;; The patch for the whole of HUNK of FILE (a git-diff-file): the file's header lines, then the
  ;; hunk.
  (define (git-hunk-patch file hunk)
    (string-append (join-lines (git-diff-file-header file))
                   (git-diff-hunk-header hunk) "\n"
                   (join-lines (git-diff-hunk-lines hunk))))

  ;; The patch for only the changed lines FROM (inclusive) to TO (exclusive) of the hunk's lines,
  ;; or #f if none of those lines is a change. The unselected changes are left out as `git add -p`
  ;; does: REVERSE? #f, for applying the patch forward (stage), turns unselected removals into
  ;; context and drops unselected additions; REVERSE? #t, for applying it with -R (unstage,
  ;; discard), keeps unselected additions as context and drops unselected removals.
  (define (git-hunk-region-patch file hunk from to reverse?)
    (let loop ([ls (git-diff-hunk-lines hunk)] [i 0] [out '()] [kept-last #f] [changed #f]
               [old 0] [new 0])
      (if (null? ls)
          (and changed
               (string-append
                (join-lines (git-diff-file-header file))
                (format "@@ -~a,~a +~a,~a @@\n" (git-diff-hunk-old-start hunk) old
                        (git-diff-hunk-new-start hunk) new)
                (join-lines (reverse out))))
          (let* ([l (car ls)]
                 [c (if (string=? l "") #\space (string-ref l 0))]
                 [selected (and (>= i from) (< i to))]
                 [rest (substring l 1 (string-length l))]
                 [next (lambda (line kept? ch old+ new+)
                         (loop (cdr ls) (+ i 1) (if line (cons line out) out) kept?
                               (or changed ch) (+ old old+) (+ new new+)))])
            (case c
              [(#\space) (next l #t #f 1 1)]
              [(#\+) (cond [selected (next l #t #t 0 1)]
                           [reverse? (next (string-append " " rest) #t #f 1 1)]
                           [else (next #f #f #f 0 0)])]
              [(#\-) (cond [selected (next l #t #t 1 0)]
                           [reverse? (next #f #f #f 0 0)]
                           [else (next (string-append " " rest) #t #f 1 1)])]
              [else (if kept-last (next l #t #f 0 0) (next #f #f #f 0 0))])))))

  (define (trim-slash t)
    (if (and (> (string-length t) 1) (char=? (string-ref t (- (string-length t) 1)) #\/))
        (substring t 0 (- (string-length t) 1))
        t))

  ;; Writes TEXT (UTF-8) to a new temporary file and returns its name; $TMPDIR if it can be
  ;; written, else /tmp.
  (define (write-temp-file text)
    (let try ([dirs (append (let ([t (getenv "TMPDIR")]) (if t (list (trim-slash t)) '())) '("/tmp"))])
      (when (null? dirs) (error 'git-apply-patch "no writable temporary directory"))
      (let ([path (format "~a/profane-patch-~a-~a.patch" (car dirs) (now-ms) (random 1000000))])
        (if (guard (e [#t #f])
              (let ([port (open-file-output-port path (file-options no-fail) (buffer-mode block)
                                                 (make-transcoder (utf-8-codec)))])
                (put-string port text)
                (close-port port)
                #t))
            path
            (try (cdr dirs))))))

  ;; Applies PATCH (a string) in ROOT with `git apply --recount` and FLAGS (e.g. ("--cached") or
  ;; ("-R" "--index")); returns a promise of (code stdout stderr) as run-git does. The patch goes
  ;; through a temporary file, removed afterwards.
  (define (git-apply-patch root patch flags)
    (let ([path (write-temp-file patch)] [result (make-promise)])
      (promise-then (run-git root (append '("apply" "--recount") flags (list path)))
                    (lambda (done)
                      (guard (e [#t #t]) (delete-file path))
                      (promise-resolve! result (promise-value done))))
      result))

  ;; ---- log ----

  (define-record-type git-commit
    (fields hash short subject author date refs)
    (nongenerative profane-git-commit))

  (define log-format "--format=%x1e%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1f%D")

  ;; Parses `git log` output in log-format.
  (define (parse-git-log text)
    (let loop ([recs (cdr (split-on text #\x1e))] [out '()])
      (if (null? recs)
          (reverse out)
          (let ([f (split-on (drop-right-char (car recs) #\newline) #\x1f)])
            (loop (cdr recs)
                  (if (= (length f) 6)
                      (cons (make-git-commit (list-ref f 0) (list-ref f 1) (list-ref f 2) (list-ref f 3)
                                             (list-ref f 4) (list-ref f 5))
                            out)
                      out))))))

  ;; ---- backends ----

  (define backends (make-eq-hashtable))

  ;; A backend is an alist of (status . (lambda (root) ...)), (diff . (lambda (root staged? paths)
  ;; ...)) and (log . (lambda (root range limit) ...)); they run inside a command and may await.
  (define (define-git-backend! name procs) (hashtable-set! backends name procs))
  (define (git-backend-names) (vector->list (hashtable-keys backends)))

  (define (backend-proc which)
    (let* ([name (var-ref 'git-read-backend)]
           [b (hashtable-ref backends name #f)])
      (unless b (error 'git "no such git read backend" name))
      (cdr (assq which b))))

  (define (git-status root) ((backend-proc 'status) root))
  ;; The commits of RANGE (a revision or "a..b"; #f: HEAD), newest first, at most LIMIT. A
  ;; repository without commits, or a bad range, gives ().
  (define (git-log root range limit) ((backend-proc 'log) root range limit))

  (define (git-diff root staged? . rest) ((backend-proc 'diff) root staged? (if (null? rest) '() (car rest))))

  (define (cli-status root)
    (let ([r (await (run-git root '("status" "--porcelain=v2" "--branch" "-z" "--untracked-files=normal")))])
      (unless (zero? (car r)) (error 'git-status (caddr r)))
      (parse-git-status root (cadr r))))

  (define (cli-diff root staged? paths)
    (let ([r (await (run-git root (append '("diff" "--no-color" "--no-ext-diff" "--src-prefix=a/" "--dst-prefix=b/" "-U3")
                                          (if staged? '("--cached") '())
                                          (if (null? paths) '() (cons "--" paths)))))])
      (unless (zero? (car r)) (error 'git-diff (caddr r)))
      (parse-git-diff (cadr r))))

  (define (cli-log root range limit)
    (let ([r (await (run-git root (list "log" (format "-n~a" limit) log-format "--no-show-signature"
                                        (or range "HEAD") "--")))])
      (if (zero? (car r)) (parse-git-log (cadr r)) '())))

  (define cli-backend
    (begin (define-git-backend! 'cli (list (cons 'status cli-status) (cons 'diff cli-diff)
                                           (cons 'log cli-log)))
           #t)))
