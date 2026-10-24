;;; (profane transpose-frame) — rearranging a frame's windows, after the transpose-frame
;;; package. Unstable API (plan §10).
;;;
;;; Each command rewrites the window tree's splits in place; windows keep their buffers and
;;; points.

(library (profane transpose-frame)
  (export transpose-frame flip-frame flop-frame rotate-frame rotate-frame-clockwise
          rotate-frame-anticlockwise)
  (import (chezscheme) (profane window) (profane command))

  (define (rewrite! proc)
    (let ([f (or (selected-frame) (error 'transpose-frame "no frame"))])
      (let walk ([n (frame-root f)])
        (when (split? n)
          (proc n)
          (for-each walk (split-children n))))
      (%relayout! f)))

  (define (reverse-if! direction)
    (lambda (s)
      (when (eq? (split-direction s) direction)
        (%split-children-set! s (reverse (split-children s)))
        (%split-weights-set! s (reverse (split-weights s))))))

  ;; Swaps rows and columns (a mirror over the top-left to bottom-right diagonal).
  (define (transpose-frame)
    (rewrite! (lambda (s)
                (%split-direction-set! s (if (eq? (split-direction s) 'below) 'right 'below)))))
  ;; Top to bottom.
  (define (flip-frame) (rewrite! (reverse-if! 'below)))
  ;; Left to right.
  (define (flop-frame) (rewrite! (reverse-if! 'right)))
  (define (rotate-frame) (flip-frame) (flop-frame))
  (define (rotate-frame-clockwise) (transpose-frame) (flop-frame))
  (define (rotate-frame-anticlockwise) (transpose-frame) (flip-frame))

  (define-command (transpose-frame) "Swap the frame's rows and columns of windows."
    (transpose-frame))
  (define-command (flip-frame) "Flip the frame's windows top to bottom." (flip-frame))
  (define-command (flop-frame) "Flip the frame's windows left to right." (flop-frame))
  (define-command (rotate-frame) "Rotate the frame's windows by 180 degrees." (rotate-frame))
  (define-command (rotate-frame-clockwise) "Rotate the frame's windows by 90 degrees clockwise."
    (rotate-frame-clockwise))
  (define-command (rotate-frame-anticlockwise)
    "Rotate the frame's windows by 90 degrees anticlockwise." (rotate-frame-anticlockwise)))
