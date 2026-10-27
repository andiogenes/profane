;;; (profane mouse) — what the mouse does. Unstable API (plan §10).
;;;
;;; The shell sends every mouse event as (handle-mouse KIND X Y CLICKS) with the point in frame
;;; coordinates (points, top-left origin), and wheel events as (handle-scroll X Y DX DY PRECISE).
;;;
;;;   click in a text window     selects it and moves point there (the region is deactivated)
;;;   drag                       selects text from where the button went down (the active region);
;;;                              above or below the window it scrolls
;;;   double / triple click      selects the word / the line
;;;   click on a canvas region   runs the region's handler (see (profane canvas))
;;;   click on a tab             selects it; on its × closes it (see (profane tab-bar))
;;;   drag a mode line / the     resizes the window above / to the left of it
;;;     divider between windows
;;;   scroll wheel or trackpad   scrolls the window under the pointer (point follows when it would
;;;                              leave the screen); sideways scrolls horizontally
;;;
;;; Not yet: dragging text, middle-click paste, dragging tabs, right-click menus.

(library (profane mouse)
  (export handle-mouse handle-scroll window-at)
  (import (chezscheme) (profane native) (profane buffer) (profane var) (profane window)
          (profane canvas) (profane command) (profane tab-bar))

  ;; ---- finding things ----

  (define (contains? e x y)
    (and (>= x (car e)) (< x (+ (car e) (caddr e))) (>= y (cadr e)) (< y (+ (cadr e) (cadddr e)))))

  ;; The text-area window (never the minibuffer) containing frame point (X, Y), or #f.
  (define (window-at x y)
    (let loop ([ws (window-list)])
      (cond [(null? ws) #f]
            [(contains? (window-edges (car ws)) x y) (car ws)]
            [else (loop (cdr ws))])))

  (define (mode-line-h w) (%win-mode-line-height (window-handle* w)))
  (define (header-h w) (%win-header-line-height (window-handle* w)))
  (define (window-handle* w) (%window-handle w))
  (define (frame-h) (%frame-handle (selected-frame)))

  ;; A window whose top edge meets W's bottom (below) or whose left edge meets W's right edge
  ;; (right): the neighbor a drag of that edge would trade space with.
  (define (neighbor w dir)
    (let* ([e (window-edges w)] [x (car e)] [y (cadr e)] [ww (caddr e)] [h (cadddr e)])
      (find (lambda (o)
              (and (not (eq? o w))
                   (let ([oe (window-edges o)])
                     (case dir
                       [(below) (and (< (abs (- (cadr oe) (+ y h))) 2)
                                     (< x (+ (car oe) (caddr oe))) (> (+ x ww) (car oe)))]
                       [else (and (< (abs (- (car oe) (+ x ww))) 2)
                                  (< y (+ (cadr oe) (cadddr oe))) (> (+ y h) (cadr oe)))]))))
            (window-list))))

  ;; ---- text positions ----

  (define (text-window? w)
    (and (not (window-native w)) (not (window-canvas w))))

  ;; Buffer position under frame point (X, Y) in W; the point is clamped into the text area
  ;; vertically, so a drag past the edge still reaches the first or last visible line.
  (define (position-in w x y)
    (let* ([e (window-edges w)] [body (- (cadddr e) (mode-line-h w))]
           [ly (max 0.0 (min (- y (cadr e)) (- body 1.0)))])
      (%win-pos-at (window-handle* w) (inexact (- x (car e))) (inexact ly))))

  (define (word-char? c) (and c (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_))))

  ;; (values start end) of the word at POS, or just POS when there is none.
  (define (word-bounds pos)
    (if (word-char? (char-after pos))
        (let* ([s (let loop ([i pos]) (if (and (> i 0) (word-char? (char-before i))) (loop (- i 1)) i))]
               [e (let loop ([i pos]) (if (word-char? (char-after i)) (loop (+ i 1)) i))])
          (values s e))
        (values pos pos)))

  ;; (values start end) of the line at POS, including its newline.
  (define (line-bounds pos)
    (let* ([h (%buffer-handle (current-buffer))] [line (%buf-line-of h pos)])
      (values (%buf-line-start h line)
              (if (< (+ line 1) (%buf-lines h)) (%buf-line-start h (+ line 1)) (point-max)))))

  ;; ---- drags ----
  ;; #f, or (text window anchor) / (resize window direction last) / (canvas).

  (define drag #f)

  (define (select! from to)
    (set-mark! from)
    (var-set! 'mark-active (not (= from to)))
    (goto-char to))

  (define (handle-mouse kind x y clicks)
    (let ([x (inexact x)] [y (inexact y)])
      (case kind
        [(down) (mouse-down x y clicks)]
        [(drag) (mouse-drag x y)]
        [(up) (set! drag #f)]
        [else (void)])))

  (define (mouse-down x y clicks)
    (set! drag #f)
    (cond
      [(canvas-click! x y) (set! drag '(canvas))]
      [(tab-bar-click! x y) (void)]
      [(window-at x y)
       => (lambda (w)
            (let* ([e (window-edges w)] [lx (- x (car e))] [ly (- y (cadr e))]
                   [on-mode-line (> ly (- (cadddr e) (mode-line-h w)))])
              (cond
                [(and on-mode-line (> (mode-line-h w) 0) (neighbor w 'below))
                 (select-window w)
                 (set! drag (list 'resize w 'below y))]
                [(and (> lx (- (caddr e) 4)) (neighbor w 'right))
                 (select-window w)
                 (set! drag (list 'resize w 'right x))]
                [on-mode-line (select-window w)]
                [(< ly (header-h w)) (select-window w)]
                [(not (text-window? w)) (select-window w)]
                [else (text-down w x y clicks)])))]
      [else (void)]))

  (define (text-down w x y clicks)
    (select-window w)
    (let ([pos (position-in w x y)])
      (when (>= pos 0)
        (goto-char pos)
        (case clicks
          [(2) (let-values ([(s e) (word-bounds pos)])
                 (select! s e)
                 (set! drag (list 'text w s)))]
          [(3) (let-values ([(s e) (line-bounds pos)])
                 (select! s e)
                 (set! drag (list 'text w s)))]
          [else
           (var-set! 'mark-active #f)
           (set! drag (list 'text w pos))]))))

  (define (mouse-drag x y)
    (when (and drag (not (eq? (car drag) 'canvas)))
      (case (car drag)
        [(text)
         (let ([w (cadr drag)])
           (when (and (window-live? w) (eq? (selected-window) w))
             (let* ([e (window-edges w)] [body (- (cadddr e) (mode-line-h w))] [ly (- y (cadr e))])
               (cond [(< ly 0) (scroll-lines! w -1)]
                     [(>= ly body) (scroll-lines! w 1)]))
             (let ([pos (position-in w x y)])
               (when (>= pos 0) (select! (caddr drag) pos)))))]
        [(resize)
         (let* ([w (cadr drag)] [dir (caddr drag)] [last (cadddr drag)]
                [delta (- (if (eq? dir 'below) y x) last)])
           (when (window-live? w)
             (let ([moved (guard (c [else 0]) (resize-window! w delta dir))])
               (set! drag (list 'resize w dir (+ last (if (number? moved) moved 0)))))))])))

  ;; ---- scrolling ----

  (define fractions (make-weak-eq-hashtable)) ; window -> unscrolled fraction of a line

  (define (scroll-lines! w n) (scroll-window-lines! w n))

  (define (handle-scroll x y dx dy precise)
    (let ([w (window-at (inexact x) (inexact y))])
      (when (and w (text-window? w))
        (let* ([fh (frame-h)]
               [lh (%frm-line-height fh 1.0)] [cw (%frm-cell-width fh 1.0)]
               [lines (+ (hashtable-ref fractions w 0.0)
                         (/ (if precise (inexact dy) (* 3.0 lh (inexact dy))) lh))]
               [whole (exact (truncate lines))])
          ;; positive dy: the content moves down, so the window shows earlier lines
          (hashtable-set! fractions w (- lines whole))
          (unless (zero? whole) (scroll-lines! w (- whole)))
          (let ([cols (exact (truncate (/ (inexact dx) cw)))])
            (unless (zero? cols)
              (set-window-hscroll! w (max 0 (- (window-hscroll w) cols)))))))))
  )
