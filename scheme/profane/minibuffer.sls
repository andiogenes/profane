;;; (profane minibuffer) — reading input in the minibuffer window, with completion. Unstable API
;;; (plan §10).
;;;
;;;   (read-from-minibuffer prompt k [initial option value ...])   ; k receives the string
;;;   (completing-read prompt collection k option value ...)
;;;
;;; Input is callback-based, not blocking: keys arrive one at a time from the shell, so a command
;;; that needs input passes what to do with it (plan §0's `await` can wrap this later). K runs
;;; after the minibuffer has closed and the selected window's buffer is current again. C-g
;;; closes it without calling K (and runs the `quit` option, if any). One minibuffer at a time;
;;; asking for another while one is open is an error, as with Emacs's
;;; enable-recursive-minibuffers off.
;;;
;;; The minibuffer is a buffer shown in the minibuffer window: the prompt (read-only in effect:
;;; the editing commands refuse to cross it), then the input on the first line. With completion
;;; the candidates follow, one per line, vertico style (`vertico-count` rows, the selected one
;;; in the `highlight` face). COLLECTION is a list of strings (or symbols), or a procedure from
;;; the input to a list of candidates, which is how async or dynamic sources plug in. Options:
;;;
;;;   initial STRING      input to start with
;;;   require-match #t    RET on input matching no candidate is refused
;;;   annotate PROC       candidate -> string shown dimmed after it (marginalia)
;;;   default STRING      preselected candidate (and result of RET on empty input)
;;;   preselect PROC      candidates -> index to start on (completion-preselect 'nearest)
;;;   preview PROC        called with the selected candidate whenever it changes (consult)
;;;   quit PROC           called, with no arguments, on C-g
;;;   history SYMBOL      history list, shared by name (M-p / M-n)
;;;   display PROC        candidate -> the string shown for it (the value stays the candidate)
;;;   raw #t              the collection's candidates are final: no filtering or sorting here
;;;                       (with a procedure that answers from results still coming in, call
;;;                       minibuffer-update! when more arrive: the candidates are recomputed,
;;;                       keeping the selected row)
;;;   files #t            file-name input: RET on a directory enters it, DEL and M-DEL delete
;;;                       a path component (vertico-directory); see (profane files)
;;;
;;; Matching splits the input at spaces and wants every part somewhere in the candidate, in any
;;; order, ignoring case unless the input has capitals (orderless-style).

(library (profane minibuffer)
  (export read-from-minibuffer completing-read read-string minibuffer-active?
          minibuffer-contents minibuffer-history completion-candidates completion-match?
          abort-minibuffer minibuffer-update!)
  (import (chezscheme) (profane buffer) (profane window) (profane mode) (profane keymap)
          (profane command) (profane command-loop) (profane var) (profane hook)
          (profane display))

  (define minibuffer-registered
    (begin
      (define-variable 'vertico-count 5 "Number of completion candidates shown.")
      (define-variable 'history-length 100 "Longest minibuffer history kept.")
      (define-variable 'completion-ignore-case 'smart
        "Ignore case when matching: #t, #f, or smart (only if the input is all lowercase).")))

  ;; ---- state of the one open minibuffer ----

  (define-record-type session
    (fields buffer k prompt-end collection require-match annotate default preselect preview
            quit history display raw files
            (mutable candidates)     ; the candidates shown, filtered
            (mutable selected)       ; index into candidates, or #f
            (mutable last-input)     ; input the candidates were computed for
            (mutable last-selected)
            (mutable history-pos))   ; M-p position, #f when not browsing
    (nongenerative profane-minibuffer-session))

  (define current #f)
  (define histories (make-eq-hashtable))

  (define (minibuffer-active?) (and current #t))
  (define (minibuffer-history name) (hashtable-ref histories name '()))

  (define (add-history! name s)
    (when (and name (> (string-length s) 0))
      (let ([old (remq-string s (minibuffer-history name))])
        (hashtable-set! histories name
                        (let ([l (cons s old)] [n (var-ref 'history-length)])
                          (if (> (length l) n) (list-head l n) l))))))

  (define (remq-string s l) (filter (lambda (x) (not (string=? x s))) l))

  (define (->string x) (cond [(string? x) x] [(symbol? x) (symbol->string x)] [else (format "~a" x)]))

  ;; ---- matching ----

  (define (split-words s)
    (let loop ([cs (string->list s)] [cur '()] [out '()])
      (define (flush) (if (null? cur) out (cons (list->string (reverse cur)) out)))
      (cond [(null? cs) (reverse (flush))]
            [(char=? (car cs) #\space) (loop (cdr cs) '() (flush))]
            [else (loop (cdr cs) (cons (car cs) cur) out)])))

  (define (contains? s sub)
    (let ([n (string-length s)] [k (string-length sub)])
      (let loop ([i 0])
        (and (<= (+ i k) n) (or (string=? (substring s i (+ i k)) sub) (loop (+ i 1)))))))

  (define (fold? input)
    (case (var-ref 'completion-ignore-case)
      [(#t) #t] [(#f) #f]
      [else (string=? input (string-downcase input))]))

  (define (completion-match? input candidate)
    (let* ([fold (fold? input)]
           [c (if fold (string-downcase candidate) candidate)])
      (for-all (lambda (w) (contains? c (if fold (string-downcase w) w))) (split-words input))))

  (define (string-prefix?* p s)
    (and (<= (string-length p) (string-length s)) (string=? p (substring s 0 (string-length p)))))

  ;; Matching candidates, best first: prefix matches, then shorter, then alphabetical.
  (define (completion-candidates collection input)
    (let* ([all (map ->string (if (procedure? collection) (collection input) collection))]
           [hits (filter (lambda (c) (completion-match? input c)) all)])
      (list-sort (lambda (a b)
                   (let ([pa (string-prefix?* input a)] [pb (string-prefix?* input b)])
                     (cond [(and pa (not pb)) #t]
                           [(and pb (not pa)) #f]
                           [(< (string-length a) (string-length b)) #t]
                           [(> (string-length a) (string-length b)) #f]
                           [else (string<? a b)])))
                 hits)))

  ;; ---- the minibuffer's buffer ----

  (define-major-mode minibuffer-mode fundamental-mode "Minibuf"
    "Major mode of the minibuffer.")

  (define (minibuffer-buffer)
    (let ([b (get-buffer-create " *Minibuf-1*")])
      (with-current-buffer b (buffer-disable-undo))
      b))

  ;; The end of the input: the end of the line the prompt is on.
  (define (input-end)
    (with-current-buffer (session-buffer current)
      (let ([p (point)])
        (goto-char (session-prompt-end current))
        (let ([e (line-end-position)]) (goto-char p) e))))

  (define (minibuffer-contents)
    (if current
        (with-current-buffer (session-buffer current)
          (buffer-substring (session-prompt-end current) (input-end)))
        ""))

  (define (completing? s) (and (session-collection s) #t))

  ;; Rewrites the candidate lines below the input line when the input or selection changed.
  (define (refresh! . keep-selection)
    (let* ([s current] [input (minibuffer-contents)] [old-selected (session-selected current)])
      (when (completing? s)
        (unless (equal? input (session-last-input s))
          (let ([cands (if (session-raw s)
                           (map ->string ((session-collection s) input))
                           (completion-candidates (session-collection s) input))])
            (session-candidates-set! s cands)
            (session-last-input-set! s input)
            (session-selected-set!
             s (cond [(null? cands) #f]
                     [(and (pair? keep-selection) old-selected) (min old-selected (- (length cands) 1))]
                     [(and (string=? input "") (session-default s)
                           (list-index (lambda (c) (string=? c (session-default s))) cands))]
                     [(session-preselect s) ((session-preselect s) cands)]
                     [else 0]))))
        (draw-candidates! s)
        (let ([sel (session-selected s)])
          (when (and (session-preview s) sel
                     (not (equal? sel (session-last-selected s))))
            (session-last-selected-set! s sel)
            (guard (c [else (void)])
              ((session-preview s) (list-ref (session-candidates s) sel))))))
      (%minibuffer-sync!)))

  ;; The collection's answer changed without the input changing (an async source got more
  ;; results): recompute the candidates, keeping the selected row, and redraw.
  (define (minibuffer-update!)
    (when (and current (completing? current))
      (let ([s current])
        (session-last-input-set! s #f)
        (with-current-buffer (session-buffer s) (refresh! #t)))))

  (define (list-index pred l)
    (let loop ([l l] [i 0]) (cond [(null? l) #f] [(pred (car l)) i] [else (loop (cdr l) (+ i 1))])))

  (define (draw-candidates! s)
    (let* ([cands (session-candidates s)] [sel (or (session-selected s) 0)]
           [count (var-ref 'vertico-count)]
           ;; the window of candidates scrolls to keep the selected one in view
           [start (max 0 (min sel (- (length cands) count)))]
           [shown (let ([tail (list-tail cands (min start (length cands)))])
                    (if (> (length tail) count) (list-head tail count) tail))])
      (with-current-buffer (session-buffer s)
        (let ([p (point)] [end (input-end)])
          (delete-region end (point-max))
          (let loop ([l shown] [i start])
            (unless (null? l)
              (insert "\n")
              (let ([from (point)])
                (insert (if (session-display s) ((session-display s) (car l)) (car l)))
                (when (eqv? i (session-selected s))
                  (put-text-property from (point) 'face 'highlight))
                (let ([note (and (session-annotate s) ((session-annotate s) (car l)))])
                  (when (and note (> (string-length note) 0))
                    (let ([a (point)])
                      (insert "  " note)
                      (put-text-property a (point) 'face 'shadow)))))
              (loop (cdr l) (+ i 1))))
          (when (null? cands)
            (when (> (string-length (minibuffer-contents)) 0)
              (insert "\n")
              (let ([a (point)])
                (insert "[No match]")
                (put-text-property a (point) 'face 'shadow))))
          (goto-char p)))))

  ;; ---- opening and closing ----

  (define (open! buffer-contents-initial k collection opts prompt)
    (when current (error 'minibuffer "Command attempted to use minibuffer while in minibuffer"))
    (let* ([b (minibuffer-buffer)]
           [opt (lambda (name default)
                  (let loop ([o opts])
                    (cond [(or (null? o) (null? (cdr o))) default]
                          [(eq? (car o) name) (cadr o)]
                          [else (loop (cddr o))])))]
           [initial (opt 'initial buffer-contents-initial)])
      (with-current-buffer b
        (erase-buffer)
        (set-major-mode! 'minibuffer-mode)
        (let ([from (point)])
          (insert prompt)
          (put-text-property from (point) 'face 'minibuffer-prompt))
        (let ([pe (point)])
          (insert initial)
          (set! current
            (make-session b k pe collection (opt 'require-match #f) (opt 'annotate #f)
                          (let ([d (opt 'default #f)]) (and d (->string d)))
                          (opt 'preselect #f) (opt 'preview #f) (opt 'quit #f) (opt 'history #f)
                          (opt 'display #f) (opt 'raw #f) (opt 'files #f)
                          '() #f #f #f #f))))
      (%minibuffer-activate! b)
      (refresh!)))

  (define (close!)
    (let ([s current])
      (set! current #f)
      (%minibuffer-deactivate!)
      s))

  (define (read-from-minibuffer prompt k . rest)
    (open! (if (pair? rest) (car rest) "") k #f (if (pair? rest) (cdr rest) '()) prompt))

  (define (read-string prompt k . rest) (apply read-from-minibuffer prompt k rest))

  (define (completing-read prompt collection k . opts)
    (open! "" k collection opts prompt))

  ;; ---- commands ----

  (define (guard-prompt! who)
    (when (<= (point) (session-prompt-end current))
      (error who "beginning of input")))

  (define (finish! text)
    (let ([s (close!)])
      (add-history! (session-history s) text)
      (let ([w (selected-window)])
        (when w (set-buffer (window-buffer w))))
      ((session-k s) text)))

  ;; RET takes the selected candidate (as vertico does); M-RET takes the input as typed.
  (define-command (exit-minibuffer)
    "Finish reading: with the selected candidate, else the typed input."
    (let* ([s current] [input (minibuffer-contents)] [sel (session-selected s)])
      (cond
        [(and (string=? input "") (session-default s)) (finish! (session-default s))]
        ;; file names: RET on a directory goes into it (vertico-directory-enter)
        [(and (session-files s) sel (directory-candidate? (list-ref (session-candidates s) sel)))
         (replace-input! (list-ref (session-candidates s) sel))]
        [(and (completing? s) sel) (finish! (list-ref (session-candidates s) sel))]
        [(and (completing? s) (session-require-match s))
         (error 'exit-minibuffer "match required")]
        [else (finish! input)])))

  (define-command (exit-minibuffer-with-input)
    "Finish with exactly what was typed, even when it matches no candidate."
    (finish! (minibuffer-contents)))

  (define (abort-minibuffer)
    (let ([s (close!)])
      (let ([w (selected-window)])
        (when w (set-buffer (window-buffer w))))
      (when (session-quit s) ((session-quit s)))
      (message "Quit")))

  (define-command (minibuffer-keyboard-quit) "Close the minibuffer without finishing."
    (abort-minibuffer))

  (define (select! delta)
    (let* ([s current] [n (length (session-candidates s))])
      (when (> n 0)
        (session-selected-set!
         s (cond [(session-selected s) (mod (+ (session-selected s) delta) n)]
                 [(> delta 0) 0]            ; from the prompt: the first
                 [else (- n 1)])))))

  (define-command (minibuffer-next-line) "Select the next candidate." (select! 1) (refresh!))
  (define-command (minibuffer-previous-line) "Select the previous candidate." (select! -1) (refresh!))

  ;; Like the owner's edge-of-vertico-buffer: the last candidate, or the first with C--.
  (define-command (minibuffer-edge-of-candidates)
    "Select the last candidate, or with a negative argument (C--) the first."
    (let* ([s current] [n (length (session-candidates s))])
      (when (> n 0)
        (session-selected-set! s (if (eq? (current-prefix-arg) '-) 0 (- n 1)))
        (refresh!))))

  (define (replace-input! text)
    (let ([s current])
      (with-current-buffer (session-buffer s)
        (delete-region (session-prompt-end s) (input-end))
        (goto-char (session-prompt-end s))
        (insert text))))

  (define (directory-candidate? c)
    (and (> (string-length c) 0) (char=? (string-ref c (- (string-length c) 1)) #\/)))

  (define-command (minibuffer-complete)
    "Insert the selected candidate as the input."
    (let ([s current])
      (cond
        [(session-selected s)
         (replace-input! (list-ref (session-candidates s) (session-selected s)))]
        [(pair? (session-candidates s))      ; the prompt is selected: take the first
         (replace-input! (car (session-candidates s)))])))

  ;; Deletes back to just after the previous "/" before position FROM (keeping that slash):
  ;; a path component, or the rest of a partly typed one.
  (define (delete-back-to-slash! from)
    (let* ([pe (session-prompt-end current)]
           [start (let back ([j (- from 1)])
                    (cond [(< j pe) pe]
                          [(eqv? (char-after j) #\/) (+ j 1)]
                          [else (back (- j 1))]))])
      (delete-region start (point))))

  ;; DEL; in a file name, right after a "/" it deletes the whole component (vertico-directory).
  (define-command (minibuffer-delete-backward-char)
    (guard-prompt! 'delete-backward-char)
    (if (and (session-files current) (eqv? (char-before) #\/) (= (point) (input-end))
             (not (current-prefix-arg)))
        (delete-back-to-slash! (- (point) 1))
        (delete-char (- (prefix-numeric-value)))))

  ;; M-DEL: a path component in a file name, else a word.
  (define-command (minibuffer-delete-word-backward)
    (guard-prompt! 'delete-word-backward)
    (cond
      [(session-files current)
       (delete-back-to-slash! (if (eqv? (char-before) #\/) (- (point) 1) (point)))]
      [else
       (let* ([pe (session-prompt-end current)]
              [word? (lambda (c) (and c (or (char-alphabetic? c) (char-numeric? c))))]
              [skip (let loop ([i (point)]) (if (and (> i pe) (not (word? (char-before i)))) (loop (- i 1)) i))]
              [start (let loop ([i skip]) (if (and (> i pe) (word? (char-before i))) (loop (- i 1)) i))])
         (delete-region start (point)))]))

  (define-command (minibuffer-beginning-of-line)
    (goto-char (session-prompt-end current)))

  (define-command (minibuffer-backward-char)
    (guard-prompt! 'backward-char)
    (backward-char (prefix-numeric-value)))

  (define-command (minibuffer-kill-whole-line) "Delete all the input."
    (delete-region (session-prompt-end current) (input-end)))

  (define (browse-history! delta)
    (let* ([s current] [h (minibuffer-history (session-history s))]
           [pos (+ (or (session-history-pos s) -1) delta)])
      (cond
        [(null? h) (error 'minibuffer "history is empty")]
        [(or (< pos 0) (>= pos (length h))) (error 'minibuffer "end of history")]
        [else
         (session-history-pos-set! s pos)
         (delete-region (session-prompt-end s) (input-end))
         (goto-char (session-prompt-end s))
         (insert (list-ref h pos))])))

  (define-command (previous-history-element) (browse-history! 1))
  (define-command (next-history-element) (browse-history! -1))

  (define minibuffer-map
    (let ([m (mode-keymap 'minibuffer-mode)])
      (for-each (lambda (b) (define-key! m (car b) (cdr b)))
                '(("RET" . exit-minibuffer) ("M-RET" . exit-minibuffer-with-input)
                  ("C-g" . minibuffer-keyboard-quit)
                  ("C-n" . minibuffer-next-line) ("<down>" . minibuffer-next-line)
                  ("C-p" . minibuffer-previous-line) ("<up>" . minibuffer-previous-line)
                  ("TAB" . minibuffer-complete) ("C-M-v" . minibuffer-edge-of-candidates)
                  ("DEL" . minibuffer-delete-backward-char) ("M-DEL" . minibuffer-delete-word-backward)
                  ("C-b" . minibuffer-backward-char) ("<left>" . minibuffer-backward-char)
                  ("C-a" . minibuffer-beginning-of-line) ("<home>" . minibuffer-beginning-of-line)
                  ("M-p" . previous-history-element) ("M-n" . next-history-element)))
      m))

  ;; Keys go to the minibuffer while it is open; its candidates follow each command.
  (define installed
    (begin
      (set-input-buffer-function! (lambda () (and current (session-buffer current))))
      (add-hook! 'post-command-hook
                 (lambda ()
                   (when (and current (eq? (current-buffer) (session-buffer current)))
                     (refresh!))))
      #t)))
