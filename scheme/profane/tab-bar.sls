;;; (profane tab-bar) — tabs: named window layouts of a frame, after Emacs's tab-bar-mode.
;;; Unstable API (plan §10).
;;;
;;; Each tab keeps its own window tree and selected window; switching tabs shows another tree
;;; (the windows of hidden tabs live on, with their points and scroll positions). The tab bar
;;; is a strip across the top of the frame, shown per tab-bar-show (by default only with more
;;; than one tab: quiet by default). A tab is named after its selected window's buffer unless
;;; renamed.

(library (profane tab-bar)
  (export tab-list current-tab-index tab-name tab-new tab-close tab-close-other tab-select
          tab-next tab-rename)
  (import (chezscheme) (profane native) (profane buffer) (profane window) (profane var)
          (profane hook) (profane command) (profane keymap) (profane display))

  (define-record-type tab
    (fields (mutable label) (mutable root) (mutable selected)) ; label: a name given by tab-rename
    (nongenerative profane-tab))

  (defvar tab-bar-show 1
    "Show the tab bar: #t always, 1 when there is more than one tab, #f never.")

  (define states (make-eq-hashtable)) ; frame -> (tabs . current index)

  (define (frame) (or (selected-frame) (error 'tab-bar "no frame")))

  (define (state f)
    (or (hashtable-ref states f #f)
        (let ([s (cons (list (make-tab #f (frame-root f) (frame-selected-window f))) 0)])
          (hashtable-set! states f s)
          s)))

  (define tab-list
    (case-lambda
      [() (tab-list (frame))]
      [(f) (car (state f))]))

  (define current-tab-index
    (case-lambda
      [() (current-tab-index (frame))]
      [(f) (cdr (state f))]))

  ;; The live layout belongs to the frame; the current tab is brought up to date before use.
  (define (save! f)
    (let ([t (list-ref (tab-list f) (current-tab-index f))])
      (tab-root-set! t (frame-root f))
      (tab-selected-set! t (frame-selected-window f))))

  (define (show! f i)
    (let ([t (list-ref (tab-list f) i)])
      (set-cdr! (state f) i)
      (%frame-set-root! f (tab-root t) (tab-selected t))))

  (define (tab-name t)
    (or (tab-label t) (buffer-name (window-buffer (tab-selected t)))))

  ;; Emacs tab-new: a tab after the current one, showing the current buffer in one window.
  (define (tab-new)
    (let* ([f (frame)] [i (current-tab-index f)]
           [w (%make-window f (window-buffer (frame-selected-window f)))])
      (save! f)
      (set-car! (state f) (let-values ([(before after) (split-at (tab-list f) (+ i 1))])
                            (append before (list (make-tab #f w w)) after)))
      (show! f (+ i 1))))

  (define (split-at xs k)
    (if (zero? k) (values '() xs)
        (let-values ([(a b) (split-at (cdr xs) (- k 1))]) (values (cons (car xs) a) b))))

  (define (remove-tab! f i)
    (set-car! (state f) (let-values ([(before after) (split-at (tab-list f) i)])
                          (append before (cdr after)))))

  ;; Emacs tab-close: deletes the current tab's windows and shows the next tab (the previous
  ;; one if it was the last).
  (define (tab-close)
    (let* ([f (frame)] [i (current-tab-index f)] [n (length (tab-list f))])
      (when (= n 1) (error 'tab-close "attempt to delete the sole tab"))
      (save! f)
      (let ([doomed (tab-root (list-ref (tab-list f) i))]
            [next (if (< (+ i 1) n) (+ i 1) (- i 1))])
        (show! f next)
        (remove-tab! f i)
        (set-cdr! (state f) (if (> next i) i next))
        (%delete-tree! doomed))))

  (define (tab-close-other)
    (let* ([f (frame)] [i (current-tab-index f)] [me (list-ref (tab-list f) i)])
      (save! f)
      (for-each (lambda (t) (unless (eq? t me) (%delete-tree! (tab-root t)))) (tab-list f))
      (set-car! (state f) (list me))
      (set-cdr! (state f) 0)))

  ;; Shows tab I (0-based).
  (define (tab-select i)
    (let ([f (frame)])
      (unless (and (>= i 0) (< i (length (tab-list f)))) (error 'tab-select "no such tab" i))
      (unless (= i (current-tab-index f))
        (save! f)
        (show! f i))))

  (define (tab-next k)
    (let ([f (frame)])
      (tab-select (mod (+ (current-tab-index f) k) (length (tab-list f))))))

  (define (tab-rename name)
    (let ([f (frame)])
      (tab-label-set! (list-ref (tab-list f) (current-tab-index f))
                     (and name (not (equal? name "")) name))))

  ;; ---- the tab bar ----

  (define shown-bars (make-eq-hashtable)) ; frame -> what was last pushed

  (define (bar-visible? f)
    (let ([show (var-ref 'tab-bar-show)])
      (cond [(eqv? show 1) (> (length (tab-list f)) 1)]
            [else (and show #t)])))

  (define (update-tab-bar! f)
    (save! f)
    (let* ([visible (bar-visible? f)]
           [names (map tab-name (tab-list f))]
           [key (and visible (cons (current-tab-index f) names))])
      (unless (equal? key (hashtable-ref shown-bars f 'none))
        (hashtable-set! shown-bars f key)
        (if (not visible)
            (begin (%frm-set-tab-bar (%frame-handle f) #vu8() 0 #vu8() 0 0 #f)
                   (%set-frame-top-margin! f 0))
            (let loop ([ns names] [i 0] [text ""] [runs '()])
              (if (null? ns)
                  (let ([bv (string->utf8 text)]
                        [rv (make-bytevector (* 12 (length runs)))])
                    (let fill ([rs (reverse runs)] [k 0])
                      (unless (null? rs)
                        (for-each (lambda (v j) (bytevector-u32-native-set! rv (+ k (* 4 j)) v))
                                  (car rs) '(0 1 2))
                        (fill (cdr rs) (+ k 12))))
                    (%frm-set-tab-bar (%frame-handle f) bv (bytevector-length bv) rv (length runs)
                                      (face-id 'tab-bar) #f)
                    (%set-frame-top-margin!
                     f (%frm-strip-height (%frame-handle f) (face-id 'tab-bar) #f)))
                  (let* ([label (format " ~a " (car ns))]
                         [start (string-length text)]
                         [face (if (= i (current-tab-index f)) 'tab-bar-tab 'tab-bar-tab-inactive)])
                    (loop (cdr ns) (+ i 1) (string-append text label " ")
                          (cons (list start (+ start (string-length label)) (face-id face))
                                runs)))))))))

  ;; ---- commands ----

  (define-command (tab-new) "Open a new tab showing the current buffer." (tab-new))
  (define-command (tab-close) "Close the current tab." (tab-close))
  (define-command (tab-close-other) "Close every tab but the current one." (tab-close-other))
  (define-command (tab-next) "Switch to the ARGth next tab." (tab-next (prefix-numeric-value)))
  (define-command (tab-previous) "Switch to the ARGth previous tab."
    (tab-next (- (prefix-numeric-value))))

  (define registered
    (begin
      (add-hook! 'pre-redisplay-hook update-tab-bar!)
      (for-each (lambda (b) (define-key! (global-map) (car b) (cdr b)))
                '(("C-x t 2" . tab-new) ("C-x t 0" . tab-close) ("C-x t 1" . tab-close-other)
                  ("C-x t o" . tab-next) ("C-x t O" . tab-previous)))
      #t)))
