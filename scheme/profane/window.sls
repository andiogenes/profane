;;; (profane window) — what the shell's windows show. Unstable API (plan §10).
;;; M1 has one window per frame; splitting, window-point and the rest arrive with M2.

(library (profane window)
  (export window? selected-window window-buffer set-window-buffer!
          window-start-line window-body-lines
          display-line-numbers-mode global-hl-line-mode show-paren-mode)
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

  ;; ---- display features ----
  ;; Emacs-style mode switches: no argument turns the mode on, #f turns it off; returns the new
  ;; state. M1 applies them to the selected window; M2 makes them real global modes/variables.
  ;; Option numbers are pf_window_option (core/display/pf_window.h).

  (define (window-feature option)
    (case-lambda
      [() ((window-feature option) #t)]
      [(on?)
       (let ([w (selected-window)])
         (when w (%win-set-option (window-handle w) option (and on? #t)))
         (and on? #t))]))

  (define display-line-numbers-mode (window-feature 1))
  (define global-hl-line-mode (window-feature 2))
  (define show-paren-mode (window-feature 3))

  (define (window-start-line w) (%win-top-line (window-handle w)))
  (define (window-body-lines w) (%win-body-lines (window-handle w))))
