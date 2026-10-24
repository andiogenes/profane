;;; (profane command-loop) — turning keys into commands. Unstable API (plan §10).
;;;
;;; Keys arrive one at a time from the shell. The loop collects a key sequence until the active
;;; keymaps (profane mode) bind it to a command or to nothing; prefix keys (C-x) wait for more.
;;; C-u / C-u C-u / C-u 12 / M-5 / C-- set the prefix argument of the next command. Each command
;;; runs in the selected window's buffer with an undo boundary before it, except inside a run
;;; of up to self-insert-amalgamation typed characters. Errors beep and go to *Messages*. New
;;; input clears the echo area. A transient map (set-transient-map) takes precedence for the
;;; next key sequence only.

(library (profane command-loop)
  (export handle-key handle-text last-input-text pending-keys self-insert-amalgamation
          set-transient-map exit-transient-map! clear-transient-map! transient-map-active?
          set-input-buffer-function!)
  (import (chezscheme) (profane native) (profane buffer) (profane window) (profane keymap)
          (profane mode) (profane command) (profane hook) (profane var))

  (defhook post-command-hook)

  ;; macOS shows an accent picker for a held letter instead of repeating it. profane turns that
  ;; off, so held keys repeat; list here the plain keys (as named by the key description, "e")
  ;; for which it should stay on. Chords never show it: they bypass the input method.
  (defvar press-and-hold-keys '()
    "Plain keys that show macOS's accent picker when held (every other key repeats).")

  ;; Emacs transient-mark-mode: C-SPC (or C-x C-x) makes the region active and windows show
  ;; it; changing the buffer or C-g deactivates it. The mark itself stays set.
  (defvar mark-active #f "Whether the region between point and the mark is active (highlighted)."
    '(local))

  (define (push-press-and-hold! keys)
    (let ([bv (string->utf8
               (apply string-append
                      (let loop ([ks keys])
                        (cond [(null? ks) '()]
                              [(string? (car ks)) (cons (car ks) (cons "\n" (loop (cdr ks))))]
                              [else (loop (cdr ks))]))))])
      (%input-set-press-and-hold bv (bytevector-length bv))))

  (define press-and-hold-installed
    (begin
      (add-var-watcher! 'press-and-hold-keys
                        (lambda (name value where) (push-press-and-hold! value)))
      (push-press-and-hold! (var-ref 'press-and-hold-keys))
      #t))

  ;; Where keys go: the selected window's buffer, unless this procedure returns a buffer (the
  ;; minibuffer, while it reads input).
  (define input-buffer-function (lambda () #f))
  (define (set-input-buffer-function! proc) (set! input-buffer-function proc))

  (define self-insert-amalgamation 20)

  (define pending '())          ; keys of an unfinished sequence
  (define (pending-keys) pending)
  (define transient #f)         ; (keymap on-exit persistent?) for the next key sequence, or #f

  ;; The shell sends plain keys as keys (not text) while a sequence is under way, so C-x o is
  ;; other-window under any keyboard layout.
  (define (set-pending! keys)
    (set! pending keys)
    (%input-set-prefix-pending (or (pair? pending) (and transient #t))))

  ;; Emacs set-transient-map: MAP is looked up first for the next key sequence, then dropped
  ;; and ON-EXIT called, whichever command (or none) the sequence ran. With PERSISTENT it stays
  ;; until exit-transient-map! (a menu, see (profane transient)): its commands run without
  ;; leaving it, an unbound key only complains, and C-g in the middle of a sequence cancels
  ;; just the sequence.
  (define set-transient-map
    (case-lambda
      [(map) (set-transient-map map void #f)]
      [(map on-exit) (set-transient-map map on-exit #f)]
      [(map on-exit persistent?)
       (set! transient (list map on-exit persistent?))
       (set-pending! pending)]))

  (define (transient-map-active?) (and transient #t))
  (define (transient-persistent?) (and transient (caddr transient)))

  (define (exit-transient!)
    (when transient
      (let ([on-exit (cadr transient)])
        (set! transient #f)
        (set-pending! pending)
        (on-exit))))

  (define (exit-transient-map!) (exit-transient!))

  ;; Drops the transient map without calling its ON-EXIT (to hand the keys to something else
  ;; for a while, such as the minibuffer, and set the map again afterwards).
  (define (clear-transient-map!)
    (set! transient #f)
    (set-pending! pending))

  (define input-text "")
  (define (last-input-text) input-text)
  (define insert-run 0)
  (define run-buffer #f) ; the buffer the current typing run is in

  ;; Prefix argument being typed: #f, or the raw value so far; digits? while C-u digits count.
  (define arg-pending #f)
  (define arg-digits? #f)

  (define (beep)
    (when (foreign-entry? "pf_app_beep")
      ((foreign-procedure "pf_app_beep" () void))))

  (define (report name c)
    (beep)
    (message "~a"
             (if (condition? c)
                 (call-with-string-output-port (lambda (p) (display-condition c p)))
                 (format "~a: ~s" name c))))

  (define (select-window-buffer)
    (let ([b (input-buffer-function)] [w (selected-window)])
      (cond
        [(and b (buffer-live? b)) (set-buffer b)]
        [(and w (window-buffer w) (buffer-live? (window-buffer w)))
         (set-buffer (window-buffer w))])))

  ;; The binding of KEYS in the active keymaps: the first map binding it to anything wins.
  (define (key-binding keys)
    (let loop ([maps (if transient
                         (cons (car transient) (current-active-maps))
                         (current-active-maps))])
      (and (pair? maps) (or (lookup-key (car maps) keys) (loop (cdr maps))))))

  (define (run-command name)
    (let ([proc (command-procedure name)])
      ;; A run ends at another command, after self-insert-amalgamation characters, or when the
      ;; buffer changes (it used to carry on into the next buffer).
      (if (and (eq? name 'self-insert-command) (eq? (last-command) 'self-insert-command)
               (eq? run-buffer (current-buffer))
               (< insert-run self-insert-amalgamation) (not arg-pending))
          (set! insert-run (+ insert-run 1))
          (begin (undo-boundary) (set! insert-run 1)))
      (set! run-buffer (current-buffer))
      (%set-prefix-arg! arg-pending)
      (set! arg-pending #f)
      (set! arg-digits? #f)
      (%set-this-command! name)
      (let ([edited-buffer (current-buffer)] [edits (buffer-edit-count)])
        (guard (c [else (report name c)])
          (if proc (proc) (error name "no such command")))
        (when (and (buffer-live? edited-buffer)
                   (with-current-buffer edited-buffer (not (= edits (buffer-edit-count)))))
          (with-current-buffer edited-buffer (var-set! 'mark-active #f))))
      (%set-prefix-arg! #f)
      (%set-last-command! name)
      (guard (c [else (report 'post-command-hook c)])
        (run-hooks 'post-command-hook))))

  ;; ---- prefix argument keys, handled by the loop itself ----

  (define (digit-of key)
    (let ([name (substring key (- (string-length key) 1) (string-length key))])
      (and (= (string-length name) 1) (char-numeric? (string-ref name 0))
           (string->number name))))

  (define (meta-or-control-digit? key)
    (and (> (string-length key) 2) (member (substring key 0 2) '("M-" "C-"))
         (= (string-length key) 3) (digit-of key)))

  (define (prefix-arg-key key)
    (cond
      [(equal? key "C-u")
       (set! arg-pending (if (pair? arg-pending) (list (* 4 (car arg-pending))) '(4)))
       (set! arg-digits? #t)
       #t]
      [(and arg-digits? (= (string-length key) 1) (digit-of key))
       => (lambda (d)
            (set! arg-pending (cond [(integer? arg-pending) (+ (* 10 arg-pending) d)]
                                    [(eq? arg-pending '-) (- d)]
                                    [else d]))
            #t)]
      [(meta-or-control-digit? key)
       => (lambda (d)
            (set! arg-pending (cond [(integer? arg-pending) (+ (* 10 arg-pending) d)]
                                    [(eq? arg-pending '-) (- d)]
                                    [else d]))
            (set! arg-digits? #t)
            #t)]
      [(and (or (member key '("C--" "M--")) (and arg-digits? (equal? key "-")))
            (not (integer? arg-pending)))
       (set! arg-pending '-)
       (set! arg-digits? #t)
       #t]
      [else #f]))

  (define (handle-key key)
    (select-window-buffer)
    (when (current-message) (message #f))
    (cond
      [(and (null? pending) (not transient) (prefix-arg-key key)) (void)]
      [(and (pair? pending) (equal? key "C-g"))
       (set-pending! '())
       (set! arg-pending #f)
       (unless (transient-persistent?) (exit-transient!))
       (message "Quit")]
      [else
       (let* ([keys (append pending (list key))]
              [b (key-binding keys)])
         (cond
           [(keymap? b)
            (set-pending! keys)
            (unless (transient-persistent?) (%echo (format "~a-" (key-description keys))))]
           [(symbol? b)
            (set-pending! '())
            (unless (transient-persistent?) (exit-transient!))
            (run-command b)]
           [else
            (set-pending! '())
            (set! arg-pending #f)
            (set! arg-digits? #f)
            (unless (transient-persistent?) (exit-transient!))
            (%set-last-command! #f)
            (beep)
            (message "~a is undefined" (key-description keys))]))]))

  ;; A key as the shell names it, for text that arrives in the middle of a key sequence.
  (define (char-key c) (if (char=? c #\space) "SPC" (string c)))

  ;; Typed text; digits and "-" right after C-u go to the prefix argument (plain keys reach
  ;; Scheme as text through the input method, not as keys). Inside a key sequence (after C-x,
  ;; or with a transient map) text is keys: C-x u used to insert "u".
  (define (handle-text text)
    (select-window-buffer)
    (cond
      [(or (pair? pending) transient)
       (for-each (lambda (c) (handle-key (char-key c))) (string->list text))]
      [(and arg-digits? (prefix-arg-key text)) (when (current-message) (message #f))]
      [else
       (when (current-message) (message #f))
       (set! input-text text)
       (run-command 'self-insert-command)])))
