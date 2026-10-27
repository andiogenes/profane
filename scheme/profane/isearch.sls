;;; (profane isearch) — incremental search, as Emacs's isearch. Unstable API (plan §10).
;;;
;;; C-s / C-r start searching forward / backward in the selected window's buffer. Typed text
;;; extends the search string and point follows the match as it is typed: after it searching
;;; forward, at its start searching backward. While searching, isearch-mode-map has the keys:
;;;
;;;   C-s / C-r   next / previous match (the first C-s or C-r on an empty string searches for
;;;               the last string again; after a failing search, wrap around the buffer)
;;;   DEL         undo the last step (a character, a repeat, a yank)
;;;   RET         stop at the match; the mark is left where the search started
;;;   C-g         when failing, take back the part that fails; otherwise go back where the
;;;               search started and stop
;;;   C-w C-y     add the rest of the word at point / the last kill to the string
;;;
;;; Any other key stops searching (as RET) and then does what it always does. The string is
;;; literal (no regexps yet: plan §8j). Case is ignored while the string has no capitals
;;; (case-fold-search). The current match is shown in the isearch face, the other matches near
;;; it in lazy-highlight: both through the highlight text property, drawn over the buffer's own
;;; faces. The search reads the keyboard through the command loop's input override, so typed
;;; text keeps the keyboard layout and input method, and a mode's single-key bindings (dired's
;;; n, m, d) do not take it.

(library (profane isearch)
  (export isearch-active? isearch-string isearch-mode-map search-ring)
  (import (chezscheme) (profane buffer) (profane window) (profane keymap) (profane command)
          (profane command-loop) (profane var) (profane display) (profane simple))

  (defvar case-fold-search #t
    "Searches ignore case, unless the search string has capital letters.")
  (defvar search-ring-max 16 "Most search strings remembered for C-s C-s.")
  (defvar lazy-highlight-max 1000 "Most other matches highlighted around the current one.")

  ;; ---- the one search in progress ----

  (define active #f)        ; the buffer being searched, or #f
  (define search-window #f) ; the window it started in
  (define origin 0)         ; point when it started
  (define region-was-active #f)
  (define forward? #t)
  (define str "")           ; the search string
  (define success #t)       ; whether str matches
  (define wrapped #f)
  (define other-end 0)      ; the match's other end from point (its start when forward)
  (define last-point 0)     ; point where the search left it
  (define states '())       ; earlier states, newest first, for DEL
  (define typed "")         ; the text the current isearch-printing-char adds

  (define ring '())
  (define (search-ring) ring)

  (define (isearch-active?) (and active #t))
  (define (isearch-string) str)

  (define (save-state!)
    (set! states (cons (vector str success wrapped forward? other-end last-point) states)))

  (define (restore-state! v)
    (set! str (vector-ref v 0))
    (set! success (vector-ref v 1))
    (set! wrapped (vector-ref v 2))
    (set! forward? (vector-ref v 3))
    (set! other-end (vector-ref v 4))
    (set! last-point (vector-ref v 5)))

  ;; ---- matching: over a copy of the text, kept while the buffer does not change ----

  (define text-cache #f)    ; #(buffer edit-count text folded-text-or-#f)

  (define (buffer-text fold?)
    (unless (and text-cache (eq? (vector-ref text-cache 0) (current-buffer))
                 (= (vector-ref text-cache 1) (buffer-edit-count)))
      (set! text-cache (vector (current-buffer) (buffer-edit-count)
                               (buffer-substring (point-min) (point-max)) #f)))
    (if fold?
        (or (vector-ref text-cache 3)
            ;; char by char: string-downcase may change the length ("İ"), and positions must hold
            (let* ([t (vector-ref text-cache 2)] [n (string-length t)] [f (make-string n)])
              (do ([i 0 (+ i 1)]) ((= i n)) (string-set! f i (char-downcase (string-ref t i))))
              (vector-set! text-cache 3 f)
              f))
        (vector-ref text-cache 2)))

  (define (fold? s)
    (and (var-ref 'case-fold-search)
         (not (exists char-upper-case? (string->list s)))))

  (define (needle s) (if (fold? s) (list->string (map char-downcase (string->list s))) s))

  (define (match-at? hay s i)
    (let ([k (string-length s)])
      (let loop ([j 0])
        (or (= j k) (and (char=? (string-ref hay (+ i j)) (string-ref s j)) (loop (+ j 1)))))))

  ;; Start of the first match of S at or after FROM (forward), or of the last one ending at or
  ;; before FROM (backward); #f if there is none.
  (define (find-match s from fwd)
    (let* ([hay (buffer-text (fold? s))] [s (needle s)]
           [n (string-length hay)] [k (string-length s)])
      (if fwd
          (let loop ([i (max 0 from)])
            (cond [(> (+ i k) n) #f] [(match-at? hay s i) i] [else (loop (+ i 1))]))
          (let loop ([i (min (- from k) (- n k))])
            (cond [(< i 0) #f] [(match-at? hay s i) i] [else (loop (- i 1))])))))

  ;; Searches for str from FROM; on a match moves point to its far end in the direction of
  ;; the search. Returns whether it matched.
  (define (search-from! from)
    (let ([m (find-match str from forward?)] [k (string-length str)])
      (set! success (and m #t))
      (when m
        (set! other-end (if forward? m (+ m k)))
        (set! last-point (if forward? (+ m k) m)))
      success))

  ;; ---- what is shown ----

  (define (prompt)
    (string-append (if success "" "Failing ") (if wrapped "Wrapped " "")
                   "I-search" (if forward? "" " backward") ": " str))

  ;; The start of the line N lines before POS in HAY, or the end of the line N lines after.
  (define (lines-from hay pos n step)
    (let ([len (string-length hay)])
      (let loop ([i pos] [left n])
        (cond [(and (< step 0) (<= i 0)) 0]
              [(and (> step 0) (>= i len)) len]
              [(char=? (string-ref hay (if (< step 0) (- i 1) i)) #\newline)
               (if (= left 0) i (loop (+ i step) (- left 1)))]
              [else (loop (+ i step) left)]))))

  ;; Highlights the current match and, around it, the other matches of the string as far as a
  ;; window's height either way (the window may still scroll to the match). While failing, the
  ;; last match that succeeded stays shown.
  (define (highlight!)
    (put-text-property (point-min) (point-max) 'highlight #f)
    (let ([k (string-length str)] [lo (min other-end last-point)] [hi (max other-end last-point)])
      (when (and (> k 0) success)
        (let* ([hay (buffer-text (fold? str))] [s (needle str)]
               [n (if (window-live? search-window) (max 1 (window-body-lines search-window)) 50)]
               [from (lines-from hay lo n -1)] [to (lines-from hay hi n 1)])
          (let loop ([i from] [count 0])
            (when (and (<= (+ i k) to) (< count (var-ref 'lazy-highlight-max)))
              (if (match-at? hay s i)
                  (begin (put-text-property i (+ i k) 'highlight 'lazy-highlight)
                         (loop (+ i k) (+ count 1)))
                  (loop (+ i 1) count))))))
      (when (< lo hi) (put-text-property lo hi 'highlight 'isearch))))

  (define (update!)
    (goto-char last-point)
    (highlight!)
    (%echo (prompt)))

  ;; ---- starting and stopping ----

  (define (live?)
    (and active (buffer-live? active) (window-live? search-window)
         (eq? (selected-window) search-window) (eq? (window-buffer search-window) active)
         (= last-point (with-current-buffer active (point)))))

  ;; Keys while searching: the map's commands, typed text, and #f (stop) for the rest.
  (define (read-input kind x)
    (cond
      [(not (live?)) (stop! #f) #f]
      [(eq? kind 'text) (set! typed x) 'isearch-printing-char]
      [(lookup-key isearch-mode-map (list x)) => (lambda (b) (and (symbol? b) b))]
      [(or (= (string-length x) 1) (string=? x "SPC"))
       (set! typed (if (string=? x "SPC") " " x))
       'isearch-printing-char]
      [else (stop! #t) #f]))

  (define (start! fwd)
    (when active (stop! #f))
    (set! active (current-buffer))
    (set! search-window (selected-window))
    (set! origin (point))
    (set! region-was-active (var-ref 'mark-active))
    (set! forward? fwd)
    (set! str "")
    (set! success #t)
    (set! wrapped #f)
    (set! other-end (point))
    (set! last-point (point))
    (set! states '())
    (set-input-override! read-input)
    (update!))

  ;; Ends the search where it is. With MARK?, as RET does: remember the string and leave the
  ;; mark where the search started.
  (define (stop! mark?)
    (let ([b active])
      (set-input-override! #f)
      (set! active #f)
      (set! states '())
      (set! text-cache #f)
      (when (buffer-live? b)
        (with-current-buffer b
          (put-text-property (point-min) (point-max) 'highlight #f)
          (when mark?
            (add-to-ring! str)
            (when (and (not region-was-active) (not (= (point) origin)))
              (set-mark! origin)
              (message "Mark saved where search started")))))))

  (define (add-to-ring! s)
    (when (> (string-length s) 0)
      (let ([l (cons s (filter (lambda (x) (not (string=? x s))) ring))])
        (set! ring (if (> (length l) (var-ref 'search-ring-max))
                       (list-head l (var-ref 'search-ring-max))
                       l)))))

  (define (searching who)
    (unless active (error who "not searching")))

  ;; ---- commands ----

  (define (start-here! fwd)
    (unless (and (selected-window) (eq? (current-buffer) (window-buffer (selected-window))))
      (error 'isearch "not in the minibuffer"))
    (start! fwd))

  (define-command (isearch-forward)
    "Search forward incrementally as the string is typed (C-s again: the next match)."
    (start-here! #t))

  (define-command (isearch-backward)
    "Search backward incrementally as the string is typed (C-r again: the previous match)."
    (start-here! #f))

  ;; Adds TEXT to the string and searches again so that the match grows where it is when it
  ;; still can: from its start forward, or backward from its start plus the new length.
  (define (extend! text)
    (save-state!)
    (set! str (string-append str text))
    (when success
      (search-from! (if forward? other-end (min (point-max) (+ last-point (string-length str))))))
    (update!))

  (define-command (isearch-printing-char) "Add the typed text to the search string."
    (searching 'isearch-printing-char)
    (extend! typed))

  (define (repeat! fwd)
    (when (and (string=? str "") (null? ring)) (error 'isearch "no previous search string"))
    (save-state!)
    (cond
      [(string=? str "")
       (set! str (car ring))
       (set! forward? fwd)
       (search-from! last-point)]
      ;; turning around finds the same match again, from the end point is at
      [(not (eq? fwd forward?))
       (set! forward? fwd)
       (search-from! last-point)]
      [(not success)
       (set! wrapped #t)
       (search-from! (if fwd (point-min) (point-max)))]
      [else (search-from! last-point)])
    (update!))

  (define-command (isearch-repeat-forward) "Go to the next match."
    (searching 'isearch-repeat-forward)
    (repeat! #t))

  (define-command (isearch-repeat-backward) "Go to the previous match."
    (searching 'isearch-repeat-backward)
    (repeat! #f))

  (define-command (isearch-delete-char) "Undo the last search step."
    (searching 'isearch-delete-char)
    (if (null? states)
        (error 'isearch "nothing to undo")
        (begin (restore-state! (car states))
               (set! states (cdr states))
               (update!))))

  (define-command (isearch-exit) "Stop searching at the match; the mark stays where it started."
    (searching 'isearch-exit)
    (stop! #t))

  (define-command (isearch-abort)
    "Take back the failing part of the string, or go back where the search started."
    (searching 'isearch-abort)
    (if success
        (begin (goto-char origin) (stop! #f) (message "Quit"))
        (begin
          (let loop ()
            (when (and (pair? states) (not success))
              (restore-state! (car states))
              (set! states (cdr states))
              (loop)))
          (if success
              (update!)
              (begin (goto-char origin) (stop! #f) (message "Quit"))))))

  ;; From point to the end of the next word (the word at point, if inside one).
  (define-command (isearch-yank-word) "Add the rest of the word at point to the search string."
    (searching 'isearch-yank-word)
    (let* ([word? (lambda (c) (and c (or (char-alphabetic? c) (char-numeric? c))))]
           [p (point)]
           [skip (let loop ([i p]) (if (and (< i (point-max)) (not (word? (char-after i)))) (loop (+ i 1)) i))]
           [end (let loop ([i skip]) (if (and (< i (point-max)) (word? (char-after i))) (loop (+ i 1)) i))])
      (when (= end p) (error 'isearch-yank-word "end of buffer"))
      (extend! (buffer-substring p end))))

  (define-command (isearch-yank-kill) "Add the last kill to the search string."
    (searching 'isearch-yank-kill)
    (extend! (current-kill)))

  (define isearch-mode-map
    (let ([m (make-keymap #f 'isearch-mode-map)])
      (for-each (lambda (b) (define-key! m (car b) (cdr b)))
                '(("C-s" . isearch-repeat-forward) ("C-r" . isearch-repeat-backward)
                  ("DEL" . isearch-delete-char) ("RET" . isearch-exit) ("C-g" . isearch-abort)
                  ("C-w" . isearch-yank-word) ("C-y" . isearch-yank-kill)))
      m))

  (define bindings
    (begin
      (define-key! (global-map) "C-s" 'isearch-forward)
      (define-key! (global-map) "C-r" 'isearch-backward)
      #t)))
