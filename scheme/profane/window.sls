;;; (profane window) — frames, the window tree, the echo area and mode lines. Unstable API
;;; (plan §10).
;;;
;;; A frame (one per editor surface) holds a tree of windows: leaves are windows, inner nodes
;;; ("splits") divide their area `below` (stacked) or `right` (side by side) among children by
;;; weight — fractions summing to 1, so resizing the frame keeps proportions. The tree lives
;;; here; the C frame (core/display/pf_frame.h) only places and renders what it is told. Under
;;; the tree is the minibuffer window, which shows the echo area (messages); reading input there
;;; comes with the minibuffer (M2 item 5). The tab bar (profane tab-bar) sits above the tree.
;;;
;;; Each window has its own point (Emacs window-point): the selected window shows the buffer's
;;; point, the others a marker of their own, and selecting a window moves the buffer's point to
;;; that window's.
;;;
;;; The shell calls (redisplay-prepare!) before every redisplay: it follows the frame size,
;;; replaces killed buffers, runs pre-redisplay-hook and pushes mode lines and text scales that
;;; changed.

(library (profane window)
  (export frame? selected-frame select-frame make-headless-frame delete-headless-frame!
          frame-root frame-width frame-height frame-windows frame-selected-window
          window? window-live? window-frame window-buffer set-window-buffer! window-parent
          selected-window select-window minibuffer-window window-minibuffer?
          window-point set-window-point! window-start-line set-window-start-line!
          window-body-lines window-hscroll set-window-hscroll! window-edges window-list next-window window-label set-window-label!
          window-prev-buffers window-next-buffers scroll-window-lines!
          window-pos-rect window-row-start window-row-end window-row-x window-move-rows window-visible-range window-native set-window-native! native-view-kinds register-native-view-kind!
          split? split-direction split-children split-weights split-parent
          split-window delete-window delete-other-windows balance-windows resize-window!
          switch-to-buffer other-buffer
          add-side-window window-dedicated? set-window-dedicated! display-buffer-in-other-window
          define-mode-line-segment register-mode-line-segment! format-mode-line
          redisplay-prepare!
          ;; internal, for (profane tab-bar) and (profane transpose-frame)
          %make-window %delete-tree! %frame-set-root! %set-frame-top-margin! %relayout!
          %split-direction-set! %split-children-set! %split-weights-set! %frame-handle
          %window-handle
          ;; internal, for (profane minibuffer)
          %minibuffer-activate! %minibuffer-sync! %minibuffer-deactivate! %minibuffer-active?)
  (import (chezscheme) (profane native) (profane buffer) (profane var) (profane hook)
          (profane mode) (profane command) (profane keymap) (profane display) (profane theme))

  ;; ---- records ----

  (define-record-type (frame %make-frame frame?)
    (fields handle
            (mutable root) (mutable selected) (mutable minibuffer)
            (mutable windows)       ; every live window but the minibuffer, in all tabs
            (mutable size)          ; (width . height) the layout was made for
            (mutable echo-lines)    ; lines the echo area shows
            (mutable top-margin)    ; points above the tree (the tab bar)
            (mutable headless?))
    (nongenerative profane-frame))

  (define-record-type (window %new-window window?)
    (fields frame handle
            (mutable buffer)
            (mutable marker)     ; this window's point, a marker id in its buffer
            (mutable parent)     ; a split, or #f at the root
            (mutable edges)      ; (x y width height) in points
            (mutable live?)
            (mutable mode-line)  ; what was last pushed, to skip unchanged ones
            (mutable scale)      ; text scale last pushed
            (mutable use-time)   ; for picking the most recently used window
            (mutable label))     ; a jump label shown in the mode line (ace-window), or #f
    (nongenerative profane-window))

  (define-record-type (split %make-split split?)
    (fields (mutable direction) ; below | right
            (mutable children)
            (mutable weights)   ; exact fractions summing to 1
            (mutable parent)
            (mutable edges))
    (nongenerative profane-window-split))

  (define printers
    (begin
      (record-writer (record-type-descriptor window)
                     (lambda (w p wr)
                       (fprintf p "#<window ~a~a>" (window-handle w)
                                (if (and (window-live? w) (buffer-live? (window-buffer w)))
                                    (format " on ~a" (buffer-name (window-buffer w)))
                                    ""))))
      (record-writer (record-type-descriptor frame)
                     (lambda (f p wr) (fprintf p "#<frame ~a>" (frame-handle f))))
      #t))

  (define (%split-direction-set! s d) (split-direction-set! s d))
  (define (%split-children-set! s cs)
    (split-children-set! s cs)
    (for-each (lambda (c) (set-parent! c s)) cs))
  (define (%split-weights-set! s ws) (split-weights-set! s ws))
  (define (%frame-handle f) (frame-handle f))
  (define (%window-handle w) (window-handle w))

  ;; Position of X in XS (eq?), or #f.
  (define (index-of x xs)
    (let loop ([xs xs] [i 0])
      (cond [(null? xs) #f] [(eq? (car xs) x) i] [else (loop (cdr xs) (+ i 1))])))

  (define (node-parent n) (if (window? n) (window-parent n) (split-parent n)))
  (define (set-parent! n p) (if (window? n) (window-parent-set! n p) (split-parent-set! n p)))

  ;; ---- variables ----

  (defvar window-min-height 4 "Fewest text lines a window may have.")
  (defvar window-min-width 10 "Fewest columns a window may have.")
  (defvar cursor-in-non-selected-windows #t
    "Show a hollow cursor in windows other than the selected one (else none).")
  (defvar max-mini-window-height 1/4
    "Largest echo area, as a fraction of the frame's height.")
  ;; Run with the frame before each redisplay, after layout (the tab bar updates itself here).
  (defhook pre-redisplay-hook)

  ;; ---- frames ----

  (define frames (make-eqv-hashtable)) ; frame handle -> frame

  ;; The selected frame, set up on first use: one window on *scratch* and the minibuffer
  ;; window. #f without one (headless, most tests).
  (define (selected-frame)
    (let ([h (%frm-selected)])
      (and (not (zero? h))
           (or (hashtable-ref frames h #f) (init-frame! h #f)))))

  (define (select-frame f) (%frm-set-selected (frame-handle f)) f)

  ;; A frame that is never shown, with a fixed-width fake font: window code without a window
  ;; server (tests). Select it with select-frame.
  (define (make-headless-frame width height)
    (let ([h (%frm-new-headless (inexact width) (inexact height))])
      (when (zero? h) (error 'make-headless-frame "could not create a frame"))
      (init-frame! h #t)))

  (define (delete-headless-frame! f)
    (unless (frame-headless? f) (error 'delete-headless-frame! "not a headless frame" f))
    (for-each (lambda (w) (window-live?-set! w #f) (free-marker! w))
              (cons (frame-minibuffer f) (frame-windows f)))
    (hashtable-delete! frames (frame-handle f))
    (%frm-free-headless (frame-handle f))
    (void))

  (define (init-frame! h headless?)
    (let ([f (%make-frame h #f #f #f '() '(0 . 0) 1 0 headless?)])
      (hashtable-set! frames h f)
      (let ([root (%make-window f (get-buffer-create "*scratch*"))]
            [mini (new-window f (echo-buffer))])
        (frame-minibuffer-set! f mini)
        (frame-windows-set! f (remq mini (frame-windows f)))
        (%win-set-option (window-handle mini) cursor-option 0)
        (frame-root-set! f root)
        (select-window root)
        (%relayout! f)
        f)))

  (define (frame-selected-window f) (frame-selected f))
  (define (frame-width f) (%frm-width (frame-handle f)))
  (define (frame-height f) (%frm-height (frame-handle f)))

  ;; ---- windows ----

  (define cursor-option 4) ; pf_window_option PF_WINDOW_CURSOR
  (define wrap-option 5)   ; PF_WINDOW_WRAP: 0 truncate, 1 at the last character, 2 at whitespace
  (define cursor-box 1)
  (define cursor-hollow 2)

  (define clock 0)
  (define (tick!) (set! clock (+ clock 1)) clock)

  (define (new-window f buffer)
    (let ([h (%frm-window-new (frame-handle f))])
      (when (zero? h) (error 'split-window "could not create a window"))
      (let ([w (%new-window f h #f #f #f '(0 0 0 0) #t #f 1.0 0 #f)])
        (frame-windows-set! f (cons w (frame-windows f)))
        (attach-buffer! w buffer)
        w)))

  ;; A window of frame F showing BUFFER, not yet in the tree, with the display modes on.
  (define (%make-window f buffer)
    (let ([w (new-window f buffer)])
      (apply-display-options! w)
      (%win-set-option (window-handle w) cursor-option (non-selected-cursor))
      w))

  (define (non-selected-cursor)
    (if (var-ref 'cursor-in-non-selected-windows) cursor-hollow 0))

  (define (check-live who w)
    (unless (and (window? w) (window-live? w)) (error who "not a live window" w)))

  (define (selected-window)
    (let ([f (selected-frame)]) (and f (frame-selected f))))

  (define (minibuffer-window) (let ([f (selected-frame)]) (and f (frame-minibuffer f))))
  (define (window-minibuffer? w) (eq? w (frame-minibuffer (window-frame w))))

  (define (selected? w) (eq? w (frame-selected (window-frame w))))

  (define (free-marker! w)
    (let ([b (window-buffer w)])
      (when (and b (buffer-live? b) (window-marker w))
        (%buf-marker-free (%buffer-handle b) (window-marker w))))
    (window-marker-set! w #f))

  ;; Points the C window at the buffer's point (selected) or its own marker.
  (define (push-buffer! w)
    (let ([b (window-buffer w)])
      (%win-set-buffer (window-handle w) (%buffer-handle b)
                       (if (selected? w) (%buffer-point-marker b) (window-marker w)))))

  (define (buffer-point b) (with-current-buffer b (point)))

  (define (attach-buffer! w b)
    (free-marker! w)
    (window-buffer-set! w b)
    (window-marker-set! w (%buf-marker-new (%buffer-handle b) (buffer-point b) #f))
    (push-buffer! w)
    (apply-display-options! w))

  (define (set-window-buffer! w buffer)
    (check-live 'set-window-buffer! w)
    (let ([b (get-buffer buffer)])
      (unless (and b (buffer-live? b)) (error 'set-window-buffer! "no such live buffer" buffer))
      (let ([old (window-buffer w)])
        (attach-buffer! w b)
        (unless (or navigating (eq? old b)) (remember-previous! w old)))
      (when (selected? w) (set-buffer b))
      b))

  ;; Each window remembers the buffers it showed before (most recent first) and, after
  ;; previous-buffer, those it can go forward to; switching to a buffer by any other means
  ;; starts the forward list over, as in Emacs.
  (define prev-buffers (make-weak-eq-hashtable))
  (define next-buffers (make-weak-eq-hashtable))
  (define navigating #f)
  (define history-length 30)

  (define (live-history table w) (filter buffer-live? (hashtable-ref table w '())))

  (define (remember-previous! w old)
    (when (and old (buffer-live? old))
      (let ([h (cons old (remq old (live-history prev-buffers w)))])
        (hashtable-set! prev-buffers w (if (> (length h) history-length) (list-head h history-length) h))
        (hashtable-delete! next-buffers w))))

  (define (window-prev-buffers w) (live-history prev-buffers w))
  (define (window-next-buffers w) (live-history next-buffers w))

  (define (window-point w)
    (let ([b (window-buffer w)])
      (cond
        [(not (and (window-live? w) (buffer-live? b))) 0]
        [(selected? w) (buffer-point b)]
        [else (%buf-marker-pos (%buffer-handle b) (window-marker w))])))

  (define (set-window-point! w pos)
    (check-live 'set-window-point! w)
    (let ([b (window-buffer w)])
      (if (selected? w)
          (with-current-buffer b (goto-char pos))
          (%buf-marker-set (%buffer-handle b) (window-marker w)
                           (max 0 (min pos (with-current-buffer b (point-max))))))
      (window-point w)))

  ;; Leaves F with no selected window. The selected window shows its buffer's point, so that
  ;; point is saved into the window's own marker first: every unselected window's marker is
  ;; current.
  (define (deselect! f)
    (let ([old (frame-selected f)])
      (when old
        (frame-selected-set! f #f)
        (when (window-live? old)
          (when (buffer-live? (window-buffer old))
            (%buf-marker-set (%buffer-handle (window-buffer old)) (window-marker old)
                             (buffer-point (window-buffer old)))
            (push-buffer! old))
          (apply-display-options! old)
          (%win-set-option (window-handle old) cursor-option (non-selected-cursor))))))

  ;; Makes W the selected window and its buffer current. The old window keeps its point in its
  ;; own marker; the buffer's point moves to W's.
  (define (select-window w)
    (check-live 'select-window w)
    (let ([f (window-frame w)])
      (when (window-minibuffer? w) (error 'select-window "the minibuffer is not active" w))
      (unless (memq w (window-list f)) (error 'select-window "window is not in the frame's tree" w))
      (unless (eq? w (frame-selected f))
        (deselect! f)
        (let ([pos (%buf-marker-pos (%buffer-handle (window-buffer w)) (window-marker w))])
          (with-current-buffer (window-buffer w) (goto-char pos)))
        (frame-selected-set! f w)
        (push-buffer! w)
        (apply-display-options! w)
        (%win-set-option (window-handle w) cursor-option cursor-box)
        (%frm-select-window (frame-handle f) (window-handle w)))
      (window-use-time-set! w (tick!))
      (set-buffer (window-buffer w))
      w))

  ;; (x y w h) of character POS in W, in W's own coordinates, or #f when it is not on screen.
  (define (window-pos-rect w pos)
    (let ([bv (make-bytevector 16)])
      (and (zero? (%win-pos-rect (window-handle w) pos bv))
           (map (lambda (i) (bytevector-ieee-single-native-ref bv (* 4 i))) '(0 1 2 3)))))

  ;; Screen rows (soft wrap), as W would lay them out now: where POS's row starts and ends (the
  ;; end is the next row's start, or the line's end on the last row), its x within the row in
  ;; points, and the position K rows down (up when negative) nearest x GOAL.
  (define (window-row-start w pos) (%win-row-start (window-handle w) pos))
  (define (window-row-end w pos) (%win-row-end (window-handle w) pos))
  (define (window-row-x w pos) (%win-row-x (window-handle w) pos))
  (define (window-move-rows w pos k goal) (%win-move-rows (window-handle w) pos k (inexact goal)))

  ;; The characters from the first line W shows to the end of its last: (values start end).
  (define (window-visible-range w)
    (let* ([b (window-buffer w)] [h (%buffer-handle b)]
           [lines (%buf-lines h)]
           [top (window-start-line w)]
           [end-line (min lines (+ top (window-body-lines w) 1))])
      (values (%buf-line-start h top)
              (if (>= end-line lines) (%buf-chars h) (%buf-line-start h end-line)))))

  (define (window-start-line w) (%win-top-line (window-handle w)))
  (define (set-window-start-line! w line) (%win-set-top-line (window-handle w) (max 0 line)))
  (define (window-body-lines w) (%win-body-lines (window-handle w)))

  ;; Columns (default-font cells) the window is scrolled sideways. Redisplay scrolls to keep point
  ;; visible (auto-hscroll); a value set here is the least it scrolls (Emacs scroll-left).
  (define (window-hscroll w)
    (exact (round (/ (%win-hscroll (window-handle w)) (cell-width (window-frame w))))))
  (define (set-window-hscroll! w columns)
    (%win-set-min-hscroll (window-handle w)
                          (inexact (* (max 0 columns) (cell-width (window-frame w)))))
    (max 0 columns))

  ;; ---- the tree ----

  (define (leaves node)
    (if (window? node) (list node) (apply append (map leaves (split-children node)))))

  ;; Windows of F's tree (the current tab), in order: top to bottom, left to right.
  (define window-list
    (case-lambda
      [() (let ([f (selected-frame)]) (if f (window-list f) '()))]
      [(f) (if (frame-root f) (leaves (frame-root f)) '())]))

  ;; The window N places after W in window-list order, cyclically.
  (define (next-window w n)
    (let ([ws (window-list (window-frame w))])
      (list-ref ws (mod (+ (index-of w ws) n) (length ws)))))

  (define (set-window-label! w label) (window-label-set! w label))

  ;; ---- native-view windows ----
  ;; A window of a native kind leaves its body to a platform view the shell places there (plan
  ;; §1, §4); it keeps its buffer for the mode line. Kinds are the shell's view classes by
  ;; number: stub is a placeholder view, web and PDF kinds register with their milestones.

  (define view-kinds (list (cons 'stub 1)))
  (define (native-view-kinds) (map car view-kinds))
  (define (register-native-view-kind! name number)
    (set! view-kinds (cons (cons name number) (remp (lambda (k) (eq? (car k) name)) view-kinds))))

  (define native-of (make-weak-eq-hashtable)) ; window -> kind name

  (define (window-native w) (hashtable-ref native-of w #f))

  ;; KIND: a registered name, or #f for an ordinary text window.
  (define (set-window-native! w kind)
    (check-live 'set-window-native! w)
    (let ([n (cond [(not kind) 0]
                   [(assq kind view-kinds) => cdr]
                   [else (error 'set-window-native! "no such native view kind" kind)])])
      (when (window-minibuffer? w) (error 'set-window-native! "not for the minibuffer" w))
      (%frm-set-window-native (frame-handle (window-frame w)) (window-handle w) n)
      (if kind (hashtable-set! native-of w kind) (hashtable-delete! native-of w))
      kind))

  ;; Puts NEW in OLD's place under OLD's parent (or at the root).
  (define (replace-node! f old new)
    (let ([p (node-parent old)])
      (set-parent! new p)
      (if p
          (split-children-set! p (map (lambda (c) (if (eq? c old) new c)) (split-children p)))
          (frame-root-set! f new))))

  (define (line-height f) (%frm-line-height (frame-handle f) 1.0))
  (define (cell-width f) (%frm-cell-width (frame-handle f) 1.0))
  (define (mode-line-box?) (eq? (var-ref 'ui-mode-line-style) 'raised))
  (define (mode-line-height f)
    (+ (if (var-ref 'mode-line-format)
           (%frm-strip-height (frame-handle f) (face-id 'mode-line) (mode-line-box?))
           0)
       ;; a window with a header line needs room for it too
       (if (var-ref 'header-line-format)
           (%frm-strip-height (frame-handle f) (face-id 'header-line) (mode-line-box?))
           0)))

  ;; The smallest window: window-min-height lines plus its mode line, window-min-width cells
  ;; plus fringes.
  (define (min-size f direction)
    (if (eq? direction 'below)
        (+ (* (var-ref 'window-min-height) (line-height f)) (mode-line-height f) 2)
        (+ (* (var-ref 'window-min-width) (cell-width f)) (* 2 (var-ref 'ui-fringe-width)) 1)))

  (define (extent edges direction) (if (eq? direction 'below) (cadddr edges) (caddr edges)))

  ;; Emacs split-window: a new window below or right of W showing its buffer, point and start,
  ;; taking half of W's space. W stays selected.
  (define split-window
    (case-lambda
      [() (split-window (selected-window) 'below)]
      [(w) (split-window w 'below)]
      [(w side)
       (check-live 'split-window w)
       (unless (memq side '(below right)) (error 'split-window "side is below or right" side))
       (when (window-minibuffer? w) (error 'split-window "cannot split the minibuffer window"))
       (let ([f (window-frame w)])
         (when (< (/ (extent (window-edges w) side) 2) (min-size f side))
           (error 'split-window "window too small for splitting"))
         (let ([new (%make-window f (window-buffer w))]
               [p (window-parent w)])
           (set-window-point! new (window-point w))
           (set-window-start-line! new (window-start-line w))
           (if (and p (eq? (split-direction p) side))
               ;; Same direction: a new sibling after W, sharing W's weight.
               (let loop ([cs (split-children p)] [ws (split-weights p)] [cs* '()] [ws* '()])
                 (cond
                   [(null? cs) (split-children-set! p (reverse cs*))
                               (split-weights-set! p (reverse ws*))]
                   [(eq? (car cs) w)
                    (let ([half (/ (car ws) 2)])
                      (loop (cdr cs) (cdr ws) (cons* new w cs*) (cons* half half ws*)))]
                   [else (loop (cdr cs) (cdr ws) (cons (car cs) cs*) (cons (car ws) ws*))]))
               (let ([s (%make-split side (list w new) '(1/2 1/2) #f #f)])
                 (replace-node! f w s)
                 (window-parent-set! w s)))
           (window-parent-set! new (window-parent w))
           (%relayout! f)
           new))]))

  ;; A dedicated window keeps its buffer: switch-to-buffer in it goes to another window.
  (define dedicated (make-weak-eq-hashtable))
  (define (window-dedicated? w) (hashtable-ref dedicated w #f))
  (define (set-window-dedicated! w flag)
    (if flag (hashtable-set! dedicated w #t) (hashtable-delete! dedicated w))
    flag)

  ;; A new window showing BUFFER along the whole left (or right) edge of F, COLUMNS wide (at most
  ;; half the frame), like Emacs's side windows; the other windows keep their layout in the rest.
  (define (add-side-window f buffer side columns)
    (unless (memq side '(left right)) (error 'add-side-window "side is left or right" side))
    (let* ([new (%make-window f (get-buffer buffer))]
           [old (frame-root f)]
           [total (max 1 (exact (round (frame-width f))))]
           [frac (min 1/2 (/ (exact (round (* columns (cell-width f)))) total))]
           [left? (eq? side 'left)])
      (if (and (split? old) (eq? (split-direction old) 'right))
          (let ([scaled (map (lambda (x) (* x (- 1 frac))) (split-weights old))])
            (split-children-set! old (if left? (cons new (split-children old)) (append (split-children old) (list new))))
            (split-weights-set! old (if left? (cons frac scaled) (append scaled (list frac))))
            (set-parent! new old))
          (let ([s (%make-split 'right (if left? (list new old) (list old new))
                                (if left? (list frac (- 1 frac)) (list (- 1 frac) frac)) #f #f)])
            (replace-node! f old s)
            (set-parent! old s)
            (set-parent! new s)))
      (%relayout! f)
      new))

  ;; Shows BUFFER in a window other than the selected one (the most recently used that is not
  ;; dedicated), splitting the selected window to the right if it is alone; selects it when SELECT?.
  ;; Returns the window.
  (define display-buffer-in-other-window
    (case-lambda
      [(b) (display-buffer-in-other-window b #f)]
      [(b select?)
       (let* ([w (selected-window)]
              [others (filter (lambda (x) (not (or (eq? x w) (window-dedicated? x) (window-minibuffer? x))))
                              (window-list (window-frame w)))]
              [target (if (pair? others) (most-recently-used others) (split-window w 'right))])
         (set-window-buffer! target b)
         (when select? (select-window target))
         target)]))

  (define (destroy-window! w)
    (let ([f (window-frame w)])
      (free-marker! w)
      (window-live?-set! w #f)
      (frame-windows-set! f (remq w (frame-windows f)))
      (%frm-window-delete (frame-handle f) (window-handle w))))

  ;; Deletes every window under NODE (a tab being closed).
  (define (%delete-tree! node) (for-each destroy-window! (leaves node)))

  (define (most-recently-used ws)
    (fold-left (lambda (best w)
                 (if (or (not best) (> (window-use-time w) (window-use-time best))) w best))
               #f ws))

  ;; Emacs delete-window: W's space goes to the sibling before it (after it if first); the
  ;; most recently used window is selected if W was.
  (define delete-window
    (case-lambda
      [() (delete-window (selected-window))]
      [(w)
       (check-live 'delete-window w)
       (let* ([f (window-frame w)] [p (window-parent w)])
         (unless p (error 'delete-window "attempt to delete the sole window"))
         (let* ([cs (split-children p)] [ws (split-weights p)]
                [i (index-of w cs)]
                [heir (if (> i 0) (- i 1) 1)]
                [ws (map (lambda (x j)
                           (cond [(= j i) 0] [(= j heir) (+ x (list-ref ws i))] [else x]))
                         ws (iota (length ws)))])
           (split-children-set! p (remq w cs))
           (split-weights-set! p (let loop ([ws ws] [j 0])
                                   (cond [(null? ws) '()]
                                         [(= j i) (loop (cdr ws) (+ j 1))]
                                         [else (cons (car ws) (loop (cdr ws) (+ j 1)))])))
           (when (null? (cdr (split-children p))) (collapse! f p)))
         (let ([was-selected (selected? w)])
           (when was-selected (deselect! f))
           (destroy-window! w)
           (when was-selected (select-window (most-recently-used (window-list f)))))
         (%relayout! f))]))

  ;; A split left with one child is replaced by it; a child split in the same direction as
  ;; its new parent merges into it.
  (define (collapse! f p)
    (let ([c (car (split-children p))] [gp (split-parent p)])
      (replace-node! f p c)
      (when (and gp (split? c) (eq? (split-direction c) (split-direction gp)))
        (let ([wc (list-ref (split-weights gp) (index-of c (split-children gp)))])
          (split-weights-set!
           gp (apply append (map (lambda (x w)
                                   (if (eq? x c)
                                       (map (lambda (y) (* y wc)) (split-weights c))
                                       (list w)))
                                 (split-children gp) (split-weights gp))))
          (%split-children-set!
           gp (apply append (map (lambda (x) (if (eq? x c) (split-children c) (list x)))
                                 (split-children gp))))))))

  ;; Emacs delete-other-windows: W fills the frame.
  (define delete-other-windows
    (case-lambda
      [() (delete-other-windows (selected-window))]
      [(w)
       (check-live 'delete-other-windows w)
       (let ([f (window-frame w)])
         (deselect! f)
         (for-each (lambda (x) (unless (eq? x w) (destroy-window! x))) (window-list f))
         (window-parent-set! w #f)
         (frame-root-set! f w)
         (select-window w)
         (%relayout! f))]))

  ;; Emacs balance-windows: each split shares its space by how many windows its children hold
  ;; in the split's direction.
  (define balance-windows
    (case-lambda
      [() (let ([f (selected-frame)]) (when f (balance-windows f)))]
      [(f)
       (let balance ([n (frame-root f)])
         (when (split? n)
           (let* ([counts (map (lambda (c) (slices c (split-direction n))) (split-children n))]
                  [total (apply + counts)])
             (split-weights-set! n (map (lambda (k) (/ k total)) counts))
             (for-each balance (split-children n)))))
       (%relayout! f)]))

  (define (slices n direction)
    (cond
      [(window? n) 1]
      [else (let ([counts (map (lambda (c) (slices c direction)) (split-children n))])
              (apply (if (eq? (split-direction n) direction) + max) counts))]))

  ;; Grows W by DELTA points in DIRECTION (below: height, right: width), taking the space from
  ;; the neighbor after it (before it if last). Returns the points actually moved.
  (define (resize-window! w delta direction)
    (check-live 'resize-window! w)
    (let* ([f (window-frame w)]
           [split+child (let up ([n w])
                          (let ([p (node-parent n)])
                            (cond [(not p) #f]
                                  [(eq? (split-direction p) direction) (cons p n)]
                                  [else (up p)])))])
      (unless split+child (error 'resize-window! "no window to take the space from"))
      (let* ([p (car split+child)] [c (cdr split+child)]
             [cs (split-children p)] [ws (split-weights p)]
             [i (index-of c cs)]
             [j (if (< (+ i 1) (length cs)) (+ i 1) (- i 1))]
             [total (extent (split-edges p) direction)]
             [smallest (min-size f direction)]
             [size (lambda (k) (* total (list-ref ws k)))]
             [d (max (- smallest (size i)) (min delta (- (size j) smallest)))]
             [dw (if (zero? total) 0 (/ (exact (round d)) (exact (round total))))])
        (split-weights-set! p (map (lambda (x k)
                                     (cond [(= k i) (+ x dw)] [(= k j) (- x dw)] [else x]))
                                   ws (iota (length ws))))
        (%relayout! f)
        (* dw total))))

  ;; ---- layout ----

  (define (place! w x y width height shown)
    (window-edges-set! w (map inexact (list x y width height)))
    (%frm-place-window (frame-handle (window-frame w)) (window-handle w)
                       (inexact x) (inexact y) (inexact width) (inexact height) shown))

  (define (echo-height f)
    (let* ([lh (line-height f)]
           [cap (max 1 (floor (/ (* (var-ref 'max-mini-window-height) (frame-height f)) lh)))])
      (+ 4 (* lh (min cap (frame-echo-lines f))))))

  ;; Lays F's tree out in the frame, hides windows of other tabs, places the minibuffer.
  (define (%relayout! f)
    (let* ([width (frame-width f)] [height (frame-height f)]
           [top (min (frame-top-margin f) height)]
           [mini (min (echo-height f) (- height top))]
           [fringe (var-ref 'ui-fringe-width)]
           [shown (window-list f)])
      (frame-size-set! f (cons width height))
      (for-each (lambda (w)
                  (unless (memq w shown)
                    (apply place! w (append (window-edges w) '(#f)))))
                (frame-windows f))
      (let layout ([n (frame-root f)] [x 0] [y top] [w width] [h (- height top mini)])
        (if (window? n)
            (begin
              (place! n x y w h #t)
              (%win-set-edges (window-handle n) (inexact fringe) (inexact fringe)
                              (if (< (+ x w) (- width 1/2)) 1.0 0.0)))
            (let ([dir (split-direction n)])
              (split-edges-set! n (list x y w h))
              (let loop ([cs (split-children n)] [ws (split-weights n)] [acc 0])
                (unless (null? cs)
                  (let* ([start (if (eq? dir 'below) y x)]
                         [total (if (eq? dir 'below) h w)]
                         [a (+ acc (car ws))]
                         [from (round (+ start (* total acc)))]
                         [to (if (null? (cdr cs)) (+ start total) (round (+ start (* total a))))])
                    (if (eq? dir 'below)
                        (layout (car cs) x from w (- to from))
                        (layout (car cs) from y (- to from) h))
                    (loop (cdr cs) (cdr ws) a)))))))
      (let ([m (frame-minibuffer f)])
        (place! m 0 (- height mini) width mini #t)
        (%win-set-edges (window-handle m) (inexact fringe) (inexact fringe) 0.0))))

  (define (%set-frame-top-margin! f points)
    (unless (= points (frame-top-margin f))
      (frame-top-margin-set! f points)
      (%relayout! f)))

  ;; Shows tree ROOT with SELECTED selected (a tab switch); windows outside it are hidden.
  (define (%frame-set-root! f root selected)
    (deselect! f)
    (set-parent! root #f)
    (frame-root-set! f root)
    (for-each (lambda (w)
                (apply-display-options! w)
                (%win-set-option (window-handle w) cursor-option (non-selected-cursor)))
              (leaves root))
    (select-window selected)
    (%relayout! f))

  ;; ---- buffers in windows ----

  (define (visible-buffer? b)
    (let ([name (buffer-name b)])
      (and (buffer-live? b) (> (string-length name) 0) (not (char=? (string-ref name 0) #\space)))))

  ;; A buffer to show instead of B: one not shown in any window if possible, else any other.
  (define other-buffer
    (case-lambda
      [() (other-buffer (current-buffer))]
      [(b)
       (let* ([candidates (filter (lambda (x) (and (visible-buffer? x) (not (eq? x b))))
                                  (buffer-list))]
              [shown (map window-buffer (window-list))]
              [hidden (filter (lambda (x) (not (memq x shown))) candidates)])
         (cond [(pair? hidden) (car hidden)]
               [(pair? candidates) (car candidates)]
               [else (get-buffer-create "*scratch*")]))]))

  (define (switch-to-buffer b)
    (let ([w (selected-window)] [b (get-buffer b)])
      (cond
        [(and w (window-dedicated? w))
         (let ([others (filter (lambda (x) (not (or (window-dedicated? x) (window-minibuffer? x))))
                               (window-list (window-frame w)))])
           (if (null? others)
               (error 'switch-to-buffer "the window is dedicated to its buffer")
               (let ([target (most-recently-used others)])
                 (select-window target)
                 (set-window-buffer! target b))))]
        [w (set-window-buffer! w b)]
        [else (set-buffer b)])))

  (define (cycle-buffer step)
    (let* ([bs (filter visible-buffer? (buffer-list))]
           [i (index-of (current-buffer) bs)])
      (when (and i (> (length bs) 1))
        (switch-to-buffer (list-ref bs (mod (+ i step) (length bs)))))))

  ;; Goes N buffers back (N > 0) or forward (N < 0) in the selected window's own history; with
  ;; none to go to, through the global buffer list as before.
  (define (navigate-buffers n)
    (let ([w (selected-window)])
      (let loop ([k (abs n)])
        (when (> k 0)
          (let* ([from (if (> n 0) prev-buffers next-buffers)]
                 [to (if (> n 0) next-buffers prev-buffers)]
                 [h (live-history from w)])
            (cond
              [(pair? h)
               (let ([current (window-buffer w)])
                 (hashtable-set! from w (cdr h))
                 (hashtable-set! to w (cons current (remq current (live-history to w))))
                 (set! navigating #t)
                 (guard (c [else (set! navigating #f) (raise c)])
                   (set-window-buffer! w (car h)))
                 (set! navigating #f))]
              [else (cycle-buffer (if (> n 0) -1 1))])
            (loop (- k 1)))))))

  (define-command (next-buffer) "Show the next buffer in the selected window."
    (navigate-buffers (- (prefix-numeric-value))))
  (define-command (previous-buffer) "Show the previous buffer in the selected window."
    (navigate-buffers (prefix-numeric-value)))

  ;; ---- scrolling ----

  ;; Scrolls W by N lines (negative: toward the start of the buffer), moving point to the
  ;; nearest visible line, same column, if that is what it takes to keep it on screen.
  (define (scroll-window-lines! w n)
    (let* ([b (window-buffer w)] [h (%buffer-handle b)]
           [lines (%buf-lines h)]
           [top (window-start-line w)]
           [new (max 0 (min (+ top n) (- lines 1)))])
      (unless (= new top)
        (set-window-start-line! w new)
        (let* ([body (window-body-lines w)]
               [pos (window-point w)] [line (%buf-line-of h pos)]
               [last (max new (min (- lines 1) (+ new (- body 1))))]
               [target (cond [(< line new) new] [(> line last) last] [else #f])])
          (when target (move-point-to-line! w h pos line target lines))))))

  (define (move-point-to-line! w h pos line target lines)
    (let* ([col (- pos (%buf-line-start h line))]
           [start (%buf-line-start h target)]
           [end (if (< (+ target 1) lines) (- (%buf-line-start h (+ target 1)) 1) (%buf-chars h))])
      (set-window-point! w (min (+ start col) end))))

  (defvar next-screen-context-lines 2
    "Lines of overlap between the screens C-v and M-v scroll through.")

  ;; C-v (sign 1) and M-v (sign -1): a screen less the context lines, or ARG lines with a prefix
  ;; argument. Point keeps its row on screen. When the end (start) is already visible, point
  ;; goes there first and only then does it complain, as in Emacs.
  (define (scroll-screen sign who)
    (let* ([w (selected-window)] [h (%buffer-handle (window-buffer w))]
           [lines (%buf-lines h)] [top (window-start-line w)] [body (window-body-lines w)]
           [arg (current-prefix-arg)]
           [n (* sign (if arg (prefix-numeric-value arg)
                          (max 1 (- body (var-ref 'next-screen-context-lines)))))]
           [pos (point)] [row (- (%buf-line-of h pos) top)])
      (cond
        [(and (> n 0) (>= (+ top body) lines))
         (if (= pos (point-max)) (error who "End of buffer") (goto-char (point-max)))]
        [(and (< n 0) (= top 0))
         (if (= pos (point-min)) (error who "Beginning of buffer") (goto-char (point-min)))]
        [else
         (let ([new (max 0 (min (+ top n) (- lines 1)))])
           (set-window-start-line! w new)
           (move-point-to-line! w h pos (%buf-line-of h pos)
                                (max 0 (min (+ new (max row 0)) (- lines 1))) lines))])))

  (define-command (scroll-up-command) "Scroll forward a screen (ARG lines with a prefix)."
    (scroll-screen 1 'scroll-up-command))
  (define-command (scroll-down-command) "Scroll back a screen (ARG lines with a prefix)."
    (scroll-screen -1 'scroll-down-command))

  ;; C-l: point's line in the middle of the window, then at the top, then at the bottom; with a
  ;; number, on that row (negative: from the bottom).
  (define recenter-step 0)

  (define-command (recenter-top-bottom)
    "Put point's line in the middle, then at the top, then at the bottom of the window."
    (let* ([w (selected-window)] [h (%buffer-handle (window-buffer w))]
           [body (max 1 (window-body-lines w))]
           [arg (current-prefix-arg)]
           [line (%buf-line-of h (point))]
           [row (cond
                  [arg (let ([n (prefix-numeric-value arg)]) (if (< n 0) (+ body n) n))]
                  [else
                   (set! recenter-step (if (eq? (last-command) 'recenter-top-bottom)
                                           (mod (+ recenter-step 1) 3)
                                           0))
                   (case recenter-step [(0) (quotient body 2)] [(1) 0] [else (- body 1)])])])
      (set-window-start-line! w (max 0 (- line (max 0 (min row (- body 1))))))))

  ;; ---- the echo area ----
  ;; Messages go into a buffer shown by the minibuffer window, which grows to fit them (up to
  ;; max-mini-window-height).

  (define echo-name " *Echo Area*")

  (define (echo-buffer)
    (let ([b (get-buffer echo-name)])
      (if (and b (buffer-live? b))
          b
          (let ([b (get-buffer-create echo-name)])
            (with-current-buffer b (buffer-disable-undo))
            b))))

  (define (newlines s) (length (filter (lambda (c) (char=? c #\newline)) (string->list s))))

  ;; While the minibuffer reads input the window shows its buffer instead; messages are still
  ;; logged but stay out of the way.
  (define mini-active #f)
  (define (%minibuffer-active?) mini-active)

  (define (%minibuffer-activate! buffer)
    (let ([f (selected-frame)])
      (set! mini-active #t)
      (attach-buffer! (frame-minibuffer f) buffer)
      (%win-set-option (window-handle (frame-minibuffer f)) cursor-option cursor-box)
      (let ([w (frame-selected f)])
        (when w (%win-set-option (window-handle w) cursor-option cursor-hollow)))
      (%minibuffer-sync!)))

  ;; Follows the minibuffer buffer's point and size (it grows to show several lines).
  (define (%minibuffer-sync!)
    (let* ([f (selected-frame)] [m (frame-minibuffer f)] [b (window-buffer m)])
      (set-window-point! m (buffer-point b))
      (let ([lines (+ 1 (newlines (with-current-buffer b (buffer-string))))])
        (unless (= lines (frame-echo-lines f))
          (frame-echo-lines-set! f lines)
          (%relayout! f)))))

  (define (%minibuffer-deactivate!)
    (let ([f (selected-frame)])
      (set! mini-active #f)
      (attach-buffer! (frame-minibuffer f) (echo-buffer))
      (%win-set-option (window-handle (frame-minibuffer f)) cursor-option 0)
      (let ([w (frame-selected f)])
        (when w (%win-set-option (window-handle w) cursor-option cursor-box)))
      (frame-echo-lines-set! f 1)
      (%relayout! f)))

  (define (show-echo! text)
    (let ([b (if mini-active #f (echo-buffer))])
     (when b
      (with-current-buffer b
        (unless (and (not text) (zero? (buffer-size)))
          (erase-buffer)
          (when text (insert text))))
      (let ([f (selected-frame)])
        (when f
          (unless (eq? (window-buffer (frame-minibuffer f)) b)
            (attach-buffer! (frame-minibuffer f) b))
          (set-window-point! (frame-minibuffer f) 0)
          (let ([lines (+ 1 (if text (newlines text) 0))])
            (unless (= lines (frame-echo-lines f))
              (frame-echo-lines-set! f lines)
              (%relayout! f))))))))

  (define sink-installed (begin (%set-message-sink! show-echo!) #t))

  ;; ---- display features: global minor modes applied to every window ----
  ;; Option numbers are pf_window_option (core/display/pf_window.h).

  ;; As in Emacs, the hl-line band and bracket highlights follow the selected window (all
  ;; windows with global-hl-line-sticky-flag); line numbers show everywhere.
  (defvar global-hl-line-sticky-flag #f
    "Highlight the current line in every window, not only the selected one.")

  (defvar display-line-numbers #t
    "Whether windows showing this buffer have line numbers (when display-line-numbers-mode is on)."
    '(local))

  (defvar truncate-lines #t
    "Cut lines at the window edge instead of continuing them on the next row (Emacs's default is
#f; here text buffers opt in to wrapping, with visual-line-mode)."
    '(local))

  (defvar word-wrap #f
    "Continue lines at whitespace instead of mid-word, when lines are not truncated."
    '(local))

  (define (wrap-mode-of w)
    (with-current-buffer (window-buffer w)
      (cond [(minor-mode-enabled? 'visual-line-mode) 2]
            [(var-ref 'truncate-lines) 0]
            [(var-ref 'word-wrap) 2]
            [else 1])))

  (define display-modes
    '((display-line-numbers-mode . 1) (global-hl-line-mode . 2) (show-paren-mode . 3)))

  (define (apply-display-options! w)
    (for-each (lambda (m)
                (let ([everywhere (case (car m)
                                    [(display-line-numbers-mode) #t]
                                    [(global-hl-line-mode) (var-ref 'global-hl-line-sticky-flag)]
                                    [else #f])])
                  (%win-set-option (window-handle w) (cdr m)
                                   (if (and (minor-mode-enabled? (car m))
                                            (or everywhere (selected? w))
                                            (or (not (eq? (car m) 'display-line-numbers-mode))
                                                (with-current-buffer (window-buffer w)
                                                  (var-ref 'display-line-numbers))))
                                       1
                                       0))))
              display-modes)
    (%win-set-option (window-handle w) wrap-option (if (window-minibuffer? w) 0 (wrap-mode-of w))))

  (defvar animate-cursor #f
    "Glide the cursor to where point jumped (rows, far columns) instead of moving it at once. Needs
ui-motion subtle or full, and macOS Reduce Motion off.")

  (defvar animate-scroll #f
    "Glide the text when a window scrolls (C-v, M-v, point leaving the window) instead of jumping.
Edits and long jumps still scroll at once. Needs ui-motion subtle or full, and macOS Reduce Motion off.")

  ;; ui-motion: off (or #f), subtle, full (pf_anim.h). macOS Reduce Motion overrides it in C.
  (define (apply-motion! v)
    (%motion-set-level (case v [(full) 2] [(subtle) 1] [else 0])))

  (define (apply-options!)
    (for-each (lambda (f) (for-each apply-display-options! (frame-windows f)))
              (vector->list (hashtable-values frames))))

  (define-minor-mode display-line-numbers-mode (global)
    "Show line numbers in a gutter."
    (apply-options!))

  (define-minor-mode global-hl-line-mode (global)
    "Highlight the line point is on."
    (apply-options!))

  (define-minor-mode visual-line-mode ()
    "Continue long lines on the next screen row, at word boundaries; C-n, C-p, C-a and C-e move by
screen rows."
    (apply-options!))

  (define-minor-mode show-paren-mode (global)
    "Highlight the bracket matching the one at point, without delay."
    (apply-options!))

  ;; ---- mode lines ----
  ;; mode-line-format is a list of elements: a string; a symbol naming a segment (a procedure
  ;; of the window, see define-mode-line-segment) or else a variable; (:face FACE ELT ...);
  ;; a procedure of the window; or a list of elements. Formatting runs in the window's buffer.

  (defvar mode-line-format
    '(" " mode-line-modified "  " mode-line-buffer-identification "   "
      mode-line-position "   " mode-line-modes)
    "What mode lines show; #f for none. Buffer-local when set."
    '(local))

  (defvar header-line-format #f
    "What the header line (above the text of a window) shows, in the format of mode-line-format;
#f for none. Buffer-local when set."
    '(local))

  (define segments (make-eq-hashtable))

  (define (register-mode-line-segment! name proc) (hashtable-set! segments name proc) name)

  (define-syntax define-mode-line-segment
    (syntax-rules ()
      [(_ (name w) body ...)
       (define registered (register-mode-line-segment! 'name (lambda (w) body ...)))]))

  ;; The mode line of W as a string and face runs ((start end face-name) ...).
  (define (format-mode-line w) (format-line w 'mode-line-format))

  ;; The text and face runs of the format in variable FORMAT-VAR (mode-line-format or
  ;; header-line-format) for window W.
  (define (format-line w format-var)
    (let ([out '()] [len 0] [runs '()])
      (define (emit! s face)
        (let ([n (string-length s)])
          (when (> n 0)
            (set! out (cons s out))
            (when face (set! runs (cons (list len (+ len n) face) runs)))
            (set! len (+ len n)))))
      (define (walk elt face depth)
        (when (> depth 32) (error 'format-mode-line "line format nests too deeply"))
        (cond
          [(string? elt) (emit! elt face)]
          [(number? elt) (emit! (number->string elt) face)]
          [(or (not elt) (null? elt)) (void)]
          [(symbol? elt)
           (cond [(hashtable-ref segments elt #f) => (lambda (p) (walk (p w) face (+ depth 1)))]
                 [(variable-defined? elt) (walk (var-ref elt) face (+ depth 1))])]
          [(procedure? elt) (walk (elt w) face (+ depth 1))]
          [(and (pair? elt) (eq? (car elt) ':face) (pair? (cdr elt)))
           (for-each (lambda (e) (walk e (cadr elt) (+ depth 1))) (cddr elt))]
          [(list? elt) (for-each (lambda (e) (walk e face (+ depth 1))) elt)]
          [else (emit! (format "~a" elt) face)]))
      (with-current-buffer (window-buffer w)
        (guard (c [else (set! out '()) (set! len 0) (set! runs '())
                        (emit! (call-with-string-output-port
                                (lambda (p) (display "line format: " p)
                                  (if (condition? c) (display-condition c p) (write c p))))
                               'error)])
          (walk (var-ref format-var) #f 0)))
      (values (apply string-append (reverse out)) (reverse runs))))

  (define-mode-line-segment (mode-line-window-label w)
    (and (window-label w) `(:face mode-line-highlight ,(format "[~a]" (window-label w)) " ")))

  (define-mode-line-segment (mode-line-modified w)
    (cond [(and (buffer-read-only?) (buffer-modified?)) "%*"]
          [(buffer-read-only?) "%%"]
          [(buffer-modified?) "**"]
          [else "--"]))

  (define-mode-line-segment (mode-line-buffer-identification w)
    `(:face mode-line-buffer-id ,(buffer-name (window-buffer w))))

  ;; All / Top / Bot / NN% of the buffer above the window, then (line,column) of its point.
  (define-mode-line-segment (mode-line-position w)
    (let* ([h (%buffer-handle (window-buffer w))]
           [total (%buf-lines h)]
           [top (window-start-line w)]
           [bottom (+ top (window-body-lines w))]
           [pt (window-point w)]
           [line (%buf-line-of h pt)])
      (format "~a  (~a,~a)"
              (cond [(and (<= top 0) (>= bottom total)) "All"]
                    [(<= top 0) "Top"]
                    [(>= bottom total) "Bot"]
                    [else (format "~a%" (quotient (* 100 top) total))])
              (+ line 1) (- pt (%buf-line-start h line)))))

  (define-mode-line-segment (mode-line-modes w)
    (let ([lighters (filter string? (map mode-lighter (enabled-minor-modes)))])
      (apply string-append "(" (format "~a" (or (mode-lighter (major-mode)) (major-mode)))
             (append (map (lambda (l) (if (and (> (string-length l) 0)
                                               (char=? (string-ref l 0) #\space))
                                          l
                                          (string-append " " l)))
                          lighters)
                     '(")")))))

  (define (runs->bytevector runs)
    (let ([bv (make-bytevector (* 12 (max 1 (length runs))) 0)])
      (let loop ([rs runs] [i 0])
        (unless (null? rs)
          (bytevector-u32-native-set! bv i (car (car rs)))
          (bytevector-u32-native-set! bv (+ i 4) (cadr (car rs)))
          (bytevector-u32-native-set! bv (+ i 8) (face-id (caddr (car rs))))
          (loop (cdr rs) (+ i 12))))
      bv))

  (define (update-mode-line! w)
    (let ([fmt (with-current-buffer (window-buffer w) (var-ref 'mode-line-format))])
      (let-values ([(text runs) (if fmt (format-mode-line w) (values "" '()))])
        (let* ([face (and fmt (if (selected? w) 'mode-line 'mode-line-inactive))]
               [box (and fmt (mode-line-box?))]
               [key (list text runs face box)])
          (unless (equal? key (window-mode-line w))
            (window-mode-line-set! w key)
            (let ([bv (string->utf8 text)])
              (%win-set-mode-line (window-handle w) bv (bytevector-length bv)
                                  (runs->bytevector runs) (length runs)
                                  (if face (face-id face) 0) box)))))))

  ;; The header line: header-line-format (buffer-local, #f for none) in the same format as the
  ;; mode line, drawn at the top of the window in the header-line face.
  (define header-keys (make-weak-eq-hashtable)) ; window -> what it last showed

  (define (update-header-line! w)
    (let ([fmt (with-current-buffer (window-buffer w) (var-ref 'header-line-format))])
      (let-values ([(text runs) (if fmt (format-line w 'header-line-format) (values "" '()))])
        (let* ([face (and fmt 'header-line)]
               [box (and fmt (mode-line-box?))]
               [key (list text runs face box)])
          (unless (equal? key (hashtable-ref header-keys w #f))
            (hashtable-set! header-keys w key)
            (let ([bv (string->utf8 text)])
              (%win-set-header-line (window-handle w) bv (bytevector-length bv)
                                    (runs->bytevector runs) (length runs)
                                    (if face (face-id face) 0) box)))))))

  ;; The active region (transient-mark-mode, see (profane command-loop)) shows in the selected
  ;; window only, as in Emacs.
  (define (update-region! w)
    (let ([b (window-buffer w)])
      (if (and (selected? w) (buffer-live? b) (not (window-minibuffer? w))
               (variable-defined? 'mark-active)
               (with-current-buffer b (and (var-ref 'mark-active) (mark) #t)))
          (let ([m (with-current-buffer b (mark))] [p (buffer-point b)])
            (%win-set-region (window-handle w) (min m p) (max m p)))
          (%win-set-region (window-handle w) 0 0))))

  (define (update-text-scale! w)
    (let ([s (inexact (with-current-buffer (window-buffer w) (var-ref 'text-scale-factor)))])
      (unless (= s (window-scale w))
        (window-scale-set! w s)
        (%frm-set-text-scale (frame-handle (window-frame w)) (window-handle w) s))))

  ;; ---- redisplay ----

  (define (redisplay-prepare!)
    (let ([f (selected-frame)])
      (when f
        (unless (and (= (frame-width f) (car (frame-size f)))
                     (= (frame-height f) (cdr (frame-size f))))
          (%relayout! f))
        (for-each (lambda (w)
                    (unless (buffer-live? (window-buffer w))
                      (set-window-buffer! w (other-buffer (window-buffer w)))))
                  (window-list f))
        (unless (or mini-active (buffer-live? (window-buffer (frame-minibuffer f))))
          (attach-buffer! (frame-minibuffer f) (echo-buffer)))
        (run-hooks 'pre-redisplay-hook f)
        (for-each (lambda (w) (update-mode-line! w) (update-header-line! w) (update-text-scale! w)
                    (update-region! w))
                  (window-list f)))))

  ;; Fringes, mode line style and line spacing change the layout. (The calls make sure the
  ;; libraries defining them have run: Chez runs a library only once it is used.)
  (define layout-watchers
    (begin
      (current-ui-style)
      (face-id 'mode-line)
      (for-each (lambda (v)
                  (add-var-watcher!
                   v (lambda (name value where)
                       (for-each %relayout! (vector->list (hashtable-values frames))))))
                '(ui-fringe-width ui-mode-line-style line-spacing))
      (add-var-watcher! 'global-hl-line-sticky-flag (lambda (name value where) (apply-options!)))
      (add-var-watcher! 'ui-motion (lambda (name value where) (apply-motion! value)))
      (apply-motion! (var-ref 'ui-motion))
      (add-var-watcher! 'animate-cursor (lambda (name value where) (%motion-set-cursor (if value 1 0))))
      (%motion-set-cursor (if (var-ref 'animate-cursor) 1 0))
      (add-var-watcher! 'animate-scroll (lambda (name value where) (%motion-set-scroll (if value 1 0))))
      (%motion-set-scroll (if (var-ref 'animate-scroll) 1 0))
      (add-var-watcher! 'truncate-lines (lambda (name value where) (apply-options!)))
      (add-var-watcher! 'word-wrap (lambda (name value where) (apply-options!)))
      #t))

  ;; ---- commands ----

  (define (n) (prefix-numeric-value))

  (define-command (split-window-below) "Split the selected window into two, one above the other."
    (split-window (selected-window) 'below))
  (define-command (split-window-right) "Split the selected window into two side by side."
    (split-window (selected-window) 'right))
  (define-command (delete-window) "Delete the selected window." (delete-window))
  (define-command (delete-other-windows) "Make the selected window fill its frame."
    (delete-other-windows))
  (define-command (other-window) "Select the ARGth window after the selected one, cyclically."
    (select-window (next-window (selected-window) (n))))
  (define-command (balance-windows) "Make windows the same size." (balance-windows))

  ;; Emacs scroll-left / scroll-right: by ARG columns, or the window's width less two.
  (define (hscroll-amount w)
    (if (current-prefix-arg)
        (prefix-numeric-value)
        (max 1 (- (exact (floor (/ (caddr (window-edges w)) (cell-width (window-frame w))))) 2))))
  (define-command (scroll-left) "Scroll the selected window's text left (see further right)."
    (let ([w (selected-window)])
      (set-window-hscroll! w (+ (window-hscroll w) (hscroll-amount w)))))
  (define-command (scroll-right) "Scroll the selected window's text right (back toward the start)."
    (let ([w (selected-window)])
      (set-window-hscroll! w (- (window-hscroll w) (hscroll-amount w)))))
  (define-command (enlarge-window) "Make the selected window ARG lines taller."
    (resize-window! (selected-window) (* (n) (line-height (selected-frame))) 'below))
  (define-command (shrink-window) "Make the selected window ARG lines shorter."
    (resize-window! (selected-window) (- (* (n) (line-height (selected-frame)))) 'below))
  (define-command (enlarge-window-horizontally) "Make the selected window ARG columns wider."
    (resize-window! (selected-window) (* (n) (cell-width (selected-frame))) 'right))
  (define-command (shrink-window-horizontally) "Make the selected window ARG columns narrower."
    (resize-window! (selected-window) (- (* (n) (cell-width (selected-frame)))) 'right))

  (define window-bindings
    (begin
      (for-each (lambda (b) (define-key! (global-map) (car b) (cdr b)))
                '(("C-x 2" . split-window-below) ("C-x 3" . split-window-right)
                  ("C-x 0" . delete-window) ("C-x 1" . delete-other-windows)
                  ("C-x o" . other-window) ("C-x +" . balance-windows)
                  ("C-x ^" . enlarge-window) ("C-x }" . enlarge-window-horizontally)
                  ("C-x {" . shrink-window-horizontally)
                  ("C-x <" . scroll-left) ("C-x >" . scroll-right)
                  ("C-x <left>" . previous-buffer) ("C-x <right>" . next-buffer)
                  ("C-x C-<left>" . previous-buffer) ("C-x C-<right>" . next-buffer)
                  ("C-v" . scroll-up-command) ("M-v" . scroll-down-command)
                  ("<next>" . scroll-up-command) ("<prior>" . scroll-down-command)
                  ("C-l" . recenter-top-bottom)))
      #t)))
