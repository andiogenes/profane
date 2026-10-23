;;; (profane theme) — themes, design tokens and UI style presets. Unstable API (plan §10, §6.1).
;;;
;;; A theme has a palette of semantic color roles, design tokens, and face specs written
;;; against the palette:
;;;
;;;   (define-theme 'my-theme
;;;     '((appearance . dark)
;;;       (palette (bg . "#101418") (fg . "#e8e8e8") (accent . system-accent) ...)
;;;       (tokens (spacing (xs . 2) (s . 4) (m . 8)) (radius (s . 4)) ...)
;;;       (faces (default (foreground . fg) (background . bg)) (link (foreground . accent)) ...)))
;;;
;;; Face attribute values that name a palette role are replaced by the role's color; a role may
;;; name another role or `system-accent` (the macOS accent color). (load-theme name) applies
;;; the faces and tokens and runs after-load-theme-hook. With theme-follows-appearance on,
;;; macOS light/dark mode switches between the themes in theme-for-appearance.
;;;
;;; UI style presets (ui-style 'minimal) / (ui-style 'rich) are named groups of variable
;;; settings; minimal is the default and the visual regression baseline (plan §6).

(library (profane theme)
  (export define-theme theme-names theme-appearance load-theme current-theme
          theme-color theme-token theme-palette
          appearance-changed! system-accent-changed! current-appearance
          define-ui-style ui-style ui-style-names current-ui-style)
  (import (chezscheme) (profane var) (profane hook) (profane face))

  (define themes (make-eq-hashtable)) ; name -> spec alist

  (define (define-theme name spec)
    (unless (assq 'palette spec) (error 'define-theme "a theme needs a palette" name))
    (hashtable-set! themes name spec)
    name)

  (define (theme-names) (vector->list (hashtable-keys themes)))

  (define (spec-ref spec key) (let ([e (assq key spec)]) (if e (cdr e) '())))

  (define (theme-spec name)
    (or (hashtable-ref themes name #f) (error 'load-theme "no such theme" name)))

  (define (theme-appearance name)
    (let ([e (assq 'appearance (theme-spec name))]) (if e (cdr e) 'light)))

  (define current #f)
  (define (current-theme) current)

  (define accent "#0a60ff") ; reported by the shell (NSColor.controlAccentColor)

  ;; Color of palette ROLE in theme NAME, following role references.
  (define (resolve palette value)
    (let loop ([v value] [depth 0])
      (cond
        [(> depth 16) (error 'theme-color "palette reference cycle" value)]
        [(eq? v 'system-accent) accent]
        [(symbol? v) (let ([e (assq v palette)]) (if e (loop (cdr e) (+ depth 1)) v))]
        [else v])))

  (define (theme-palette) (if current (spec-ref (theme-spec current) 'palette) '()))
  (define (theme-color role) (resolve (theme-palette) role))

  ;; (theme-token 'spacing 'm) -> 8; (theme-token 'line-height) -> 1.0 for single values.
  (define theme-token
    (case-lambda
      [(group) (let ([e (assq group (spec-ref (theme-spec current) 'tokens))])
                 (and e (cdr e)))]
      [(group key) (let ([g (theme-token group)])
                     (and (list? g) (let ([e (assq key g)]) (and e (cdr e)))))]))

  (defhook after-load-theme-hook)

  ;; Applies theme NAME. A theme owns colors, weight, slant and underline: for every face it
  ;; specifies, those are reset to the spec (left-out ones cleared, so switching never leaks a
  ;; previous theme's colors). Typography (family, height, features) is left alone: it belongs
  ;; to the type tokens and typography variables.
  (define (load-theme name)
    (let* ([spec (theme-spec name)]
           [palette (spec-ref spec 'palette)])
      (set! current name)
      (for-each
       (lambda (entry)
         (let ([face (car entry)])
           (unless (face-defined? face) (define-face face '()))
           (for-each (lambda (attr) (set-face-attribute! face attr #f))
                     '(foreground background underline weight slant))
           (for-each (lambda (a)
                       (set-face-attribute! face (car a)
                                            (if (memq (car a) '(foreground background underline))
                                                (resolve palette (cdr a))
                                                (cdr a))))
                     (cdr entry))))
       (spec-ref spec 'faces))
      (run-hooks 'after-load-theme-hook name)
      name))

  ;; ---- following macOS ----

  (defvar theme-follows-appearance #t
    "Switch themes with macOS light/dark mode, using theme-for-appearance.")
  (defvar theme-for-appearance '((light . profane-light) (dark . profane-dark))
    "Theme to load for each macOS appearance.")

  (define appearance 'light)
  (define (current-appearance) appearance)

  (define (appearance-changed! which)
    (set! appearance which)
    (when (var-ref 'theme-follows-appearance)
      (let ([e (assq which (var-ref 'theme-for-appearance))])
        (when (and e (hashtable-contains? themes (cdr e))) (load-theme (cdr e))))))

  ;; The accent color changed in System Settings: reload so roles using it pick it up.
  (define (system-accent-changed! color)
    (set! accent color)
    (when current (load-theme current)))

  ;; ---- UI style presets ----
  ;; Chrome settings the presets switch. Seams: each is read by the chrome it names as that
  ;; lands (windows and mode line: M2 item 4; pop-ups: item 6; scroll bars, motion: M4/M8).

  (defvar ui-fringe-width 1 "Fringe width in points (minimal: 1, like the owner's Emacs).")
  (defvar ui-scroll-bars #f "Scroll bars: #f, or overlay (thin, auto-hiding).")
  (defvar ui-popup-shadow #f "Whether pop-ups cast the theme's elevation shadow.")
  (defvar ui-motion 'subtle "Animation level: subtle or full (Reduce Motion always wins).")
  (defvar ui-mode-line-style 'flat "Mode line look: flat or raised.")

  (define styles (make-eq-hashtable)) ; name -> alist of (variable . value)
  (define style #f)
  (define (current-ui-style) style)

  (define (define-ui-style name settings)
    (hashtable-set! styles name settings)
    name)

  (define (ui-style-names) (vector->list (hashtable-keys styles)))

  (define (ui-style name)
    (let ([settings (or (hashtable-ref styles name #f) (error 'ui-style "no such ui style" name))])
      (for-each (lambda (s) (var-set-default! (car s) (cdr s))) settings)
      (set! style name)
      name)))
