;;; (profane vterm) — a terminal emulator in a window, after Emacs's vterm. Unstable API (plan §10).
;;;
;;; M-x vterm opens a shell (explicit-shell-file-name) on a pseudo-terminal in a buffer of mode
;;; vterm-mode; M-x shell-here opens one rooted at the current directory (one per directory,
;;; reused). The window shows the terminal's cell grid (libvterm, core/term), not buffer text:
;;; full-screen programs, truecolor and wide characters work, and the grid follows the window's
;;; size. Every key goes to the program except vterm-keymap-exceptions (C-x, M-x, C-g, C-c, ...:
;;; those stay the editor's). Typed text, including input-method text, goes to the program too.
;;;
;;;   C-c C-c C-d C-z C-g C-l   send that control key       C-q   send the next key as it is
;;;   C-y M-y                   paste the kill ring          C-c C-t   copy mode (below)
;;;   S-<prior> S-<next>        scroll the terminal's history
;;;
;;; Copy mode (C-c C-t) puts the history and the screen into the buffer as plain text, read-only,
;;; so searching, the region and M-w work as anywhere; C-c C-t returns to the live terminal. When
;;; the program exits its buffer is killed (vterm-kill-buffer-on-exit).

(library (profane vterm)
  (export vterm-buffer? vterm-title vterm-copy-mode? vterm-send-string vterm-text vterm-size
          vterm-scroll-offset)
  (import (chezscheme) (profane native) (profane buffer) (profane window) (profane command)
          (profane command-loop) (profane keymap) (profane mode) (profane var) (profane hook)
          (profane face) (profane display) (profane theme) (profane process) (profane files)
          (profane simple))

  (defvar explicit-shell-file-name #f
    "The shell programs like vterm run (#f: the SHELL environment variable, else /bin/zsh).")
  (defvar vterm-scrollback 5000 "Lines of history a terminal keeps.")
  (defvar vterm-kill-buffer-on-exit #t "Kill a terminal's buffer when its program exits.")
  (defvar vterm-keymap-exceptions
    '("C-c" "C-x" "C-g" "M-x" "M-o" "M-g" "C-y" "M-y" "M-:")
    "Keys the editor keeps in a terminal buffer instead of sending them to the program.")

  (define terminal-faces
    (begin
      (for-each (lambda (f) (define-face (car f) (cadr f) (caddr f)))
                '((vterm () "Terminal text.")
                  (vterm-bold ((weight . bold)) "Bold terminal text.")
                  (vterm-italic ((slant . italic)) "Italic terminal text.")
                  (vterm-bold-italic ((weight . bold) (slant . italic)) "Bold italic terminal text.")))
      #t))

  (define-major-mode vterm-mode fundamental-mode "VTerm" "Major mode of terminal buffers.")

  ;; ---- sessions ----

  (define-record-type session
    (fields buffer (mutable process) handle (mutable title) (mutable bells) (mutable copy?)
            (mutable dead?)))

  (define sessions (make-weak-eq-hashtable)) ; buffer -> session

  (define (session-of b) (and b (hashtable-ref sessions b #f)))
  (define (vterm-buffer? b) (and (session-of b) #t))
  (define (vterm-title b) (let ([s (session-of b)]) (and s (session-title s))))
  (define (vterm-copy-mode? b) (let ([s (session-of b)]) (and s (session-copy? s))))
  ;; The history and screen as text, the terminal's size as (rows . columns), and how far back
  ;; (in lines) the view is scrolled.
  (define (vterm-text b)
    (let* ([s (session-of b)] [h (session-handle s)] [n (%trm-dump h (make-bytevector 0) 0)] [bv (make-bytevector n)])
      (%trm-dump h bv n)
      (utf8->string bv)))
  (define (vterm-size b) (let ([h (session-handle (session-of b))]) (cons (%trm-rows h) (%trm-cols h))))
  (define (vterm-scroll-offset b) (%trm-view-offset (session-handle (session-of b))))

  (define (current-session!)
    (or (session-of (current-buffer)) (error 'vterm "this is not a terminal buffer")))

  (define (shell-program)
    (or (var-ref 'explicit-shell-file-name) (getenv "SHELL") "/bin/zsh"))

  ;; ---- colors ----

  (define fallback-ansi
    '#(#x000000 #xcd0000 #x00cd00 #xcdcd00 #x0000ee #xcd00cd #x00cdcd #xe5e5e5
       #x7f7f7f #xff0000 #x00ff00 #xffff00 #x5c5cff #xff00ff #x00ffff #xffffff))
  (define ansi-roles
    '#(term-black term-red term-green term-yellow term-blue term-magenta term-cyan term-white
       term-bright-black term-bright-red term-bright-green term-bright-yellow term-bright-blue
       term-bright-magenta term-bright-cyan term-bright-white))

  (define (role-color role fallback)
    (let ([c (guard (e [else #f]) (theme-color role))])
      (if (and (string? c) (>= (string-length c) 7) (char=? (string-ref c 0) #\#))
          (or (string->number (substring c 1 7) 16) fallback)
          fallback)))

  (define (push-colors! s)
    (let ([ansi (make-bytevector 64)])
      (do ([i 0 (+ i 1)]) ((= i 16))
        (bytevector-u32-native-set! ansi (* 4 i)
                                    (role-color (vector-ref ansi-roles i) (vector-ref fallback-ansi i))))
      (%trm-set-colors (session-handle s) (role-color 'fg #xdddddd) (role-color 'bg #x000000) ansi)))

  ;; ---- talking to the program ----

  (define (send-bytes! s bv)
    (let ([p (session-process s)])
      (when (and p (process-live? p)) (process-send-bytes p bv))))

  ;; What the terminal wants to say (key encodings, answers to queries) goes to the program.
  (define (flush-output! s)
    (let ([buf (make-bytevector 4096)])
      (let loop ()
        (let ([n (%trm-output (session-handle s) buf 4096)])
          (when (> n 0)
            (let ([chunk (make-bytevector n)])
              (bytevector-copy! buf 0 chunk 0 n)
              (send-bytes! s chunk))
            (loop))))))

  (define (read-title s)
    (let* ([h (session-handle s)] [n (%trm-title h (make-bytevector 0) 0)])
      (if (> n 0)
          (let ([bv (make-bytevector n)])
            (%trm-title h bv n)
            (utf8->string bv))
          #f)))

  (define (on-program-output s bv)
    (let ([h (session-handle s)])
      (%trm-feed h bv (bytevector-length bv))
      (flush-output! s)
      (let ([bells (%trm-bells h)])
        (when (> bells (session-bells s))
          (session-bells-set! s bells)
          (when (foreign-entry? "pf_app_beep") ((foreign-procedure "pf_app_beep" () void)))))
      (session-title-set! s (read-title s))))

  (define (vterm-send-string b string)
    (let ([s (session-of b)])
      (when s
        (let ([bv (string->utf8 string)])
          (%trm-text (session-handle s) bv (bytevector-length bv))
          (flush-output! s)))))

  (define (send-key! s key)
    (let ([bv (string->utf8 key)])
      (if (zero? (%trm-key (session-handle s) bv (bytevector-length bv)))
          (flush-output! s)
          (message "~a is not a terminal key" key))))

  ;; ---- creating terminals ----

  (define (window-size w)
    (if w
        (cons (max 1 (%trm-window-size (%window-handle w) 0)) (max 1 (%trm-window-size (%window-handle w) 1)))
        (cons 24 80)))

  (define (make-terminal-buffer name dir)
    (let* ([b (generate-new-buffer name)]
           [size (window-size (selected-window))]
           [h (%trm-new (car size) (cdr size) (var-ref 'vterm-scrollback))]
           [s (make-session b #f h #f 0 #f #f)])
      (when (zero? h) (error 'vterm "cannot create a terminal"))
      (hashtable-set! sessions b s)
      (push-colors! s)
      (with-current-buffer b
        (set-major-mode! 'vterm-mode)
        (var-set! 'display-line-numbers #f)
        (var-set! 'default-directory dir)
        (var-set! 'key-filter key-filter)
        (var-set! 'text-input-command 'vterm-send-text)
        (buffer-disable-undo)
        (set-buffer-read-only! #t))
      (session-process-set!
       s
       (start-process "vterm" (list (shell-program))
                      `((pty . #t) (binary . #t) (cwd . ,dir) (rows . ,(car size)) (cols . ,(cdr size))
                        (env . (("INSIDE_PROFANE" . "1") ("COLORTERM" . "truecolor")))
                        (filter . ,(lambda (p bv) (on-program-output s bv)))
                        (sentinel . ,(lambda (p event) (on-exit s event))))))
      b))

  (define (on-exit s event)
    (session-dead?-set! s #t)
    (let ([b (session-buffer s)])
      (if (and (var-ref 'vterm-kill-buffer-on-exit) (buffer-live? b))
          (begin (destroy-session! s) (kill-buffer b))
          (let ([note (string->utf8 (string-append "\r\n[Process exited: " (string-trim-right event) "]\r\n"))])
            (%trm-feed (session-handle s) note (bytevector-length note))))))

  (define (string-trim-right s)
    (let loop ([n (string-length s)])
      (if (and (> n 0) (char-whitespace? (string-ref s (- n 1)))) (loop (- n 1)) (substring s 0 n))))

  ;; Detaches the terminal from every window, kills the program and frees the terminal.
  (define (destroy-session! s)
    (detach-everywhere! (session-handle s))
    (let ([p (session-process s)]) (when (and p (process-live? p)) (kill-process p)))
    (%trm-free (session-handle s))
    (session-dead?-set! s #t))

  (define (default-dir)
    (default-directory))

  (define-command (vterm)
    "Open a terminal (the one called *vterm*, if there is one; with a prefix argument a new one)."
    (let* ([new? (current-prefix-arg)] [existing (get-buffer "*vterm*")])
      (if (and existing (not new?) (session-of existing) (not (session-dead? (session-of existing))))
          (switch-to-buffer existing)
          (switch-to-buffer (make-terminal-buffer "*vterm*" (default-dir))))))

  (define-command (shell-here)
    "Open a shell rooted at the current directory (the existing one, if there is one)."
    (let* ([dir (default-dir)]
           [trimmed (if (and (> (string-length dir) 1) (directory-name? dir)) (substring dir 0 (- (string-length dir) 1)) dir)]
           [name (string-append "*shell*<" trimmed "/>")]
           [existing (get-buffer name)])
      (if (and existing (session-of existing) (not (session-dead? (session-of existing))))
          (switch-to-buffer existing)
          (switch-to-buffer (make-terminal-buffer name dir)))))

  ;; ---- keys ----

  (define (key-filter key)
    (cond
      [(member key (var-ref 'vterm-keymap-exceptions)) #f]
      [(equal? key "C-q") 'vterm-send-next-key]
      [(equal? key "S-<prior>") 'vterm-scroll-back]
      [(equal? key "S-<next>") 'vterm-scroll-forward]
      [else 'vterm-send-key]))

  (define-command (vterm-send-key) "Send the key just typed to the program."
    (send-key! (current-session!) (last-input-key)))

  (define-command (vterm-send-text) "Send the text just typed to the program."
    (vterm-send-string (current-buffer) (last-input-text)))

  (define-command (vterm-send-next-key) "Send the next key to the program, whatever it is."
    (let ([s (current-session!)] [b (current-buffer)])
      (set-key-reader! (lambda (key) (when (buffer-live? b) (send-key! s key))))
      (message "Send next key:")))

  (define-syntax define-send
    (syntax-rules ()
      [(_ name key doc) (define-command (name) doc (send-key! (current-session!) key))]))
  (define-send vterm-send-c-c "C-c" "Send C-c to the program.")
  (define-send vterm-send-c-d "C-d" "Send C-d to the program.")
  (define-send vterm-send-c-z "C-z" "Send C-z to the program.")
  (define-send vterm-send-c-g "C-g" "Send C-g to the program.")
  (define-send vterm-send-c-l "C-l" "Send C-l to the program.")

  (define-command (vterm-yank) "Paste the latest kill into the program."
    (let* ([s (current-session!)] [bv (string->utf8 (current-kill))])
      (%trm-paste (session-handle s) bv (bytevector-length bv))
      (flush-output! s)))

  (define (scroll! s lines) (%trm-scroll-view (session-handle s) lines))
  (define-command (vterm-scroll-back) "Scroll the terminal's history back a page."
    (let ([s (current-session!)]) (scroll! s (max 1 (- (%trm-rows (session-handle s)) 1)))))
  (define-command (vterm-scroll-forward) "Scroll the terminal's history forward a page."
    (let ([s (current-session!)]) (scroll! s (- (max 1 (- (%trm-rows (session-handle s)) 1))))))

  ;; ---- copy mode ----

  (define-command (vterm-copy-mode)
    "Show the terminal's history and screen as plain read-only text, or return to the terminal."
    (let ([s (current-session!)])
      (cond
        [(session-copy? s)
         (session-copy?-set! s #f)
         (with-inhibit-read-only (lambda () (erase-buffer)))
         (var-set! 'key-filter key-filter)
         (var-set! 'text-input-command 'vterm-send-text)
         (message "Back in the terminal")]
        [else
         (let* ([h (session-handle s)] [n (%trm-dump h (make-bytevector 0) 0)] [bv (make-bytevector n)])
           (%trm-dump h bv n)
           (session-copy?-set! s #t)
           (var-set! 'key-filter #f)
           (var-set! 'text-input-command 'self-insert-command)
           (with-inhibit-read-only
            (lambda ()
              (erase-buffer)
              (insert (utf8->string bv))))
           (goto-char (point-max))
           (message "Copy mode; C-c C-t returns to the terminal"))])))

  ;; ---- windows ----

  (define attached (make-weak-eq-hashtable)) ; window -> terminal handle it shows

  (define (set-terminal! w handle)
    (let ([f (window-frame w)])
      (%trm-set-window (%frame-handle f) (%window-handle w) handle
                       (if (zero? handle) 0 (face-id 'vterm)) (if (zero? handle) 0 (face-id 'vterm-bold))
                       (if (zero? handle) 0 (face-id 'vterm-italic))
                       (if (zero? handle) 0 (face-id 'vterm-bold-italic)))))

  (define (detach-everywhere! handle)
    (let-values ([(ws hs) (hashtable-entries attached)])
      (vector-for-each (lambda (w h)
                         (when (and (= h handle) (window-live? w)) (set-terminal! w 0))
                         (when (= h handle) (hashtable-delete! attached w)))
                       ws hs)))

  ;; Before every redisplay: windows show their terminal (or text, in copy mode), the terminal
  ;; takes the size of the window it is shown in (and the program is told), dead buffers are cleaned up.
  (define (sync! f)
    (for-each
     (lambda (w)
       (let* ([s (session-of (window-buffer w))]
              [want (if (and s (not (session-copy? s)) (not (session-dead? s))) (session-handle s) 0)]
              [have (hashtable-ref attached w 0)])
         (unless (= want have)
           (set-terminal! w want)
           (if (zero? want) (hashtable-delete! attached w) (hashtable-set! attached w want)))))
     (frame-windows f))
    (let ([done '()])
      (for-each
       (lambda (w)
         (let ([s (session-of (window-buffer w))])
           (when (and s (not (session-dead? s)) (not (memq s done)))
             (set! done (cons s done))
             (let* ([size (window-size w)] [h (session-handle s)])
               (unless (and (= (%trm-rows h) (car size)) (= (%trm-cols h) (cdr size)))
                 (%trm-resize h (car size) (cdr size))
                 (let ([p (session-process s)])
                   (when (and p (process-live? p)) (process-resize! p (car size) (cdr size)))))))))
       ;; the selected window drives the size when it shows the terminal
       (let ([sel (frame-selected-window f)])
         (if sel (cons sel (remq sel (frame-windows f))) (frame-windows f)))))
    ;; killed buffers
    (let-values ([(bs ss) (hashtable-entries sessions)])
      (vector-for-each (lambda (b s)
                         (unless (or (buffer-live? b) (session-dead? s)) (destroy-session! s)))
                       bs ss)))

  (define installed
    (begin
      (add-hook! 'pre-redisplay-hook sync!)
      (add-hook! 'after-load-theme-hook
                 (lambda args
                   (let-values ([(bs ss) (hashtable-entries sessions)])
                     (vector-for-each (lambda (b s) (unless (session-dead? s) (push-colors! s))) bs ss))))
      #t))

  (define bindings
    (begin
      (for-each (lambda (b) (define-key! (mode-keymap 'vterm-mode) (car b) (cdr b)))
                '(("C-c C-c" . vterm-send-c-c) ("C-c C-d" . vterm-send-c-d) ("C-c C-z" . vterm-send-c-z)
                  ("C-c C-g" . vterm-send-c-g) ("C-c C-l" . vterm-send-c-l) ("C-c C-t" . vterm-copy-mode)
                  ("C-y" . vterm-yank) ("M-y" . vterm-yank)))
      #t)))
