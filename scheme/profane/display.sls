;;; (profane display) — faces and text properties as the display engine sees them. Unstable
;;; API (plan §10).
;;;
;;; Every face gets a small integer id; whenever any face changes, all faces are resolved
;;; (inheritance, default) and pushed to the C face table (core/display/pf_face.h), so a theme
;;; change restyles everything. The display engine's own faces (cursor, line numbers, hl-line,
;;; show-paren) are Emacs's built-in faces mapped to roles. Text properties live in the C core
;;; and move with edits; the `face` property holds a face (or #f), others hold any value.
;;;
;;; The light/dark palettes here are interim: themes and design tokens replace them (M2 item 3).

(library (profane display)
  (export face-id put-text-property get-text-property remove-text-property
          appearance set-appearance! color->rgba)
  (import (chezscheme) (profane native) (profane buffer) (profane face) (profane var))

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

  (define font-variables
    (begin
      (define-variable 'default-font-family "JetBrains Mono" "Family of the default face's font.")
      (define-variable 'default-font-size 14 "Size of the default face's font, in points.")))

  (define (open-font family size bold? italic?)
    (if (foreign-entry? "pf_font_open_styled")
        ((foreign-procedure "pf_font_open_styled" (utf-8 float int int) unsigned-32)
         family (inexact size) (if bold? 1 0) (if italic? 1 0))
        0)) ; no font registry (headless tests): the window's default font

  (define (bold? w) (and (memq w '(semibold bold extrabold heavy black)) #t))
  (define (italic? s) (and (memq s '(italic oblique)) #t))

  ;; Font id for face NAME, 0 when it is the default face's font.
  (define (face-font name)
    (let ([family (or (face-attribute name 'family) (var-ref 'default-font-family))]
          [height (or (face-attribute name 'height) 1)]
          [weight (face-attribute name 'weight)]
          [slant (face-attribute name 'slant)])
      (if (and (not (eq? name 'default)) (equal? family (var-ref 'default-font-family))
               (= height 1) (not (bold? weight)) (not (italic? slant))
               (not (bold? (face-attribute 'default 'weight)))
               (not (italic? (face-attribute 'default 'slant))))
          0
          (open-font family (* height (var-ref 'default-font-size)) (bold? weight)
                     (italic? slant)))))

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

  (define (push-all!) (for-each push-face! (face-names)))

  ;; pf_face_role order (core/display/pf_face.h).
  (define roles '(default cursor line-number line-number-current-line hl-line
                  show-paren-match show-paren-mismatch))

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
         (show-paren-mismatch () "A bracket without a proper partner.")))
      (let loop ([i 0] [rs roles])
        (unless (null? rs) (%face-role-set i (face-id (car rs))) (loop (+ i 1) (cdr rs))))
      (add-face-watcher! (lambda (name) (push-all!)))
      #t))

  ;; ---- interim appearance palettes (modus-operandi / modus-vivendi-like) ----

  (define palettes
    '((light (default (foreground . "#000000") (background . "#ffffff"))
             (cursor (background . "#000000"))
             (shadow (foreground . "#9a9a9a"))
             (line-number-current-line (foreground . "#000000"))
             (hl-line (background . "#e4e9ef"))
             (highlight (background . "#d7e4f5"))
             (region (background . "#bdd8ef"))
             (show-paren-match (background . "#b8d9f0"))
             (show-paren-mismatch (background . "#f2b8b8")))
      (dark (default (foreground . "#ffffff") (background . "#000000"))
            (cursor (background . "#ffffff"))
            (shadow (foreground . "#6b6b6b"))
            (line-number-current-line (foreground . "#ffffff"))
            (hl-line (background . "#1e1e2a"))
            (highlight (background . "#2a3a52"))
            (region (background . "#2f4f6a"))
            (show-paren-match (background . "#2f4f6a"))
            (show-paren-mismatch (background . "#7a2f2f")))))

  (define current-appearance 'light)
  (define (appearance) current-appearance)

  (define (set-appearance! which)
    (let ([palette (cdr (or (assq which palettes) (error 'set-appearance! "light or dark" which)))])
      (set! current-appearance which)
      (for-each (lambda (entry)
                  (for-each (lambda (a) (set-face-attribute! (car entry) (car a) (cdr a)))
                            (cdr entry)))
                palette)
      which))

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
