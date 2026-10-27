(import (chezscheme) (srfi :64) (profane var) (profane hook) (profane face) (profane theme)
        (profane themes) (profane display) (profane command))

(for-each invoke-library '((profane display) (profane themes)))

(test-begin "theme")

;; ---- WCAG 2 contrast ----
(define (channel c)
  (let ([s (/ c 255.0)])
    (if (<= s 0.03928) (/ s 12.92) (expt (/ (+ s 0.055) 1.055) 2.4))))
(define (luminance hex)
  (let ([n (string->number (substring hex 1 7) 16)])
    (+ (* 0.2126 (channel (quotient n 65536)))
       (* 0.7152 (channel (mod (quotient n 256) 256)))
       (* 0.0722 (channel (mod n 256))))))
(define (contrast a b)
  (let ([la (luminance a)] [lb (luminance b)])
    (/ (+ (max la lb) 0.05) (+ (min la lb) 0.05))))

;; RELAXED lists (key . minimum) for values a theme copies from elsewhere and that miss the bar:
;; `divider` and the face names in the "text on" group.
(define (check-theme name . relaxed)
  (define (min-for key default) (let ([e (assq key relaxed)]) (if e (cdr e) default)))
  (load-theme name)
  (let ([bg (face-attribute 'default 'background)]
        [fg (face-attribute 'default 'foreground)])
    (test-assert (format "~a: body text >= 7:1" name) (>= (contrast fg bg) 7))
    (for-each
     (lambda (f)
       (test-assert (format "~a: ~a >= 4.5:1" name f)
                    (>= (contrast (face-attribute f 'foreground) bg) 4.5)))
     '(shadow line-number font-lock-comment-face link error warning success
       font-lock-string-face font-lock-keyword-face font-lock-type-face))
    (for-each
     (lambda (f)
       (test-assert (format "~a: text on ~a >= ~a:1" name f (min-for f 4.5))
                    (>= (contrast fg (face-attribute f 'background)) (min-for f 4.5))))
     '(hl-line highlight region show-paren-match show-paren-mismatch isearch lazy-highlight
       isearch-fail))
    (test-assert (format "~a: cursor stands out >= 7:1" name)
                 (>= (contrast (face-attribute 'cursor 'background) bg) 7))
    ;; Chrome: mode lines and tabs (active text >= 7:1, inactive >= 4.5:1), and the window
    ;; divider against the text background (>= 3:1, WCAG's bar for UI components).
    (for-each
     (lambda (f+min)
       (let ([f (car f+min)])
         (test-assert (format "~a: ~a text >= ~a:1" name f (cdr f+min))
                      (>= (contrast (face-attribute f 'foreground) (face-attribute f 'background))
                          (cdr f+min)))))
     '((mode-line . 7) (mode-line-inactive . 4.5) (tab-bar-tab . 7) (tab-bar-tab-inactive . 4.5)))
    (test-assert (format "~a: divider >= ~a:1" name (min-for 'divider 3))
                 (>= (contrast (face-attribute 'vertical-border 'foreground) bg) (min-for 'divider 3)))))

(check-theme 'profane-light)
(check-theme 'profane-dark)
;; The modus palettes are copied as published: operandi's border is 2.7:1 on white, and
;; vivendi-tinted's paren-match background is 4.3:1 under white text.
(check-theme 'modus-operandi '(divider . 2.5))
(check-theme 'modus-vivendi-tinted '(show-paren-match . 4.2))

(load-theme 'modus-vivendi-tinted)
(test-equal "vivendi-tinted: background" "#0d0e1c" (face-attribute 'default 'background))
(test-equal "vivendi-tinted: cursor" "#ff66ff" (face-attribute 'cursor 'background))
(load-theme 'modus-operandi)
(test-equal "operandi: keyword" "#531ab6" (face-attribute 'font-lock-keyword-face 'foreground))
(test-equal "operandi: mode line" "#c8c8c8" (face-attribute 'mode-line 'background))

;; ---- loading ----
(load-theme 'profane-light)
((command-procedure 'toggle-theme))
(test-eq "toggle-theme: light to dark" 'profane-dark (current-theme))
((command-procedure 'toggle-theme))
(test-eq "toggle-theme: dark to light" 'profane-light (current-theme))

(define loaded '())
(add-hook! 'after-load-theme-hook (lambda (name) (set! loaded (cons name loaded))))
(load-theme 'profane-light)
(test-eq "current theme" 'profane-light (current-theme))
(test-equal "hook ran" '(profane-light) loaded)
(test-equal "faces resolved through the palette" "#ffffff" (face-attribute 'default 'background))
(test-eq "weight from the theme" 'bold (face-attribute 'line-number-current-line 'weight))

(define-theme 'test-theme
  '((appearance . dark)
    (palette (bg . "#101010") (fg . "#f0f0f0") (accent . system-accent) (warn . accent))
    (tokens (spacing (m . 9)) (line-height . 1.2))
    (faces (default (foreground . fg) (background . bg))
           (warning (foreground . warn)))))
(set-face-attribute! 'link 'foreground "#123456")
(load-theme 'test-theme)
(test-equal "palette role references" (theme-color 'accent) (face-attribute 'warning 'foreground))
(system-accent-changed! "#ff00aa")
(test-equal "system accent reloads" "#ff00aa" (face-attribute 'warning 'foreground))
(test-eqv "token" 9 (theme-token 'spacing 'm))
(test-eqv "single-value token" 1.2 (theme-token 'line-height))
(test-eq "theme appearance" 'dark (theme-appearance 'test-theme))
(load-theme 'profane-light)
(test-assert "switching back leaves no foreign colors"
             (not (equal? "#ff00aa" (face-attribute 'warning 'foreground))))
(test-equal "and resets faces the other theme changed" (face-attribute 'link 'foreground)
            (theme-color 'blue))
(test-error "unknown theme" #t (load-theme 'no-such-theme))

;; ---- following macOS ----
(appearance-changed! 'dark)
(test-eq "dark mode loads the dark theme" 'profane-dark (current-theme))
(appearance-changed! 'light)
(test-eq "and back" 'profane-light (current-theme))
(var-set! 'theme-follows-appearance #f)
(appearance-changed! 'dark)
(test-eq "can be turned off" 'profane-light (current-theme))
(var-set! 'theme-follows-appearance #t)

;; ---- typography and ui styles ----
(test-equal "variable-pitch uses the UI font" "system-ui" (face-attribute 'variable-pitch 'family))
(load-theme 'profane-dark)
(test-equal "themes leave typography alone" "system-ui" (face-attribute 'variable-pitch 'family))
(ui-style 'rich)
(test-eq "rich preset" #t (var-ref 'ui-popup-shadow))
(test-eqv "rich fringes" 8 (var-ref 'ui-fringe-width))
(ui-style 'minimal)
(test-eq "minimal preset" #f (var-ref 'ui-popup-shadow))
(test-eqv "minimal 1pt fringes" 1 (var-ref 'ui-fringe-width))
(test-eq "current style" 'minimal (current-ui-style))

(test-end "theme")
(test-exit)
