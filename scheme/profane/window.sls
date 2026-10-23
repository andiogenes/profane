;;; (profane window) — what the shell's windows show. Unstable API (plan §10).
;;; M1 has one window per frame; splitting, window-point and the rest arrive with M2.

(library (profane window)
  (export window? selected-window window-buffer set-window-buffer!
          window-start-line window-body-lines)
  (import (chezscheme) (profane native) (profane buffer))

  (define-record-type (window %make-window window?)
    (fields handle (mutable buffer))
    (nongenerative profane-window))

  (define windows (make-eqv-hashtable)) ; handle -> window

  ;; The selected window, or #f when there is none (headless, tests).
  (define (selected-window)
    (let ([h (%win-selected)])
      (and (not (zero? h))
           (or (hashtable-ref windows h #f)
               (let ([w (%make-window h #f)])
                 (hashtable-set! windows h w)
                 w)))))

  (define (set-window-buffer! w b)
    (let ([b (get-buffer b)])
      (unless (and b (buffer-live? b)) (error 'set-window-buffer! "no such live buffer" b))
      (unless (zero? (%win-set-buffer (window-handle w) (%buffer-handle b)
                                      (%buffer-point-marker b)))
        (error 'set-window-buffer! "window is gone" w))
      (window-buffer-set! w b)
      b))

  (define (window-start-line w) (%win-top-line (window-handle w)))
  (define (window-body-lines w) (%win-body-lines (window-handle w))))
