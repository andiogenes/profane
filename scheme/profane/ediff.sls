;;; (profane ediff) — two buffers side by side with their differences, after Emacs's ediff. Unstable
;;; API (plan §10, §8m).
;;;
;;;   M-x ediff-buffers, ediff-files           compare two buffers or files
;;;   e in the status buffer                   the file at point: work tree against the index
;;;                                            (unstaged), or the index against HEAD (staged)
;;;
;;; The window is split in two: A on the left, B on the right. Both show copies of the buffers
;;; with filler lines where one side has fewer, so a difference occupies the same rows on both
;;; sides and the two scroll together. Changed lines are tinted, the current difference stronger,
;;; with the words that changed inside it emphasized. The differences come from
;;; `git diff --no-index`, so git is the only diff engine.
;;;
;;;   n SPC   next difference           p DEL   previous difference
;;;   a       copy A's lines of this difference into B       b   copy B's into A
;;;   #       toggle ignoring whitespace      !   compare again      q   quit
;;;
;;; Copying edits the original buffer (undo works there); a buffer that is read-only (a version
;;; from the index) refuses. Two-way only: a three-way merge is not implemented.

(library (profane ediff)
  (export ediff-start)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane keymap) (profane mode) (profane var) (profane face) (profane display)
          (profane hook) (profane files) (profane minibuffer) (profane async) (profane git)
          (profane git status) (profane section) (profane simple))

  (defvar ediff-filler-width 300 "Columns of the filler lines that keep both sides aligned.")
  (defvar ediff-session #f "The ediff session a view buffer belongs to." '(local))

  (define ediff-faces
    (begin
      (for-each (lambda (f) (define-face (car f) (cadr f) (caddr f)))
                '((ediff-changed-a () "Lines of A that differ from B.")
                  (ediff-changed-b () "Lines of B that differ from A.")
                  (ediff-current-a () "The current difference in A.")
                  (ediff-current-b () "The current difference in B.")
                  (ediff-refined-a () "The words that changed in the current difference, in A.")
                  (ediff-refined-b () "The words that changed in the current difference, in B.")
                  (ediff-filler () "Filler lines keeping the two sides aligned.")))
      #t))

  (define-major-mode ediff-mode fundamental-mode "Ediff" "Major mode of the buffers an ediff session shows.")

  ;; ---- sessions ----

  ;; hunks: a vector of hunk records. views and positions are rebuilt by render!.
  (define-record-type session
    (fields src-a src-b name-a name-b (mutable va) (mutable vb) (mutable wa) (mutable wb)
            (mutable hunks) (mutable current) (mutable ignore-ws) origin owned
            (mutable starts-a) (mutable starts-b) (mutable synced))
    (nongenerative profane-ediff-session))

  ;; a0 la: lines of A, b0 lb: lines of B (0-based, in the sources); row: the first view row,
  ;; height: rows it takes in the views.
  (define-record-type hunk (fields a0 la b0 lb row height))

  (define sessions '())

  (define (split-lines text)
    (if (string=? text "")
        '()
        (let loop ([i 0] [start 0] [out '()])
          (cond [(= i (string-length text))
                 (reverse (if (> i start) (cons (substring text start i) out) out))]
                [(char=? (string-ref text i) #\newline)
                 (loop (+ i 1) (+ i 1) (cons (substring text start i) out))]
                [else (loop (+ i 1) start out)]))))

  (define (buffer-text b) (with-current-buffer b (buffer-substring (point-min) (point-max))))

  ;; ---- the differences ----

  ;; The hunks between the texts of A and B, as lists (a0 la b0 lb), from git.
  (define (compute-hunks text-a text-b ignore-ws)
    (let* ([fa (git-write-temp-file text-a)] [fb (git-write-temp-file text-b)]
           [r (await (run-git "/" (append '("diff" "--no-index" "--no-color" "-U0")
                                          (if ignore-ws '("-w") '())
                                          (list "--" fa fb))))])
      (guard (e [#t #t]) (delete-file fa))
      (guard (e [#t #t]) (delete-file fb))
      (unless (memv (car r) '(0 1))
        (error 'ediff (let ([m (caddr r)]) (if (string=? m "") "git diff failed" m))))
      (let ([files (parse-git-diff (cadr r))])
        (when (and (pair? files) (git-diff-file-binary? (car files)))
          (error 'ediff "binary files differ"))
        (if (null? files)
            '()
            (map (lambda (h)
                   (let ([ol (git-diff-hunk-old-len h)] [nl (git-diff-hunk-new-len h)])
                     (list (if (zero? ol) (git-diff-hunk-old-start h) (- (git-diff-hunk-old-start h) 1)) ol
                           (if (zero? nl) (git-diff-hunk-new-start h) (- (git-diff-hunk-new-start h) 1)) nl)))
                 (git-diff-file-hunks (car files)))))))

  ;; ---- the views ----

  (define (filler) (make-string (var-ref 'ediff-filler-width) #\space))

  ;; Fills the two view buffers with the aligned lines; returns the hunk records.
  (define (render! s)
    (let* ([ta (buffer-text (session-src-a s))] [tb (buffer-text (session-src-b s))]
           [lines-a (list->vector (split-lines ta))] [lines-b (list->vector (split-lines tb))]
           [raw (compute-hunks ta tb (session-ignore-ws s))]
           [out-a (open-output-string)] [out-b (open-output-string)]
           [fill (filler)])
      (define (emit-line! port line) (put-string port line) (put-string port "\n"))
      (let loop ([hs raw] [ia 0] [ib 0] [row 0] [acc '()])
        (cond
         [(null? hs)
          ;; what follows the last difference is the same on both sides
          (do ([i ia (+ i 1)]) ((>= i (vector-length lines-a)))
            (emit-line! out-a (vector-ref lines-a i)))
          (do ([i ib (+ i 1)]) ((>= i (vector-length lines-b)))
            (emit-line! out-b (vector-ref lines-b i)))
          (session-hunks-set! s (list->vector (reverse acc)))]
         [else
          (let* ([h (car hs)] [a0 (car h)] [la (cadr h)] [b0 (caddr h)] [lb (cadddr h)]
                 [common (- a0 ia)] [height (max la lb)])
            (do ([k 0 (+ k 1)]) ((= k common))
              (emit-line! out-a (vector-ref lines-a (+ ia k)))
              (emit-line! out-b (vector-ref lines-b (+ ib k))))
            (do ([k 0 (+ k 1)]) ((= k height))
              (emit-line! out-a (if (< k la) (vector-ref lines-a (+ a0 k)) fill))
              (emit-line! out-b (if (< k lb) (vector-ref lines-b (+ b0 k)) fill)))
            (loop (cdr hs) (+ a0 la) (+ b0 lb) (+ row common height)
                  (cons (make-hunk a0 la b0 lb (+ row common) height) acc)))]))
      (fill-view! (session-va s) (get-output-string out-a) s 'a)
      (fill-view! (session-vb s) (get-output-string out-b) s 'b)))

  (define (fill-view! b text s side)
    (with-current-buffer b
      (set-buffer-read-only! #f)
      (erase-buffer)
      (insert text)
      (set-buffer-read-only! #t)
      (set-buffer-unmodified!)
      ;; the start of every row
      (let ([starts (let loop ([pos 0] [acc '()])
                      (if (>= pos (buffer-size))
                          (list->vector (reverse acc))
                          (begin (goto-char pos)
                                 (forward-line 1)
                                 (loop (point) (cons pos acc)))))])
        (if (eq? side 'a) (session-starts-a-set! s starts) (session-starts-b-set! s starts)))
      (goto-char 0))
    ;; the faces of every difference
    (let ([hunks (session-hunks s)])
      (do ([i 0 (+ i 1)]) ((= i (vector-length hunks)))
        (paint-hunk! s i (eqv? i (session-current s))))))

  (define (row-start s side row)
    (let ([starts (if (eq? side 'a) (session-starts-a s) (session-starts-b s))])
      (if (< row (vector-length starts)) (vector-ref starts row) (with-current-buffer (if (eq? side 'a) (session-va s) (session-vb s)) (point-max)))))

  ;; Colors the rows of difference I on both sides: its own lines tinted, the filler rows as such,
  ;; and, for the current one, the words that changed.
  (define (paint-hunk! s i current?)
    (let* ([h (vector-ref (session-hunks s) i)] [row (hunk-row h)] [height (hunk-height h)]
           [la (hunk-la h)] [lb (hunk-lb h)])
      (define (paint-side! side count tint-face)
        (let ([b (if (eq? side 'a) (session-va s) (session-vb s))])
          (with-current-buffer b
            (with-inhibit-read-only
             (lambda ()
               (do ([k 0 (+ k 1)]) ((= k height))
                 (let ([from (row-start s side (+ row k))] [to (row-start s side (+ row k 1))])
                   (put-text-property from (max from (- to 1))
                                      'face (if (< k count) tint-face 'ediff-filler)))))))))
      (paint-side! 'a la (if current? 'ediff-current-a 'ediff-changed-a))
      (paint-side! 'b lb (if current? 'ediff-current-b 'ediff-changed-b))
      (when (and current? (> la 0) (> lb 0))
        (let* ([lines-a (let loop ([k 0] [acc '()])
                          (if (= k la) (reverse acc) (loop (+ k 1) (cons (row-text s 'a (+ row k)) acc))))]
               [lines-b (let loop ([k 0] [acc '()])
                          (if (= k lb) (reverse acc) (loop (+ k 1) (cons (row-text s 'b (+ row k)) acc))))]
               [ranges (git-refine-lines (append (map (lambda (l) (string-append "-" l)) lines-a)
                                                 (map (lambda (l) (string-append "+" l)) lines-b)))])
          (for-each (lambda (k r)
                      (for-each (lambda (rg)
                                  (with-current-buffer (session-va s)
                                    (with-inhibit-read-only
                                     (lambda ()
                                       (let ([from (row-start s 'a (+ row k))])
                                         (put-text-property (+ from (- (car rg) 1)) (+ from (- (cdr rg) 1)) 'face 'ediff-refined-a))))))
                                r))
                    (iota la) (list-head ranges la))
          (for-each (lambda (k r)
                      (for-each (lambda (rg)
                                  (with-current-buffer (session-vb s)
                                    (with-inhibit-read-only
                                     (lambda ()
                                       (let ([from (row-start s 'b (+ row k))])
                                         (put-text-property (+ from (- (car rg) 1)) (+ from (- (cdr rg) 1)) 'face 'ediff-refined-b))))))
                                r))
                    (iota lb) (list-tail ranges la))))))

  (define (row-text s side row)
    (let ([b (if (eq? side 'a) (session-va s) (session-vb s))])
      (with-current-buffer b
        (buffer-substring (row-start s side row) (- (row-start s side (+ row 1)) 1)))))

  ;; ---- windows and scrolling ----

  (define (show-current! s)
    (let ([h (current-hunk s)])
      (when h
        (for-each (lambda (w side)
                    (when (window-live? w)
                      (set-window-point! w (row-start s side (hunk-row h)))
                      (set-window-start-line! w (max 0 (- (hunk-row h) 2)))))
                  (list (session-wa s) (session-wb s)) '(a b)))))

  (define (current-hunk s)
    (let ([hs (session-hunks s)] [i (session-current s)])
      (and i (< -1 i (vector-length hs)) (vector-ref hs i))))

  (define (announce! s)
    (let ([n (vector-length (session-hunks s))])
      (if (zero? n)
          (message "No differences")
          (message "Difference ~a of ~a" (+ 1 (session-current s)) n))))

  (define (goto-hunk! s i)
    (let ([n (vector-length (session-hunks s))])
      (when (> n 0)
        (let ([old (session-current s)] [new (max 0 (min (- n 1) i))])
          (when (and old (< old n)) (paint-hunk! s old #f))
          (session-current-set! s new)
          (paint-hunk! s new #t)
          (show-current! s)
          (announce! s)))))

  ;; Keeps the two windows on the same rows: whichever the user scrolls or moves in, the other
  ;; follows.
  (define (sync-sessions! f)
    (for-each
     (lambda (s)
       (let* ([wa (session-wa s)] [wb (session-wb s)]
              [sel (selected-window)])
         (when (and (window-live? wa) (window-live? wb) (or (eq? sel wa) (eq? sel wb)))
           (let* ([from (if (eq? sel wa) wa wb)] [to (if (eq? sel wa) wb wa)]
                  [side (if (eq? sel wa) 'a 'b)] [other (if (eq? sel wa) 'b 'a)]
                  [line (with-current-buffer (window-buffer from)
                          (line-number-at-pos (point)))]
                  [key (cons line (window-start-line from))])
             (unless (equal? key (session-synced s))
               (session-synced-set! s key)
               (set-window-start-line! to (window-start-line from))
               (set-window-point! to (row-start s other (- line 1))))))))
     sessions))

  (define sync-hook (begin (add-hook! 'pre-redisplay-hook sync-sessions!) #t))

  ;; ---- starting and stopping ----

  (define (view-name side s)
    (format "*ediff ~a: ~a*" (if (eq? side 'a) "A" "B") (if (eq? side 'a) (session-name-a s) (session-name-b s))))

  ;; Compares buffers A and B. OWNED are temporary buffers to kill when the session ends.
  (define (ediff-start a b name-a name-b owned)
    (let* ([origin (current-buffer)]
           [s (make-session a b name-a name-b #f #f #f #f (vector) #f #f origin owned
                            (vector) (vector) #f)])
      (session-va-set! s (get-buffer-create (format "*ediff A: ~a*" name-a)))
      (session-vb-set! s (get-buffer-create (format "*ediff B: ~a*" name-b)))
      (for-each (lambda (v)
                  (with-current-buffer v
                    (set-major-mode! 'ediff-mode)
                    (buffer-disable-undo)
                    (var-set! 'display-line-numbers #f)
                    (var-set! 'ediff-session s)))
                (list (session-va s) (session-vb s)))
      (render! s)
      (cond
       [(zero? (vector-length (session-hunks s)))
        (for-each kill-buffer (list (session-va s) (session-vb s)))
        (for-each (lambda (o) (when (buffer-live? o) (kill-buffer o))) owned)
        (message "No differences")]
       [else
        (set! sessions (cons s sessions))
        (let* ([wa (selected-window)] [wb (split-window wa 'right)])
          (session-wa-set! s wa)
          (session-wb-set! s wb)
          (set-window-buffer! wa (session-va s))
          (set-window-buffer! wb (session-vb s))
          (select-window wa)
          (session-current-set! s 0)
          (paint-hunk! s 0 #t)
          (show-current! s)
          (announce! s))])
      s))

  (define (finish! s)
    (set! sessions (remq s sessions))
    (let ([wb (session-wb s)] [wa (session-wa s)])
      (when (and (window-live? wb) (> (length (window-list)) 1)) (delete-window wb))
      (when (window-live? wa) (select-window wa)))
    (for-each (lambda (b) (when (buffer-live? b) (kill-buffer b)))
              (append (list (session-va s) (session-vb s)) (session-owned s)))
    (when (buffer-live? (session-origin s)) (switch-to-buffer (session-origin s))))

  (define (current-session)
    (or (var-ref 'ediff-session) (error 'ediff "not in an ediff session")))

  ;; ---- commands ----

  (define (move! delta)
    (let* ([s (current-session)] [n (vector-length (session-hunks s))] [i (session-current s)])
      (cond [(zero? n) (message "No differences")]
            [(and (> delta 0) (>= i (- n 1))) (message "At the last difference")]
            [(and (< delta 0) (<= i 0)) (message "At the first difference")]
            [else (goto-hunk! s (+ i delta))])))

  (define-command (ediff-next-difference) "Go to the next difference." (move! 1))
  (define-command (ediff-previous-difference) "Go to the previous difference." (move! -1))

  (define (rerender! s keep)
    (render! s)
    (let ([n (vector-length (session-hunks s))])
      (cond [(zero? n) (message "No differences left")
                       (session-current-set! s #f)]
            [else (session-current-set! s #f)
                  (goto-hunk! s keep)])))

  ;; Replaces the lines the current difference covers in the target with the other side's.
  (define (copy! from-side)
    (let* ([s (current-session)] [h (current-hunk s)])
      (unless h (error 'ediff "no difference here"))
      (let* ([to-side (if (eq? from-side 'a) 'b 'a)]
             [src-from (if (eq? from-side 'a) (session-src-a s) (session-src-b s))]
             [src-to (if (eq? from-side 'a) (session-src-b s) (session-src-a s))]
             [from0 (if (eq? from-side 'a) (hunk-a0 h) (hunk-b0 h))]
             [fromn (if (eq? from-side 'a) (hunk-la h) (hunk-lb h))]
             [to0 (if (eq? from-side 'a) (hunk-b0 h) (hunk-a0 h))]
             [ton (if (eq? from-side 'a) (hunk-lb h) (hunk-la h))]
             [lines (let ([all (split-lines (buffer-text src-from))])
                      (list-head (list-tail all from0) fromn))]
             [keep (session-current s)])
        (when (with-current-buffer src-to (buffer-read-only?))
          (error 'ediff (format "buffer ~a is read-only" (if (eq? to-side 'a) "A" "B"))))
        (with-current-buffer src-to
          (undo-boundary)
          (goto-char (point-min))
          (forward-line to0)
          (let ([start (point)])
            (forward-line ton)
            (delete-region start (point))
            (goto-char start)
            (insert (apply string-append (map (lambda (l) (string-append l "\n")) lines)))))
        (rerender! s keep))))

  (define-command (ediff-copy-a-to-b) "Copy A's lines of this difference into B." (copy! 'a))
  (define-command (ediff-copy-b-to-a) "Copy B's lines of this difference into A." (copy! 'b))

  (define-command (ediff-recompute) "Compare the buffers again."
    (let ([s (current-session)]) (rerender! s (or (session-current s) 0))))

  (define-command (ediff-toggle-whitespace) "Toggle ignoring whitespace in the comparison."
    (let ([s (current-session)])
      (session-ignore-ws-set! s (not (session-ignore-ws s)))
      (rerender! s 0)
      (message "Whitespace is ~a" (if (session-ignore-ws s) "ignored" "significant"))))

  (define-command (ediff-quit) "Leave ediff." (finish! (current-session)))

  ;; ---- ways in ----

  (define (buffer-title b) (buffer-name b))

  (define-command (ediff-buffers)
    "Compare two buffers."
    (let ([names (map buffer-name (filter (lambda (b) (not (char=? (string-ref (buffer-name b) 0) #\space))) (buffer-list)))])
      (completing-read "Buffer A: " names
                       (lambda (na)
                         (completing-read "Buffer B: " names
                                          (lambda (nb)
                                            (ediff-start (get-buffer na) (get-buffer nb) na nb '())))))))

  (define-command (ediff-files)
    "Compare two files."
    (read-file-name "File A: "
                    (lambda (pa)
                      (read-file-name "File B: "
                                      (lambda (pb)
                                        (let ([a (find-file-noselect pa)] [b (find-file-noselect pb)])
                                          (ediff-start a b (file-name-nondirectory pa) (file-name-nondirectory pb) '())))))))

  ;; A read-only buffer holding git's version of PATH: REV is "HEAD" or "" (the index). A file that
  ;; does not exist there (new) gives an empty buffer.
  (define (version-buffer root rev path)
    (let* ([r (await (run-git root (list "show" (string-append rev ":" path))))]
           [b (generate-new-buffer (format "~a (~a)" path (if (string=? rev "") "index" rev)))])
      (with-current-buffer b
        (when (zero? (car r)) (insert (cadr r)))
        (set-buffer-unmodified!)
        (set-buffer-read-only! #t))
      b))

  (define-command (magit-ediff-dwim)
    "Compare the file at point: the work tree against the index, or the index against HEAD."
    (let* ([s (section-at-point)] [item (and s (section-value s))])
      (unless (and item (git-item? item) (memq (git-item-kind item) '(file hunk)) (memq (git-item-area item) '(unstaged staged)))
        (error 'magit-ediff "point is not on a changed file"))
      (let* ([root (var-ref 'git-repo-root)] [path (git-item-path item)])
        (if (eq? (git-item-area item) 'unstaged)
            (let ([idx (version-buffer root "" path)]
                  [wt (find-file-noselect (string-append root "/" path))])
              (ediff-start idx wt (format "~a (index)" path) (format "~a (work tree)" path) (list idx)))
            (let ([head (version-buffer root "HEAD" path)] [idx (version-buffer root "" path)])
              (ediff-start head idx (format "~a (HEAD)" path) (format "~a (index)" path) (list head idx)))))))

  (define bindings
    (begin
      (for-each (lambda (b) (define-key! (mode-keymap 'ediff-mode) (car b) (cdr b)))
                '(("n" . ediff-next-difference) ("SPC" . ediff-next-difference)
                  ("p" . ediff-previous-difference) ("DEL" . ediff-previous-difference)
                  ("a" . ediff-copy-a-to-b) ("b" . ediff-copy-b-to-a)
                  ("!" . ediff-recompute) ("#" . ediff-toggle-whitespace) ("q" . ediff-quit)))
      (define-key! (mode-keymap 'git-status-mode) "e" 'magit-ediff-dwim)
      #t)))
