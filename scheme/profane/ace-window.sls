;;; (profane ace-window) — picking a window by label, after the ace-window package. Unstable
;;; API (plan §10).
;;;
;;; With two windows ace-window just switches; with more, every window shows a digit badge
;;; and the next key picks one. With C-u the picked window swaps buffers with the
;;; selected one, with C-u C-u it is deleted. The labels are badges: pop-up canvases on the
;;; overlay layer, centered on their windows (the mode-line-window-label segment is still
;;; there for mode lines that want it).

(library (profane ace-window)
  (export ace-window)
  (import (chezscheme) (profane buffer) (profane window) (profane command)
          (profane command-loop) (profane keymap) (profane canvas))

  (define action 'select) ; for the pending pick: select, swap or delete

  (define badges '()) ; canvases showing the labels

  (define (clear-labels!)
    (for-each delete-canvas! badges)
    (set! badges '())
    (for-each (lambda (w) (set-window-label! w #f)) (window-list)))

  ;; A badge with LABEL centered on window W.
  (define badge-size 44)

  (define (show-badge! w label)
    (let* ([c (make-canvas badge-size badge-size)]
           [text (number->string label)]
           [m (draw-popup-background! c badge-size badge-size)])
      (let-values ([(tw th) (text-extent text)])
        (draw-text! c (/ (- badge-size tw) 2) (/ (- badge-size th) 2) text))
      (let ([e (window-edges w)])
        (show-popup! c (- (+ (car e) (/ (caddr e) 2)) (/ badge-size 2))
                     (- (+ (cadr e) (/ (cadddr e) 2)) (/ badge-size 2))))
      (set! badges (cons c badges))))

  (define (pick! w)
    (case action
      [(select) (select-window w)]
      [(delete) (delete-window w)]
      [(swap)
       (let* ([me (selected-window)] [mine (window-buffer me)] [theirs (window-buffer w)]
              [my-point (window-point me)] [their-point (window-point w)])
         (set-window-buffer! me theirs)
         (set-window-buffer! w mine)
         (set-window-point! me their-point)
         (set-window-point! w my-point)
         (select-window w))]))

  (define (ace-window)
    (let ([ws (window-list)])
      (cond
        [(< (length ws) 2) (void)]
        [(and (= (length ws) 2) (eq? action 'select)) (pick! (next-window (selected-window) 1))]
        [else
         (let ([m (make-keymap #f 'ace-window)])
           (let loop ([ws ws] [i 1])
             (unless (or (null? ws) (> i 9))
               (set-window-label! (car ws) i)
               (show-badge! (car ws) i)
               (define-key! m (number->string i) (string->symbol (format "ace-window-~a" i)))
               (loop (cdr ws) (+ i 1))))
           (set-transient-map m clear-labels!))])))

  (define-command (ace-window)
    "Select a window by its label; with C-u swap buffers with it, with C-u C-u delete it."
    (set! action (let ([arg (current-prefix-arg)])
                   (cond [(equal? arg '(4)) 'swap] [(equal? arg '(16)) 'delete] [else 'select])))
    (ace-window))

  ;; The keys of the transient map: ace-window-1 ... ace-window-9.
  (define registered
    (for-each (lambda (i)
                (register-command!
                 (string->symbol (format "ace-window-~a" i))
                 (lambda ()
                   (let ([ws (window-list)])
                     (when (<= i (length ws)) (pick! (list-ref ws (- i 1))))))
                 "Pick the window with this label (ace-window)."))
              '(1 2 3 4 5 6 7 8 9))))
