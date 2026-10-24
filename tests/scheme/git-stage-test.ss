(import (chezscheme) (srfi :64) (profane buffer) (profane keymap) (profane command)
        (profane command-loop) (profane async) (profane mode) (profane var) (profane window)
        (profane display) (profane themes) (profane files) (profane minibuffer) (profane complete)
        (profane simple) (profane section) (profane git) (profane git status))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane files) (profane minibuffer) (profane complete) (profane section)
                           (profane git) (profane git status)))

(test-begin "git-stage")

(define (settle!)
  (let loop ([n 0])
    (when (and (command-busy?) (< n 2000))
      (async-poll! 5)
      (resume-busy!)
      (loop (+ n 1)))))
(define (keys . ks) (for-each (lambda (k) (for-each handle-key (kbd k)) (settle!)) ks))
(define (type s) (string-for-each (lambda (c) (handle-text (string c))) s))
(define (text) (buffer-substring 0 (buffer-size)))
(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))
(define (sh fmt . args) (system (apply format fmt args)))

(define dir (let ([p (format "/tmp/pf-gstage-~a" (random 1000000000))])
              (sh "rm -rf ~a; mkdir -p ~a" p p)
              p))
(define (git . args) (sh "cd ~a && git -c user.email=t@t -c user.name=t ~a >/dev/null 2>&1" dir
                         (apply string-append (map (lambda (a) (format "'~a' " a)) args))))
(define (out . args) (cadr (await (run-git dir args))))
(define (file-text name) (call-with-input-file (string-append dir "/" name) get-string-all))
(sh "cd ~a && git init -q -b main" dir)
(sh "cd ~a && printf 'a\\nb\\nc\\nd\\ne\\nf\\ng\\nh\\ni\\nj\\nk\\nl\\n' > p.txt && printf 'x\\n' > q.txt && printf 'y\\n' > r.txt" dir)
(git "add" "-A")
(git "commit" "-m" "init")
(sh "cd ~a && sed -i '' 's/^b$/B/; s/^c$/C/; s/^l$/L/' p.txt && printf 'X\\n' >> q.txt && printf 'u\\n' > untracked.txt" dir)

(define f (select-frame (make-headless-frame 800 800)))
(var-set! 'default-directory (string-append dir "/"))
(keys "C-x g")
(define b (current-buffer))

(define (find-section pred)
  (let ([found #f])
    (section-walk (sections) (lambda (s) (when (and (not found) (pred s)) (set! found s))))
    found))
(define (item-of s) (section-value s))
(define (goto-section! pred) (goto-char (section-start (find-section pred))) )
(define (is? kind area path)
  (lambda (s) (let ([v (item-of s)])
                (and v (git-item? v) (eq? (git-item-kind v) kind) (eq? (git-item-area v) area)
                     (or (not path) (equal? (git-item-path v) path))))))
(define (hunk-n area path n)
  (let ([hs (filter (is? 'hunk area path) (let ([all '()]) (section-walk (sections) (lambda (s) (set! all (cons s all)))) (reverse all)))])
    (list-ref hs n)))

;; ---- stage a hunk ----
(goto-char (section-start (hunk-n 'unstaged "p.txt" 1)))          ; the "L" hunk
(keys "s")
(test-assert "s on a hunk stages it" (and (contains? (out "diff" "--cached") "+L") (not (contains? (out "diff" "--cached") "+B"))))
(test-assert "and the buffer shows it under Staged changes" (contains? (text) "Staged changes (1)"))
(test-assert "the other hunk is still unstaged" (contains? (out "diff") "+B"))

;; ---- unstage it ----
(goto-char (section-start (hunk-n 'staged "p.txt" 0)))
(keys "u")
(test-equal "u on a staged hunk unstages it" "" (out "diff" "--cached"))
(test-assert "the buffer has no Staged changes" (not (contains? (text) "Staged changes")))

;; ---- a file ----
(goto-char (section-start (find-section (is? 'file 'unstaged "q.txt"))))
(keys "s")
(test-equal "s on a file stages it" "q.txt\n" (out "diff" "--cached" "--name-only"))
(goto-char (section-start (find-section (is? 'file 'staged "q.txt"))))
(keys "u")
(test-equal "u on the file unstages it" "" (out "diff" "--cached" "--name-only"))

;; ---- an untracked file ----
(goto-char (section-start (find-section (is? 'untracked 'untracked "untracked.txt"))))
(keys "s")
(test-assert "s on an untracked file adds it" (contains? (out "status" "--porcelain") "A  untracked.txt"))
(goto-char (section-start (find-section (is? 'file 'staged "untracked.txt"))))
(keys "u")
(test-assert "and u puts it back" (contains? (out "status" "--porcelain") "?? untracked.txt"))

;; ---- region: only some lines of a hunk ----
(let* ([h (hunk-n 'unstaged "p.txt" 0)])
  ;; hunk lines: " a" "-b" "-c" "+B" "+C" " d" ...; select "+C" alone
  (goto-char (section-start h))
  (forward-line 5)                       ; "+C"
  (test-equal "on the +C line" "+C" (buffer-substring (point) (+ (point) 2)))
  (set-mark! (point))
  (var-set! 'mark-active #t)
  (forward-line 1)                       ; region covers exactly that line
  (keys "s")
  (let ([staged (out "diff" "--cached" "-U0")])
    (test-assert "the region stages just its lines" (and (contains? staged "+C") (not (contains? staged "+B")) (not (contains? staged "-b")))))
  (test-assert "the region is not active any more" (not (var-ref 'mark-active)))
  (test-assert "the rest of the hunk stays unstaged" (let ([u (out "diff" "-U0")]) (and (contains? u "+B") (contains? u "-b") (contains? u "-c")))))

;; unstage a region of the staged hunk
(let* ([h (hunk-n 'staged "p.txt" 0)])
  (goto-char (section-start h))
  (forward-line 1)
  (set-mark! (point))
  (var-set! 'mark-active #t)
  (forward-line 10)
  (keys "u")
  (test-equal "u with a region over the whole hunk unstages it" "" (out "diff" "--cached")))

;; ---- discard ----
(goto-char (section-start (hunk-n 'unstaged "p.txt" 1)))          ; the L hunk
(keys "k")
(test-assert "k asks first" (minibuffer-active?))
(type "n")
(keys "RET")
(test-assert "n cancels: the change is still there" (contains? (file-text "p.txt") "L"))
(keys "k")
(type "y")
(keys "RET")
(test-assert "y discards the hunk: L is gone, B stays"
             (let ([t (file-text "p.txt")]) (and (not (contains? t "L")) (contains? t "B"))))
(goto-char (section-start (find-section (is? 'file 'unstaged "q.txt"))))
(keys "k")
(type "y")
(keys "RET")
(test-equal "discarding a file restores it" "x\n" (file-text "q.txt"))
(goto-char (section-start (find-section (is? 'untracked 'untracked "untracked.txt"))))
(keys "k")
(type "y")
(keys "RET")
(test-assert "discarding an untracked file deletes it" (not (file-exists? (string-append dir "/untracked.txt"))))

;; a region discard of one line (worktree)
(let ([h (hunk-n 'unstaged "p.txt" 0)])
  (goto-char (section-start h))
  (forward-line 4)                       ; "+B"
  (test-equal "on the +B line" "+B" (buffer-substring (point) (+ (point) 2)))
  (set-mark! (point))
  (var-set! 'mark-active #t)
  (forward-line 1)
  (keys "k")
  (type "y")
  (keys "RET")
  (test-assert "the selected added line is gone, the other changes stay"
               (let ([t (file-text "p.txt")]) (and (not (contains? t "B")) (contains? t "C")))))

;; ---- S and U ----
(sh "cd ~a && printf 'X\\n' >> q.txt && printf 'Y\\n' >> r.txt" dir)
(keys "g")
(keys "S")
(test-assert "S stages every tracked change" (let ([n (out "diff" "--cached" "--name-only")]) (and (contains? n "q.txt") (contains? n "r.txt") (contains? n "p.txt"))))
(keys "U")
(test-equal "U unstages everything" "" (out "diff" "--cached" "--name-only"))

;; ---- errors leave things alone ----
(goto-char (section-start (find-section (is? 'file 'unstaged "q.txt"))))
(keys "s")
(goto-char (section-start (find-section (is? 'file 'staged "q.txt"))))
(keys "s")
(test-assert "s on something staged is an error, nothing changes" (contains? (out "diff" "--cached" "--name-only") "q.txt"))
(goto-char (section-start (find-section (is? 'file 'staged "q.txt"))))
(keys "k")
(test-assert "k on a file asks even when staged" (minibuffer-active?))
(type "y")
(keys "RET")
(test-equal "discarding a staged file restores it from HEAD" "x\n" (file-text "q.txt"))
(test-equal "and nothing is staged" "" (out "diff" "--cached" "--name-only"))

(sh "rm -rf ~a" dir)
(delete-headless-frame! f)
(test-end "git-stage")
(test-exit)
