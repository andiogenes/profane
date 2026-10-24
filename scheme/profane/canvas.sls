;;; (profane canvas) — the low-level drawing API: retained canvases shown as pop-up surfaces on
;;; the overlay layer, with hit regions. Unstable API (plan §5.1, §10).
;;;
;;;   (define-canvas (cpu-meter c w h)
;;;     (fill-rounded-rect! c 0 0 w h 6 'bg-mode-line)
;;;     (draw-text! c 8 2 (format "~a%" (cpu-load)) 'mode-line))
;;;   (on-click! cpu-meter (lambda (x y) (open-activity-monitor)))
;;;   (show-popup! cpu-meter 20 20)
;;;
;;; Draw ops append to the canvas's display list in order: rect, rounded rect (filled or
;;; outlined), shadow, line (horizontal or vertical for now), text. Colors are "#rrggbb[aa]"
;;; strings, 0xRRGGBBAA integers or theme palette roles (symbols); a canvas drawn by
;;; define-canvas redraws, before the next frame, whenever it was invalidated (invalidate!).
;;; Coordinates are points from the canvas's top-left; pop-ups are placed in frame
;;; coordinates. Hit regions answer canvas-click! with the handler of the topmost region.
;;;
;;; Canvas windows: (set-window-canvas! w canvas) makes the body of window W (all but its mode
;;; line) a drawing surface on the base layer, in place of text; the canvas is sized to the
;;; body before each frame (a define-canvas redraws when that changes). The window keeps its
;;; buffer for its mode line and its place in the window tree.
;;;
;;; Not yet (plan §5.1): paths and bezier curves, images, clip and transform (ops are not
;;; clipped to a canvas window's body, so draw inside w x h), inline canvases, and mouse
;;; events: they reach canvas-click! once the shell routes the mouse.

(library (profane canvas)
  (export make-canvas delete-canvas! canvas? canvas-width canvas-height set-canvas-size!
          clear-canvas! define-canvas redraw! invalidate! on-click!
          fill-rect! fill-rounded-rect! stroke-rounded-rect! draw-shadow! draw-line! draw-text!
          add-hit-region! text-extent
          show-popup! hide-popup! popup-shown? draw-popup-background!
          set-window-canvas! window-canvas
          canvas-click! canvas-at)
  (import (chezscheme) (profane native) (profane window) (profane theme) (profane display)
          (profane var) (profane hook))

  (define-record-type (canvas %make-canvas canvas?)
    (fields handle
            (mutable draw)     ; (lambda (canvas w h)) or #f
            (mutable dirty?)
            (mutable click)    ; whole-canvas handler or #f
            (mutable regions)  ; alist id -> (handler . cursor)
            (mutable next-region)
            (mutable origin))  ; (x . y) of its pop-up, or #f
    (nongenerative profane-canvas))

  (define (fl x) (inexact x))

  (define live (make-eqv-hashtable)) ; handle -> canvas, for hit dispatch

  (define (make-canvas w h)
    (let ([h* (%cvs-new (fl w) (fl h))])
      (when (zero? h*) (error 'make-canvas "could not create a canvas"))
      (let ([c (%make-canvas h* #f #f #f '() 1 #f)])
        (hashtable-set! live h* c)
        c)))

  (define (frame-handle)
    (let ([f (selected-frame)])
      (unless f (error 'show-popup! "there is no frame"))
      (%frame-handle f)))

  (define window-canvases (make-weak-eq-hashtable)) ; window -> canvas

  (define (delete-canvas! c)
    (hide-popup! c)
    (let-values ([(ws cs) (hashtable-entries window-canvases)])
      (vector-for-each (lambda (w k) (when (eq? k c) (set-window-canvas! w #f))) ws cs))
    (hashtable-delete! live (canvas-handle c))
    (%cvs-free (canvas-handle c))
    (void))

  (define (canvas-width c) (inexact->exact (round (%cvs-width (canvas-handle c)))))
  (define (canvas-height c) (inexact->exact (round (%cvs-height (canvas-handle c)))))
  (define (set-canvas-size! c w h) (%cvs-set-size (canvas-handle c) (fl w) (fl h)))

  ;; ---- colors ----

  (define (->rgba c)
    (cond [(integer? c) c]
          [(string? c) (color->rgba c)]
          [(symbol? c) (color->rgba (theme-color c))]
          [else (error 'canvas "not a color" c)]))

  ;; ---- drawing ----

  (define (fill-rect! c x y w h color)
    (%cvs-fill-rect (canvas-handle c) (fl x) (fl y) (fl w) (fl h) (->rgba color)) (void))
  (define (fill-rounded-rect! c x y w h r color)
    (%cvs-fill-round-rect (canvas-handle c) (fl x) (fl y) (fl w) (fl h) (fl r) (->rgba color)) (void))
  (define stroke-rounded-rect!
    (case-lambda
      [(c x y w h r color) (stroke-rounded-rect! c x y w h r 1 color)]
      [(c x y w h r line color)
       (%cvs-stroke-round-rect (canvas-handle c) (fl x) (fl y) (fl w) (fl h) (fl r) (fl line)
                               (->rgba color)) (void)]))
  (define (draw-shadow! c x y w h r blur color)
    (%cvs-shadow (canvas-handle c) (fl x) (fl y) (fl w) (fl h) (fl r) (fl blur) (->rgba color)) (void))
  (define (draw-line! c x0 y0 x1 y1 line color)
    (%cvs-line (canvas-handle c) (fl x0) (fl y0) (fl x1) (fl y1) (fl line) (->rgba color)) (void))

  ;; FACE (default: the default face) gives font and foreground; COLOR overrides the latter.
  (define draw-text!
    (case-lambda
      [(c x y str) (draw-text! c x y str 'default #f)]
      [(c x y str face) (draw-text! c x y str face #f)]
      [(c x y str face color)
       (let ([bv (string->utf8 str)])
         (%cvs-text (canvas-handle c) (fl x) (fl y) bv (bytevector-length bv) (face-id face)
                    (if color (->rgba color) 0))
         (void))]))

  ;; Width and height of STR in FACE, in points.
  (define text-extent
    (case-lambda
      [(str) (text-extent str 'default)]
      [(str face)
       (let ([bv (string->utf8 str)] [f (frame-handle)])
         (values (%cvs-text-width f bv (bytevector-length bv) (face-id face))
                 (%cvs-text-height f (face-id face))))]))

  ;; ---- hit regions and clicks ----

  (define cursor-shapes '((arrow . 0) (pointer . 1) (text . 2)))

  (define add-hit-region!
    (case-lambda
      [(c x y w h handler) (add-hit-region! c x y w h handler 'arrow)]
      [(c x y w h handler cursor)
       (let ([id (canvas-next-region c)])
         (canvas-next-region-set! c (+ id 1))
         (canvas-regions-set! c (cons (cons id (cons handler cursor)) (canvas-regions c)))
         (%cvs-add-hit (canvas-handle c) (fl x) (fl y) (fl w) (fl h) id (cdr (assq cursor cursor-shapes)))
         id)]))

  ;; A handler for clicks anywhere on C that no more specific region takes.
  (define (on-click! c handler)
    (canvas-click-set! c handler)
    (invalidate! c))

  (define (add-whole-canvas-region! c)
    (when (canvas-click c)
      (%cvs-add-hit (canvas-handle c) 0.0 0.0 (%cvs-width (canvas-handle c))
                    (%cvs-height (canvas-handle c)) 0 1)))

  ;; Drops everything drawn and every hit region.
  (define (clear-canvas! c)
    (%cvs-clear (canvas-handle c))
    (canvas-regions-set! c '())
    (canvas-next-region-set! c 1)
    (add-whole-canvas-region! c))

  ;; The canvas shown at frame point (X, Y), or #f.
  (define (canvas-at x y)
    (and (>= (%cvs-frame-hit (frame-handle) (fl x) (fl y)) 0)
         (hashtable-ref live (%cvs-hit-canvas) #f)))

  ;; Calls the handler of the topmost region (of a pop-up, else of a canvas window) at frame
  ;; point (X, Y) with the point in the canvas's coordinates; returns #t if there was one.
  (define (canvas-click! x y)
    (let ([id (%cvs-frame-hit (frame-handle) (fl x) (fl y))])
      (and (>= id 0)
           (let* ([c (hashtable-ref live (%cvs-hit-canvas) #f)]
                  [h (and c (if (zero? id) (canvas-click c) (let ([r (assv id (canvas-regions c))]) (and r (cadr r)))))]
                  [lx (%cvs-hit-x)] [ly (%cvs-hit-y)])
             (and h (begin (h lx ly) #t))))))

  ;; ---- retained drawing ----

  (define (redraw! c)
    (canvas-dirty?-set! c #f)
    (clear-canvas! c)
    (let ([draw (canvas-draw c)])
      (when draw (draw c (canvas-width c) (canvas-height c)))))

  (define (invalidate! c) (canvas-dirty?-set! c #t))

  (define-syntax define-canvas
    (syntax-rules ()
      [(_ (name c w h) body ...)
       (define name (let ([canvas (make-canvas 100 24)])
                      (canvas-draw-set! canvas (lambda (c w h) body ... (void)))
                      (invalidate! canvas)
                      canvas))]))

  ;; Redraws before each frame the canvases that were invalidated.
  (define (redraw-dirty!)
    (let ([dirty '()])
      (hashtable-walk* (lambda (c) (when (canvas-dirty? c) (set! dirty (cons c dirty)))))
      (for-each redraw! dirty)))

  (define (hashtable-walk* proc)
    (let-values ([(keys vals) (hashtable-entries live)])
      (vector-for-each proc vals)))

  (define (register-canvas-drawer!) (add-hook! 'pre-redisplay-hook (lambda (f) (fit-canvas-windows!) (redraw-dirty!))))
  (define installed (begin (register-canvas-drawer!) #t))

  ;; ---- canvas windows ----

  (define (window-canvas w) (hashtable-ref window-canvases w #f))

  ;; CANVAS #f makes W a text window again.
  (define (set-window-canvas! w canvas)
    (%cvs-set-window (%frame-handle (window-frame w)) (%window-handle w)
                     (if canvas (canvas-handle canvas) 0))
    (if canvas (hashtable-set! window-canvases w canvas) (hashtable-delete! window-canvases w))
    (when canvas (fit-to-window! w canvas))
    (void))

  (define (fit-to-window! w c)
    (let ([bw (%cvs-window-body (%window-handle w) 2)] [bh (%cvs-window-body (%window-handle w) 3)])
      (unless (and (= bw (%cvs-width (canvas-handle c))) (= bh (%cvs-height (canvas-handle c))))
        (set-canvas-size! c bw bh)
        (if (canvas-draw c) (invalidate! c) (void)))))

  (define (fit-canvas-windows!)
    (let-values ([(ws cs) (hashtable-entries window-canvases)])
      (vector-for-each (lambda (w c) (when (window-live? w) (fit-to-window! w c))) ws cs)))

  ;; ---- pop-up surfaces ----

  (define (show-popup! c x y)
    (redraw-if-dirty! c)
    (canvas-origin-set! c (cons x y))
    (%cvs-popup-show (frame-handle) (canvas-handle c) (fl x) (fl y))
    (void))

  (define (redraw-if-dirty! c) (when (canvas-dirty? c) (redraw! c)))

  (define (hide-popup! c)
    (when (selected-frame) (%cvs-popup-hide (frame-handle) (canvas-handle c)))
    (canvas-origin-set! c #f)
    (void))

  (define (popup-shown? c) (and (canvas-origin c) #t))

  ;; The surface of a pop-up: the theme's background with its border, corner radius and, when
  ;; ui-popup-shadow is on, the elevation shadow (token LEVEL, 1 to 3). The shadow is drawn
  ;; inside the canvas, so leave its blur as margin (the returned value) around the box.
  (define draw-popup-background!
    (case-lambda
      [(c w h) (draw-popup-background! c w h 2)]
      [(c w h level)
       (let* ([r (or (theme-token 'radius 'm) 6)]
              [e (theme-token 'elevation level)]
              [blur (if (and e (var-ref 'ui-popup-shadow)) (cdr (assq 'blur e)) 0)]
              [m (inexact->exact (ceiling blur))])
         (when (> m 0)
           (draw-shadow! c m (+ m (cdr (assq 'y e))) (- w (* 2 m)) (- h (* 2 m)) r blur
                         (inexact->exact (round (* 255 (cdr (assq 'alpha e)))))))
         (fill-rounded-rect! c m m (- w (* 2 m)) (- h (* 2 m)) r 'bg)
         (stroke-rounded-rect! c m m (- w (* 2 m)) (- h (* 2 m)) r 1 'border)
         m)])))
