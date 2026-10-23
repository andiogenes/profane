(import (chezscheme) (srfi :64) (profane var) (profane hook) (profane face) (profane theme)
        (profane themes) (profane display))

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

(define (check-theme name)
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
       (test-assert (format "~a: text on ~a >= 4.5:1" name f)
                    (>= (contrast fg (face-attribute f 'background)) 4.5)))
     '(hl-line highlight region show-paren-match show-paren-mismatch))
    (test-assert (format "~a: cursor stands out >= 7:1" name)
                 (>= (contrast (face-attribute 'cursor 'background) bg) 7))))

(check-theme 'profane-light)
(check-theme 'profane-dark)

;; ---- loading ----
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
