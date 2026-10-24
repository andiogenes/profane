;;; (profane display) — faces and text properties as the display engine sees them. Unstable
;;; API (plan §10).
;;;
;;; Every face gets a small integer id; whenever any face changes, all faces are resolved
;;; (inheritance, default) and pushed to the C face table (core/display/pf_face.h), so a theme
;;; change restyles everything. The display engine's own faces (cursor, line numbers, hl-line,
;;; show-paren) are Emacs's built-in faces mapped to roles. Text properties live in the C core
;;; and move with edits; the `face` property holds a face (or #f), others hold any value.
;;;
;;; Colors come from themes (profane theme); fonts from the default-font-* variables and
;;; per-face family/height/features. Text scale is per buffer: windows draw a buffer's text at
;;; its text-scale-factor (profane window pushes it), chrome is not scaled.

(library (profane display)
  (export face-id put-text-property get-text-property remove-text-property color->rgba
          text-scale pinch-text-scale)
  (import (chezscheme) (profane native) (profane buffer) (profane face) (profane var)
          (profane command) (profane keymap))

  ;; ---- face ids ----

  (define ids (make-eq-hashtable))
  (define next-id 1)

  (define (face-id name)
    (or (hashtable-ref ids name #f)
        (let ([id next-id])
          (set! next-id (+ id 1))
          (hashtable-set! ids name id)
          id)))

  ;; "#rrggbb" or "#rrggbbaa" -> 0xRRGGBBAA.
  (define (color->rgba c)
    (unless (and (string? c) (memv (string-length c) '(7 9)) (char=? (string-ref c 0) #\#))
      (error 'color->rgba "colors are \"#rrggbb\" strings" c))
    (let ([n (string->number (substring c 1 (string-length c)) 16)])
      (unless n (error 'color->rgba "bad color" c))
      (if (= (string-length c) 7) (+ (* n 256) 255) n)))

  ;; ---- fonts ----

  (defvar default-font-family "JetBrains Mono" "Family of the default face's font (code).")
  (defvar default-font-size 14 "Size of the default face's font, in points.")
  (defvar line-spacing 0 "Extra space between lines, in points.")

  ;; Text scale: a factor on the size of the current buffer's text (C-x C-= / C-x C-- /
  ;; C-x C-0, trackpad pinch), as Emacs's text-scale-mode.
  (defvar text-scale-factor 1.0 "Size of this buffer's text relative to its faces' fonts." '(local))
  (define (text-scale) (var-ref 'text-scale-factor))

  ;; FAMILY may be system-ui (the macOS UI font, SF Pro); FEATURES like "calt=0,liga=0".
  (define (open-font family size bold? italic? features)
    (if (foreign-entry? "pf_font_open_ex")
        ((foreign-procedure "pf_font_open_ex" (utf-8 float int int utf-8) unsigned-32)
         family (inexact size) (if bold? 1 0) (if italic? 1 0) features)
        0)) ; no font registry (headless tests): the window's default font

  (define (bold? w) (and (memq w '(semibold bold extrabold heavy black)) #t))
  (define (italic? s) (and (memq s '(italic oblique)) #t))

  ;; Font id for face NAME, 0 when it is the default face's font.
  (define (face-font name)
    (let ([family (or (face-attribute name 'family) (var-ref 'default-font-family))]
          [height (or (face-attribute name 'height) 1)]
          [weight (face-attribute name 'weight)]
          [slant (face-attribute name 'slant)]
          [features (face-attribute name 'features)])
      (if (and (not (eq? name 'default)) (equal? family (face-family 'default))
               (= height 1) (eq? (bold? weight) (bold? (face-attribute 'default 'weight)))
               (eq? (italic? slant) (italic? (face-attribute 'default 'slant)))
               (equal? features (face-attribute 'default 'features)))
          0 ; same font as the default face
          (open-font family (* height (var-ref 'default-font-size)) (bold? weight)
                     (italic? slant) features))))

  (define (face-family name) (or (face-attribute name 'family) (var-ref 'default-font-family)))

  ;; ---- pushing faces to C ----

  (define has-fg 1)
  (define has-bg 2)
  (define has-underline 4)

  (define (push-face! name)
    (let* ([fg (face-attribute name 'foreground)]
           [bg (face-attribute name 'background)]
           [ul (face-attribute name 'underline)]
           [flags (+ (if fg has-fg 0) (if bg has-bg 0) (if ul has-underline 0))])
      (%face-define (face-id name) flags (if fg (color->rgba fg) 0) (if bg (color->rgba bg) 0)
                    (if (string? ul) (color->rgba ul) 0) (face-font name))))

  (define (push-all!)
    (for-each push-face! (face-names))
    (%display-set-line-spacing (inexact (var-ref 'line-spacing))))

  ;; pf_face_role order (core/display/pf_face.h).
  (define roles '(default cursor line-number line-number-current-line hl-line
                  show-paren-match show-paren-mismatch fringe vertical-border))

  ;; ---- built-in faces ----

  (define builtin
    (begin
      (for-each
       (lambda (f) (define-face (car f) (cadr f) (caddr f)))
       '((bold ((weight . bold)) "Bold text.")
         (italic ((slant . italic)) "Italic text.")
         (bold-italic ((weight . bold) (slant . italic)) "Bold italic text.")
         (underline ((underline . #t)) "Underlined text.")
         (shadow () "Dimmed text.")
         (highlight () "Highlighted text.")
         (region () "The active region.")
         (cursor () "The cursor's color (its background).")
         (line-number ((inherit . shadow)) "Line numbers.")
         (line-number-current-line ((inherit . line-number)) "The current line's number.")
         (hl-line () "The current-line band (its background).")
         (show-paren-match () "A bracket and its partner.")
         (show-paren-mismatch () "A bracket without a proper partner.")
         (link () "Links.")
         (error () "Errors.")
         (warning () "Warnings.")
         (success () "Success.")
         (minibuffer-prompt () "Minibuffer prompts.")
         (variable-pitch ((family . "system-ui")) "Proportional text (docs, notes).")
         (fringe () "The fringes (their background).")
         (vertical-border () "The line between side-by-side windows (its foreground).")
         (mode-line ((family . "system-ui")) "The selected window's mode line.")
         (mode-line-inactive ((inherit . mode-line)) "Other windows' mode lines.")
         (mode-line-buffer-id ((family . "system-ui") (weight . bold))
                              "The buffer name in mode lines.")
         (mode-line-highlight () "Highlighted mode line text (window labels).")
         (tab-bar ((family . "system-ui")) "The tab bar.")
         (tab-bar-tab ((inherit . tab-bar)) "The current tab.")
         (tab-bar-tab-inactive ((inherit . tab-bar)) "Other tabs.")
         (fixed-pitch () "Monospaced text inside proportional text.")
         (font-lock-comment-face () "Comments.")
         (font-lock-doc-face ((inherit . font-lock-comment-face)) "Documentation.")
         (font-lock-string-face () "Strings.")
         (font-lock-keyword-face () "Keywords.")
         (font-lock-builtin-face () "Built-in names.")
         (font-lock-function-name-face () "Function names at definition.")
         (font-lock-variable-name-face () "Variable names at definition.")
         (font-lock-type-face () "Type names.")
         (font-lock-constant-face () "Constants.")))
      (let loop ([i 0] [rs roles])
        (unless (null? rs) (%face-role-set i (face-id (car rs))) (loop (+ i 1) (cdr rs))))
      (add-face-watcher! (lambda (name) (push-all!)))
      (for-each (lambda (v) (add-var-watcher! v (lambda (n val where) (push-all!))))
                '(default-font-family default-font-size line-spacing))
      #t))

  ;; ---- text scale ----

  (define (set-text-scale! s)
    (let ([s (max 0.5 (min 3.0 s))])
      (var-set! 'text-scale-factor s)
      (message "Text scale ~a%" (exact (round (* 100 s))))))

  (define-command (text-scale-increase) (set-text-scale! (* (text-scale) 1.1)))
  (define-command (text-scale-decrease) (set-text-scale! (/ (text-scale) 1.1)))
  (define-command (text-scale-reset) (set-text-scale! 1.0))

  ;; Trackpad pinch: MAGNIFICATION is the gesture's relative change.
  (define (pinch-text-scale magnification) (set-text-scale! (* (text-scale) (+ 1 magnification))))

  (define text-scale-bindings
    (begin
      (define-key! (global-map) "C-x C-=" 'text-scale-increase)
      (define-key! (global-map) "C-x C-+" 'text-scale-increase)
      (define-key! (global-map) "C-x C--" 'text-scale-decrease)
      (define-key! (global-map) "C-x C-0" 'text-scale-reset)
      #t))

  ;; ---- text properties ----

  (define prop-ids (make-eq-hashtable))   ; property name -> id (face is 1: PF_PROP_FACE)
  (define next-prop 2)
  (define values-by-id (make-eqv-hashtable)) ; non-face values, interned
  (define ids-by-value (make-hashtable equal-hash equal?))
  (define next-value 1)

  (define (prop-id name)
    (if (eq? name 'face)
        1
        (or (hashtable-ref prop-ids name #f)
            (begin
              (when (>= next-prop 32) (error 'put-text-property "too many text properties" name))
              (hashtable-set! prop-ids name next-prop)
              (set! next-prop (+ next-prop 1))
              (hashtable-ref prop-ids name #f)))))

  (define (encode name value)
    (cond
      [(not value) 0]
      [(eq? name 'face)
       (unless (face-defined? value) (error 'put-text-property "undefined face" value))
       (face-id value)]
      [(hashtable-ref ids-by-value value #f)]
      [else (let ([id next-value])
              (set! next-value (+ id 1))
              (hashtable-set! ids-by-value value id)
              (hashtable-set! values-by-id id value)
              id)]))

  (define (decode name id)
    (cond
      [(zero? id) #f]
      [(eq? name 'face)
       (let loop ([fs (face-names)]) (cond [(null? fs) #f]
                                           [(= (face-id (car fs)) id) (car fs)]
                                           [else (loop (cdr fs))]))]
      [else (hashtable-ref values-by-id id #f)]))

  (define (handle) (%buffer-handle (current-buffer)))

  ;; Gives characters [START, END) of the current buffer property NAME = VALUE (#f removes).
  (define (put-text-property start end name value)
    (let ([lo (min start end)] [hi (max start end)])
      (unless (and (>= lo 0) (<= hi (point-max))) (error 'put-text-property "out of range" start end))
      (%buf-put-prop (handle) (prop-id name) lo hi (encode name value))
      (void)))

  (define (remove-text-property start end name) (put-text-property start end name #f))

  (define (get-text-property pos name)
    (decode name (%buf-get-prop (handle) (prop-id name) pos))))
