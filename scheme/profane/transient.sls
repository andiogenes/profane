;;; (profane transient) — transient menus, after Emacs's transient (Magit's popups). Unstable API
;;; (plan §10).
;;;
;;;   (define-transient (git-menu)
;;;     "Git"
;;;     ("Arguments"
;;;      (switch "-a" "--all" all)
;;;      (option "-m" "--message=" message))
;;;     ("Actions"
;;;      (action "c" "Commit" git-commit)
;;;      (action "l" "Log" git-log stay)))
;;;
;;; defines the command git-menu, which shows a panel of the keys above the echo area (a pop-up
;;; canvas, see (profane canvas)) and takes over the keys until one is done. Items:
;;;
;;;   (action KEY LABEL COMMAND [stay])   runs the command (a symbol, or a procedure) and closes
;;;                                       the menu, unless it says stay
;;;   (switch KEY FLAG NAME [on])         toggles; FLAG is shown, green when on
;;;   (option KEY FLAG NAME [value])      reads a string in the minibuffer (empty clears it)
;;;
;;; KEY is a key sequence as for kbd: "c", "- a" (two keys). The command runs with the switches
;;; and options as an alist in (transient-args), e.g. ((all . #t) (message . "fix")); an option
;;; that is not set is left out. C-g or ESC closes the menu; other unbound keys only complain.
;;; Menus are columns, one per group. Values start from the defaults on every opening.

(library (profane transient)
  (export define-transient register-transient! open-transient close-transient transient-open?
          transient-args transient-arg transient-names)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane keymap) (profane canvas) (profane minibuffer) (profane theme))

  (define defs (make-eq-hashtable)) ; name -> (title . groups)

  (define (register-transient! name title groups doc)
    (hashtable-set! defs name (cons title groups))
    (register-command! name (lambda () (open-transient name)) doc)
    name)

  (define-syntax define-transient
    (lambda (x)
      (syntax-case x ()
        [(_ (name) title doc group ...)
         (and (string? (syntax->datum #'title)) (string? (syntax->datum #'doc)))
         #'(define registered (register-transient! 'name title '(group ...) doc))]
        [(_ (name) title group ...)
         #'(define registered
             (register-transient! 'name title '(group ...) (string-append "Menu: " title)))])))

  (define (transient-names) (vector->list (hashtable-keys defs)))

  ;; ---- items ----

  (define (item-kind i) (car i))
  (define (item-key i) (cadr i))
  (define (item-label i) (caddr i))
  (define (item-target i) (cadddr i))   ; command (action) or value name (switch, option)
  (define (item-extra i) (let ([t (cddddr i)]) (and (pair? t) (car t))))

  (define (key-text spec) (list->string (remv #\space (string->list spec))))

  ;; ---- the open menu ----

  (define-record-type session
    (fields name title groups map values (mutable canvas))
    (nongenerative profane-transient-session))

  (define current #f)
  (define current-args (make-parameter '()))

  (define (transient-open?) (and current #t))
  (define (transient-args) (current-args))
  (define (transient-arg name . default)
    (let ([e (assq name (current-args))]) (if e (cdr e) (if (pair? default) (car default) #f))))

  (define (value name) (hashtable-ref (session-values current) name #f))
  (define (set-value! name v) (hashtable-set! (session-values current) name v))

  (define (args-now)
    (let ([out '()])
      (for-each
       (lambda (g)
         (for-each (lambda (i)
                     (when (memq (item-kind i) '(switch option))
                       (let ([v (value (item-target i))])
                         (when v (set! out (cons (cons (item-target i) v) out))))))
                   (cdr g)))
       (session-groups current))
      (reverse out)))

  (define (command-name name key)
    (string->symbol (format "transient/~a/~a" name (key-text key))))

  (define (run-target target)
    (cond [(procedure? target) (target)]
          [(command-procedure target) => (lambda (p) (p))]
          [else (error 'transient "no such command" target)]))

  (define (reopen-map!)
    (set-transient-map (session-map current) (lambda () (hide!)) #t))

  (define (make-item-command item)
    (case (item-kind item)
      [(action)
       (lambda ()
         (let ([args (args-now)] [stay? (eq? (item-extra item) 'stay)])
           (unless stay? (close-transient))
           (parameterize ([current-args args])
             (run-target (item-target item)))
           (when (and stay? current) (refresh-panel!))))]
      [(switch)
       (lambda ()
         (set-value! (item-target item) (not (value (item-target item))))
         (refresh-panel!))]
      [(option)
       (lambda ()
         (let ([s current])
           (clear-transient-map!)           ; the minibuffer takes the keys meanwhile
           (read-from-minibuffer
            (string-append (item-label item) " ")
            (lambda (text)
              (when (eq? s current)
                (set-value! (item-target item) (if (string=? text "") #f text))
                (reopen-map!)
                (refresh-panel!)))
            (or (value (item-target item)) "")
            'quit (lambda () (when (eq? s current) (reopen-map!) (refresh-panel!))))))]
      [else (error 'transient "unknown item" item)]))

  (define (build-map name groups)
    (let ([m (make-keymap #f name)])
      (for-each
       (lambda (g)
         (for-each
          (lambda (item)
            (let ([cmd (command-name name (item-key item))])
              (register-command! cmd (make-item-command item) "A transient menu key.")
              (define-key! m (item-key item) cmd)))
          (cdr g)))
       groups)
      (register-command! 'transient-quit (lambda () (close-transient)) "Close the transient menu.")
      (define-key! m "C-g" 'transient-quit)
      (define-key! m "ESC" 'transient-quit)
      m))

  (define (open-transient name)
    (let ([d (hashtable-ref defs name #f)])
      (unless d (error 'open-transient "no such transient" name))
      (when current (close-transient))
      (let* ([groups (cdr d)]
             [s (make-session name (car d) groups (build-map name groups)
                              (make-eq-hashtable) #f)])
        (set! current s)
        ;; defaults
        (for-each (lambda (g)
                    (for-each (lambda (i)
                                (when (memq (item-kind i) '(switch option))
                                  (let ([v (item-extra i)])
                                    (when v (set-value! (item-target i) v)))))
                              (cdr g)))
                  groups)
        (session-canvas-set! s (make-canvas 100 100))
        (reopen-map!)
        (refresh-panel!))))

  (define (hide!)
    (when current
      (let ([s current])
        (set! current #f)
        (when (session-canvas s) (delete-canvas! (session-canvas s))))))

  (define (close-transient)
    (when current
      (if (transient-map-active?) (exit-transient-map!) (hide!))))

  ;; ---- drawing ----

  (define (token group key default) (or (theme-token group key) default))

  (define (width-of str face) (let-values ([(w h) (text-extent str face)]) w))
  (define (height-of face) (let-values ([(w h) (text-extent "M" face)]) h))

  ;; Rows of a group: (key-text label-text value-text value-face).
  (define (rows-of g)
    (map (lambda (i)
           (case (item-kind i)
             [(action) (list (key-text (item-key i)) (item-label i) "" 'default)]
             [(switch) (list (key-text (item-key i)) (item-label i) ""
                             (if (value (item-target i)) 'success 'shadow))]
             [else (let ([v (value (item-target i))])
                     (list (key-text (item-key i)) (item-label i) (or v "unset")
                           (if v 'link 'shadow)))]))
         (cdr g)))

  (define (refresh-panel!)
    (let* ([s current] [c (session-canvas s)] [f (selected-frame)]
           [pad (token 'spacing 'l 12)] [gap (token 'spacing 'xl 16)] [colgap (token 'spacing 'xxl 24)]
           [m (popup-margin)]
           [lh (inexact->exact (ceiling (height-of 'default)))]
           [cols (map (lambda (g) (cons (car g) (rows-of g))) (session-groups s))]
           [col-w (map (lambda (col)
                         (let ([kw (apply max 0 (map (lambda (r) (width-of (car r) 'minibuffer-prompt)) (cdr col)))])
                           (list kw
                                 (apply max (width-of (car col) 'shadow)
                                        (map (lambda (r)
                                               (+ kw gap (width-of (cadr r) 'default)
                                                  (if (string=? (caddr r) "") 0 (+ 6 (width-of (caddr r) 'default)))))
                                             (cdr col))))))
                       cols)]
           [content-w (+ (apply + (map cadr col-w)) (* colgap (max 0 (- (length cols) 1))))]
           [content-h (* lh (+ 1 (apply max 1 (map (lambda (col) (length (cdr col))) cols))))]
           [w (min (frame-width f) (+ (inexact->exact (ceiling content-w)) (* 2 pad) (* 2 m)))]
           [h (+ content-h (* 2 pad) (* 2 m))]
           [mini-y (cadr (window-edges (minibuffer-window)))])
      (set-canvas-size! c w h)
      (clear-canvas! c)
      (draw-popup-background! c w h)
      (let loop ([cols cols] [ws col-w] [x (+ m pad)])
        (unless (null? cols)
          (let ([col (car cols)] [kw (caar ws)])
            (draw-text! c x (+ m pad) (car col) 'shadow)
            (let rows ([rs (cdr col)] [y (+ m pad lh)])
              (unless (null? rs)
                (let* ([r (car rs)] [lx (+ x kw gap)])
                  (draw-text! c x y (car r) 'minibuffer-prompt)
                  (draw-text! c lx y (cadr r) (if (string=? (caddr r) "") 'default (cadddr r)))
                  (unless (string=? (caddr r) "")
                    (draw-text! c (+ lx (width-of (cadr r) 'default) 6) y (caddr r) (cadddr r))))
                (rows (cdr rs) (+ y lh))))
            (loop (cdr cols) (cdr ws) (+ x (cadar ws) colgap)))))
      (show-popup! c 0 (- mini-y h (- m)))))
  )
