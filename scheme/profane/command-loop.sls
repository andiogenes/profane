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
  (export handle-key handle-text last-input-text last-input-key pending-keys self-insert-amalgamation
          set-transient-map exit-transient-map! clear-transient-map! transient-map-active?
          set-input-buffer-function! set-key-reader!
          command-busy? resume-busy! abort-busy! command-wait! command-wake!)
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

  ;; A mode that takes over the keyboard (a terminal) sets these buffer-locally. key-filter is
  ;; called with the first key of every sequence: a command symbol it returns runs instead of the
  ;; keymaps, #f lets them have the key. Typed text that no keymap binds runs text-input-command.
  (defvar key-filter #f "Procedure from a key to a command to run for it, or #f for the keymaps." '(local))
  (defvar text-input-command 'self-insert-command "Command run for typed text no keymap binds." '(local))

  (define last-key #f)
  (define (last-input-key) last-key)

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
    (%input-set-prefix-pending (or (pair? pending) (and transient #t) (and key-reader #t))))

  ;; The next key (a key description, as handle-key gets it; typed text arrives one character
  ;; at a time) goes to PROC instead of the keymaps, once: avy reads its characters this way.
  ;; PROC may set a reader again. While one is set the shell sends plain keys as keys.
  (define key-reader #f)
  (define (set-key-reader! proc)
    (set! key-reader proc)
    (set-pending! pending))

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

  ;; ---- commands that outlive their time slice ----
  ;; Each command (with its post-command work) runs in a Chez engine that is allowed
  ;; `command-slice-ticks` procedure calls at a time. Almost every command finishes in its first
  ;; slice and nothing changes. One that does not is suspended and the call returns: the shell
  ;; runs its event loop and calls resume-busy! (via pf-resume) for the next slice, so C-g, the
  ;; one key still read meanwhile, can abort it (abort-busy!, plan §0). Other keys and text typed
  ;; meanwhile wait in a queue and run, in order, once the command is done; C-g throws that
  ;; typeahead away, as in Emacs. A suspended command's dynamic-wind exits have already run (with-
  ;; current-buffer is undone), and abort just drops the rest of it. Commands run from inside a
  ;; command (M-x, avy, transient actions) share its slice.
  (defvar command-slice-ticks 500000
    "Procedure calls a command may make before the editor checks for C-g (about a few ms).")

  (define suspended #f)      ; the engine of a command waiting for its next slice, or #f
  (define in-command #f)     ; a slice is running
  (define saved-buffer #f)   ; the current buffer when the command was suspended
  (define input-queue '())   ; (key . "C-x") and (text . "ab") typed while suspended, in order
  (define resume-scheduled #f)

  (define (command-busy?) (and suspended #t))

  ;; A command that waits for something other than the clock (a process, a timer: (profane
  ;; async) await) parks its engine instead of spinning: the slice ends without scheduling a
  ;; resume, and command-wake! schedules one when what it waits for may have happened. Still
  ;; "busy": C-g aborts it and other input queues.
  (define waiting #f)

  ;; Inside a command: blocks until (READY?) is true and returns #t. Elsewhere there is no
  ;; engine to park, and it returns #f at once: the caller must wait some other way.
  (define (command-wait! ready?)
    (and in-command
         (begin
           (let loop ()
             (unless (ready?)
               (set! waiting #t)
               (engine-block)
               (loop)))
           #t)))

  (define (command-wake!)
    (when (and suspended waiting) (schedule-resume!)))

  (define (schedule-resume!)
    (unless resume-scheduled
      (set! resume-scheduled #t)
      (when (foreign-entry? "pf_app_schedule_resume")
        ((foreign-procedure "pf_app_schedule_resume" () void)))))

  (define (slice!)
    (let ([e suspended] [was-busy (and suspended #t)])
      (set! suspended #f)
      (set! waiting #f)
      (set! in-command #t)
      (e (var-ref 'command-slice-ticks)
         (lambda (ticks . vals)
           (set! in-command #f)
           (when was-busy (%input-set-busy #f))
           (drain-queue!))
         (lambda (e2)
           (set! in-command #f)
           (set! suspended e2)
           (set! saved-buffer (current-buffer))
           (%input-set-busy #t)
           (unless waiting (schedule-resume!))))))

  (define (run-in-engine thunk)
    (if in-command
        (thunk)
        (begin (set! suspended (make-engine thunk)) (slice!))))

  ;; The next slice of the suspended command, if any.
  (define (resume-busy!)
    (set! resume-scheduled #f)
    (when suspended
      (when (and saved-buffer (buffer-live? saved-buffer)) (set-buffer saved-buffer))
      (slice!)))

  ;; C-g while a command is suspended: drop it and the typeahead.
  (define (abort-busy!)
    (set! suspended #f)
    (set! waiting #f)
    (set! input-queue '())
    (%input-set-busy #f)
    (set-pending! '())
    (set! arg-pending #f)
    (set! arg-digits? #f)
    (set! insert-run 0)
    (%set-prefix-arg! #f)
    (%set-last-command! #f)
    (beep)
    (message "Quit"))

  (define (drain-queue!)
    (let loop ()
      (when (and (pair? input-queue) (not suspended))
        (let ([event (car input-queue)])
          (set! input-queue (cdr input-queue))
          (if (eq? (car event) 'key) (process-key (cdr event)) (process-text (cdr event)))
          (loop)))))

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
        (run-in-engine
         (lambda ()
           (guard (c [else (report name c)])
             (if proc (proc) (error name "no such command")))
           (when (and (buffer-live? edited-buffer)
                      (with-current-buffer edited-buffer (not (= edits (buffer-edit-count)))))
             (with-current-buffer edited-buffer (var-set! 'mark-active #f)))
           (%set-prefix-arg! #f)
           (%set-last-command! name)
           (guard (c [else (report 'post-command-hook c)])
             (run-hooks 'post-command-hook)))))))

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

  ;; Keys arrive here; while a command is suspended only C-g is acted on, the rest is queued.
  (define (handle-key key)
    (if (and suspended (not in-command))
        (if (equal? key "C-g") (abort-busy!) (set! input-queue (append input-queue (list (cons 'key key)))))
        (process-key key)))

  (define (process-key key)
    (select-window-buffer)
    (when (current-message) (message #f))
    (set! last-key key)
    (cond
      [key-reader
       (let ([reader key-reader])
         (set-key-reader! #f)
         (guard (c [else (report 'key-reader c)])
           (reader key)))]
      [(and (null? pending) (not transient) (var-ref 'key-filter) ((var-ref 'key-filter) key))
       => (lambda (command)
            (%set-prefix-arg! #f)
            (run-command command))]
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
    (if (and suspended (not in-command))
        (set! input-queue (append input-queue (list (cons 'text text))))
        (process-text text)))

  (define (process-text text)
    (select-window-buffer)
    (cond
      [(or (pair? pending) transient key-reader)
       (for-each (lambda (c) (handle-key (char-key c))) (string->list text))]
      [(and arg-digits? (prefix-arg-key text)) (when (current-message) (message #f))]
      [else
       (when (current-message) (message #f))
       (set! input-text text)
       ;; A mode may bind a plain character (dired's n, m, d): the command runs instead of
       ;; inserting it. Everything else is typed.
       (let ([b (and (= (string-length text) 1) (key-binding (list (char-key (string-ref text 0)))))])
         (run-command (if (symbol? b) b (var-ref 'text-input-command))))])))
