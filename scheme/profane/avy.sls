;;; (profane avy) — jumping to a visible position by typing a short label, after the avy package.
;;; Unstable API (plan §10).
;;;
;;;   avy-goto-word-1   read a character, label every visible word starting with it
;;;   avy-goto-char     read a character, label every visible occurrence of it
;;;   avy-goto-line     label every visible line
;;;
;;; The labels are a canvas pop-up on the overlay layer (see (profane canvas)), drawn over the
;;; text in every window of the frame; type a label to jump there (selecting that window, and
;;; leaving the mark where you were). C-g, ESC or a key that is no label cancels. Candidates are
;;; ordered by distance from point (the selected window first), so the nearest get the shortest
;;; labels. Labels are made of the keys in `avy-keys`; with more candidates than keys they take
;;; several. Keys arrive as keys named from the ASCII-capable layout, so the labels work while a
;;; non-Latin layout is active.

(library (profane avy)
  (export avy-labels)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane canvas) (profane var) (profane native))

  (defvar avy-keys '("a" "s" "d" "f" "g" "h" "j" "k" "l")
    "Keys the jump labels are made of, home row first.")

  ;; ---- labels ----

  ;; N labels of equal length over KEYS (strings), in order: "a" ... or "aa" "as" ... when there
  ;; are more candidates than keys.
  (define (avy-labels n keys)
    (let* ([k (length keys)]
           [len (let loop ([len 1] [cap k]) (if (>= cap n) len (loop (+ len 1) (* cap k))))])
      (let make ([i 0] [acc '()])
        (if (= i n)
            (reverse acc)
            (make (+ i 1)
                  (cons (let digits ([v i] [d len] [out '()])
                          (if (zero? d)
                              (apply string-append out)
                              (digits (quotient v k) (- d 1) (cons (list-ref keys (remainder v k)) out))))
                        acc))))))

  ;; ---- candidates ----
  ;; A candidate is (window position x y): its place in frame coordinates.

  (define (word-char? c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

  (define (candidate w pos)
    (let ([r (window-pos-rect w pos)] [e (window-edges w)])
      (and r (list w pos (+ (car e) (car r)) (+ (cadr e) (cadr r)) (caddr r)))))

  ;; Positions in W's visible text satisfying (ok? text i prev-char) where i indexes TEXT.
  (define (scan-window w ok?)
    (let-values ([(start end) (window-visible-range w)])
      (let* ([b (window-buffer w)]
             [text (with-current-buffer b (buffer-substring start end))]
             [before (and (> start 0) (with-current-buffer b (char-before start)))])
        (let loop ([i 0] [acc '()])
          (if (= i (string-length text))
              (reverse acc)
              (loop (+ i 1)
                    (if (ok? text i (if (> i 0) (string-ref text (- i 1)) before))
                        (cons (+ start i) acc)
                        acc)))))))

  (define (distance c from-window point)
    (if (eq? (car c) from-window)
        (abs (- (cadr c) point))
        (+ 1000000000 (cadr c))))

  (define (order-candidates cs)
    (let ([w (selected-window)] [p (point)])
      (list-sort (lambda (a b) (< (distance a w p) (distance b w p))) cs)))

  (define (gather ok?)
    (order-candidates
     (apply append
            (map (lambda (w)
                   (filter values (map (lambda (pos) (candidate w pos)) (scan-window w ok?))))
                 (window-list)))))

  ;; ---- the jump ----

  (define (jump! c)
    (let ([w (car c)] [pos (cadr c)])
      (unless (and (eq? w (selected-window)) (= pos (point)))
        (set-mark! (point)))
      (unless (eq? w (selected-window)) (select-window w))
      (goto-char pos)))

  ;; Shows LABELS (parallel to CANDIDATES) whose text starts with TYPED, with the typed part
  ;; dropped, and reads keys until one label is complete.
  (define (choose candidates labels)
    (let ([canvas (make-canvas 10 10)] [f (selected-frame)])
      (define (finish) (delete-canvas! canvas))
      (define (draw typed)
        (clear-canvas! canvas)
        (let ([n (string-length typed)])
          (for-each
           (lambda (c label)
             (when (and (>= (string-length label) n) (string=? (substring label 0 n) typed))
               (let ([shown (substring label n (string-length label))])
                 (let-values ([(tw th) (text-extent shown)])
                   (let ([pad 3])
                     (fill-rounded-rect! canvas (caddr c) (cadddr c) (+ tw (* 2 pad)) th 3 'red)
                     (draw-text! canvas (+ (caddr c) pad) (cadddr c) shown 'default 'bg))))))
           candidates labels)))
      (define (ask typed)
        (set-canvas-size! canvas (frame-width f) (frame-height f))
        (draw typed)
        (show-popup! canvas 0 0)
        (set-key-reader!
         (lambda (key)
           (let ([typed (string-append typed key)])
             (let ([hits (filter (lambda (p) (and (>= (string-length (cdr p)) (string-length typed))
                                                  (string=? (substring (cdr p) 0 (string-length typed)) typed)))
                                 (map cons candidates labels))])
               (cond
                 [(null? hits) (finish) (message "No such label")]
                 [(string=? (cdr (car hits)) typed) (finish) (jump! (car (car hits)))]
                 [else (ask typed)]))))))
      (ask "")))

  (define (start ok?)
    (let ([cs (gather ok?)])
      (cond
        [(null? cs) (message "No visible match")]
        [(null? (cdr cs)) (jump! (car cs))]
        [else (choose cs (avy-labels (length cs) (var-ref 'avy-keys)))])))

  ;; Reads one character, then runs (ACT char).
  (define (read-char-then prompt act)
    (message "~a" prompt)
    (set-key-reader!
     (lambda (key)
       (cond
         [(equal? key "SPC") (act #\space)]
         [(= (string-length key) 1) (act (string-ref key 0))]
         [else (message "Quit")]))))

  (define-command (avy-goto-word-1)
    "Jump to the start of a visible word beginning with a typed character."
    (read-char-then "Word start char: "
                    (lambda (ch)
                      (start (lambda (text i prev)
                               (and (char-ci=? (string-ref text i) ch)
                                    (word-char? (string-ref text i))
                                    (not (and prev (word-char? prev)))))))))

  (define-command (avy-goto-char)
    "Jump to a visible occurrence of a typed character."
    (read-char-then "Char: "
                    (lambda (ch) (start (lambda (text i prev) (char=? (string-ref text i) ch))))))

  (define-command (avy-goto-line)
    "Jump to the beginning of a visible line."
    (start (lambda (text i prev) (or (not prev) (char=? prev #\newline))))))
