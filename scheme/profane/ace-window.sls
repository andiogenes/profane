;;; (profane ace-window) — picking a window by label, after the ace-window package. Unstable
;;; API (plan §10).
;;;
;;; With two windows ace-window just switches; with more, every window shows a digit in its
;;; mode line and the next key picks one. With C-u the picked window swaps buffers with the
;;; selected one, with C-u C-u it is deleted. Labels drawn over the windows themselves come
;;; with (profane canvas) (M2 item 6); the mode-line label is the seam.

(library (profane ace-window)
  (export ace-window)
  (import (chezscheme) (profane buffer) (profane window) (profane command)
          (profane command-loop) (profane keymap))

  (define action 'select) ; for the pending pick: select, swap or delete

  (define (clear-labels!)
    (for-each (lambda (w) (set-window-label! w #f)) (window-list)))

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
