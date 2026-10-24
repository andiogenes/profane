;;; (profane section) — trees of sections in a read-only buffer, after Magit's magit-section.
;;; Unstable API (plan §10).
;;;
;;; A section is a heading line, optional body lines, and child sections; folding hides the body
;;; and the children. Porcelain builds a tree and renders it:
;;;
;;;   (render-sections!
;;;     (list (new-section 'files 'unstaged "Unstaged changes (2)" '() children #f #f)))
;;;
;;; (new-section KIND ID HEADING BODY CHILDREN FOLDED? VALUE): KIND says what a section is (commands
;;; dispatch on it), ID identifies it across refreshes (compared with equal?), HEADING and each BODY
;;; line are a string or a list of strings and (string . face) pairs, VALUE is the porcelain's own
;;; datum. The buffer is rebuilt from the tree on every change, so a refresh is just a new tree:
;;; (section-refresh! roots) keeps the folds of sections whose ids survive and puts point back on the
;;; same section and line (or on the nearest surviving ancestor). Buffer positions in a section are
;;; valid until the next render.
;;;
;;; section-mode, the parent of porcelain modes: TAB folds the section at point, S-TAB all, n p move
;;; to the next or previous section, M-n M-p to the next or previous sibling, ^ to the parent, g
;;; calls section-refresh-function, q buries the buffer.

(library (profane section)
  (export section? new-section section-kind section-id section-heading section-body
          section-value section-parent section-children section-folded?
          section-start section-heading-end section-body-start section-end
          section-foldable? section-walk section-find
          render-sections! section-refresh! section-at section-at-point sections
          section-toggle! section-fold-all!)
  (import (chezscheme) (profane buffer) (profane command) (profane keymap) (profane mode)
          (profane var) (profane face) (profane display) (profane window) (profane simple))

  (defvar section-roots '() "The top-level sections of the buffer, as last rendered." '(local))
  (defvar section-fold-state #f "Folded state of every rendered section id (an equal? hashtable)." '(local))
  (defvar section-refresh-function #f
    "A procedure of no arguments that rebuilds the buffer's sections (g in section-mode)." '(local))

  (define section-faces
    (begin
      (define-face 'section-heading '((weight . bold)) "Section headings.")
      #t))

  (define-major-mode section-mode fundamental-mode "Section" "Major mode of buffers made of sections.")

  (define-record-type section
    (fields kind id heading body children (mutable folded) value (mutable parent)
            (mutable start) (mutable heading-end) (mutable body-start) (mutable end))
    (protocol
     (lambda (new)
       (lambda (kind id heading body children folded value)
         (let ([s (new kind id heading body children folded value #f 0 0 0 0)])
           (for-each (lambda (c) (section-parent-set! c s)) children)
           s)))))

  (define (new-section kind id heading body children folded? value)
    (make-section kind id heading body children (and folded? #t) value))

  ;; The top-level sections of the current buffer, as last rendered.
  (define (sections) (var-ref 'section-roots))

  (define (section-folded? s) (section-folded s))

  (define (section-foldable? s)
    (or (pair? (section-body s)) (pair? (section-children s))))

  (define (section-walk roots proc)
    (for-each (lambda (s) (proc s) (section-walk (section-children s) proc)) roots))

  (define (section-find roots id)
    (let ([found #f])
      (section-walk roots (lambda (s) (when (and (not found) (equal? (section-id s) id)) (set! found s))))
      found))

  ;; ---- rendering ----

  (define (insert-segments! text)
    (cond
     [(string? text) (insert text)]
     [else
      (for-each (lambda (seg)
                  (if (string? seg)
                      (insert seg)
                      (let ([from (point)])
                        (insert (car seg))
                        (put-text-property from (point) 'face (cdr seg)))))
                text)]))

  (define (insert-section! s)
    (section-start-set! s (point))
    (let ([from (point)])
      (insert-segments! (section-heading s))
      (put-text-property from (point) 'face 'section-heading)
      ;; Faces given in the heading win over the default.
      (when (pair? (section-heading s))
        (let ([p from])
          (for-each (lambda (seg)
                      (let ([n (string-length (if (string? seg) seg (car seg)))])
                        (when (pair? seg) (put-text-property p (+ p n) 'face (cdr seg)))
                        (set! p (+ p n))))
                    (section-heading s)))))
    (section-heading-end-set! s (point))
    (insert "\n")
    (section-body-start-set! s (point))
    (unless (section-folded? s)
      (for-each (lambda (l) (insert-segments! l) (insert "\n")) (section-body s))
      (for-each insert-section! (section-children s)))
    (section-end-set! s (point)))


  (define (fold-state)
    (or (var-ref 'section-fold-state)
        (let ([h (make-hashtable equal-hash equal?)])
          (var-set! 'section-fold-state h)
          h)))

  ;; Rebuilds the buffer from ROOTS, applying the folds remembered for their ids, and remembers
  ;; the folds now in force (ids that are gone are forgotten).
  (define (render-sections! roots)
    (let ([state (fold-state)])
      (section-walk roots (lambda (s)
                            (let ([v (hashtable-ref state (section-id s) 'none)])
                              (unless (eq? v 'none) (section-folded-set! s v)))))
      (with-inhibit-read-only
       (lambda ()
         (erase-buffer)
         (for-each insert-section! roots)
         (goto-char (point-min))))
      (var-set! 'section-roots roots)
      (hashtable-clear! state)
      (section-walk roots (lambda (s) (hashtable-set! state (section-id s) (section-folded? s))))
      (set-buffer-unmodified!)))

  ;; ---- finding sections ----

  (define (contains? s pos) (and (>= pos (section-start s)) (< pos (section-end s))))

  (define (section-at pos)
    (let descend ([level (var-ref 'section-roots)] [found #f])
      (let ([hit (find (lambda (s) (contains? s pos)) level)])
        (cond [(not hit) (or found (and (pair? level) (= pos (point-max)) (car (reverse level))))]
              [(section-folded? hit) hit]
              [else (descend (section-children hit) hit)]))))

  (define (section-at-point) (section-at (point)))

  (define (ancestor-ids s)
    (let loop ([s s] [out '()])
      (if s (loop (section-parent s) (cons (section-id s) out)) (reverse out))))

  ;; ---- keeping point across a render ----

  ;; (ids line column): the ids of the section at point and its ancestors, innermost first, and
  ;; where point was in the innermost.
  (define (anchor)
    (let ([s (section-at-point)])
      (and s (list (ancestor-ids s)
                   (- (line-number-at-pos (point)) (line-number-at-pos (section-start s)))
                   (- (point) (line-beginning-position))))))

  (define (restore! a)
    (cond
     [(not a) (goto-char (point-min))]
     [else
      (let loop ([ids (car a)] [innermost #t])
        (cond
         [(null? ids) (goto-char (point-min))]
         [(section-find (var-ref 'section-roots) (car ids))
          => (lambda (s)
               (goto-char (section-start s))
               (when innermost
                 (let ([last (- (line-number-at-pos (max (section-start s) (- (section-end s) 1)))
                                (line-number-at-pos (section-start s)))])
                   (forward-line (min (cadr a) last)))
                 (goto-char (min (+ (line-beginning-position) (caddr a)) (line-end-position)))))]
         [else (loop (cdr ids) #f)]))]))

  (define (section-refresh! roots)
    (let ([a (anchor)])
      (render-sections! roots)
      (restore! a)))

  ;; ---- folding ----

  (define (section-toggle! s)
    (when (section-foldable? s)
      (hashtable-set! (fold-state) (section-id s) (not (section-folded? s)))
      (section-folded-set! s (not (section-folded? s)))
      (let ([a (anchor-of s)])
        (render-sections! (var-ref 'section-roots))
        (restore! a))))

  ;; Point stays where it was, unless it is in what folding hides.
  (define (anchor-of s)
    (let ([a (anchor)])
      (if (and a (section-folded? s) (>= (point) (section-body-start s)))
          (list (ancestor-ids s) 0 0)
          a)))

  (define (section-fold-all! fold?)
    (let ([state (fold-state)] [a (anchor)])
      (section-walk (var-ref 'section-roots)
                    (lambda (s)
                      (when (and (section-foldable? s) (section-parent s))
                        (section-folded-set! s fold?)
                        (hashtable-set! state (section-id s) fold?))))
      (render-sections! (var-ref 'section-roots))
      (restore! a)))

  (define-command (section-toggle)
    "Fold or unfold the section at point."
    (let ([s (section-at-point)])
      (when s (section-toggle! s))))

  (define-command (section-cycle)
    "Fold every nested section, or unfold them all if they are folded."
    (let ([any-open #f])
      (section-walk (var-ref 'section-roots)
                    (lambda (s) (when (and (section-parent s) (section-foldable? s) (not (section-folded? s)))
                                  (set! any-open #t))))
      (section-fold-all! any-open)))

  ;; ---- movement ----

  (define (visible-sections)
    (let ([out '()])
      (let walk ([level (var-ref 'section-roots)])
        (for-each (lambda (s)
                    (set! out (cons s out))
                    (unless (section-folded? s) (walk (section-children s))))
                  level))
      (reverse out)))

  (define-command (section-forward)
    "Move to the next section."
    (let ([next (find (lambda (s) (> (section-start s) (point))) (visible-sections))])
      (if next (goto-char (section-start next)) (error 'section-forward "no next section"))))

  (define-command (section-backward)
    "Move to the start of this section, or of the previous one."
    (let ([prev (find (lambda (s) (< (section-start s) (point))) (reverse (visible-sections)))])
      (if prev (goto-char (section-start prev)) (error 'section-backward "no previous section"))))

  (define (siblings s)
    (if (section-parent s) (section-children (section-parent s)) (var-ref 'section-roots)))

  (define-command (section-forward-sibling)
    "Move to the next section at this level."
    (let* ([s (section-at-point)]
           [rest (and s (memq s (siblings s)))])
      (if (and rest (pair? (cdr rest)))
          (goto-char (section-start (cadr rest)))
          (error 'section-forward-sibling "no next sibling"))))

  (define-command (section-backward-sibling)
    "Move to the previous section at this level."
    (let* ([s (section-at-point)]
           [before (and s (let loop ([l (siblings s)] [prev #f])
                            (cond [(null? l) #f] [(eq? (car l) s) prev] [else (loop (cdr l) (car l))])))])
      (if before
          (goto-char (section-start before))
          (error 'section-backward-sibling "no previous sibling"))))

  (define-command (section-up)
    "Move to the parent section."
    (let ([s (section-at-point)])
      (if (and s (section-parent s))
          (goto-char (section-start (section-parent s)))
          (error 'section-up "no parent section"))))

  (define-command (section-refresh)
    "Rebuild the sections of this buffer."
    (let ([f (var-ref 'section-refresh-function)])
      (if f (f) (message "Nothing to refresh"))))

  (define-command (section-quit)
    "Bury this buffer."
    (switch-to-buffer (other-buffer (current-buffer))))

  (define bindings
    (begin
      (for-each (lambda (b) (define-key! (mode-keymap 'section-mode) (car b) (cdr b)))
                '(("TAB" . section-toggle) ("<backtab>" . section-cycle)
                  ("n" . section-forward) ("p" . section-backward)
                  ("M-n" . section-forward-sibling) ("M-p" . section-backward-sibling)
                  ("^" . section-up) ("g" . section-refresh) ("q" . section-quit)))
      #t)))
