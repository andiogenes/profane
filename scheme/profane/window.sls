;;; (profane window) — what the shell's windows show. Unstable API (plan §10).
;;; M1 has one window per frame; splitting, window-point and the rest arrive with M2.

(library (profane window)
  (export window? selected-window window-buffer set-window-buffer!
          window-start-line window-body-lines)
  (import (chezscheme) (profane native) (profane buffer) (profane mode))

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

  ;; ---- display features: global minor modes (Emacs display-line-numbers-mode, ...) ----
  ;; Option numbers are pf_window_option (core/display/pf_window.h). M2's window tree applies
  ;; them to every window; for now the selected one.

  (define (apply-option option on?)
    (let ([w (selected-window)])
      (when w (%win-set-option (window-handle w) option on?))))

  (define-minor-mode display-line-numbers-mode (global)
    "Show line numbers in a gutter."
    (apply-option 1 (minor-mode-enabled? 'display-line-numbers-mode)))

  (define-minor-mode global-hl-line-mode (global)
    "Highlight the line point is on."
    (apply-option 2 (minor-mode-enabled? 'global-hl-line-mode)))

  (define-minor-mode show-paren-mode (global)
    "Highlight the bracket matching the one at point, without delay."
    (apply-option 3 (minor-mode-enabled? 'show-paren-mode)))

  (define (window-start-line w) (%win-top-line (window-handle w)))
  (define (window-body-lines w) (%win-body-lines (window-handle w))))
