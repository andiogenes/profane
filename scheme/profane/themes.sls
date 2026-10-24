;;; (profane themes) — the built-in themes. Unstable API (plan §10).
;;;
;;; profane-light and profane-dark: accessible high-contrast themes in the spirit of
;;; modus-operandi and modus-vivendi-tinted (plan §2), with their own palettes. Body text is
;;; above 7:1 contrast (WCAG AAA), dimmed text and comments above 4.5:1; tests check this.

(library (profane themes)
  (export builtin-themes)
  (import (chezscheme) (profane theme))

  ;; Shared by both themes; values are points unless noted.
  (define tokens
    '((spacing (xs . 2) (s . 4) (m . 8) (l . 12) (xl . 16) (xxl . 24))
      (radius (s . 4) (m . 6) (l . 10))
      ;; Shadows for raised surfaces (pop-ups, completion): blur, y offset, opacity.
      (elevation (1 (blur . 4) (y . 1) (alpha . 0.12))
                 (2 (blur . 10) (y . 3) (alpha . 0.16))
                 (3 (blur . 20) (y . 6) (alpha . 0.20)))
      ;; Type scale: UI chrome in the system font (SF Pro), code in the code font.
      (type (ui-family . "system-ui") (code-family . "JetBrains Mono") (ui-size . 13)
            (small . 0.9) (title . 1.25))
      (line-height . 1.0)))

  ;; Faces in terms of palette roles (shared; each theme supplies the roles).
  (define faces
    '((default (foreground . fg) (background . bg))
      (cursor (background . cursor))
      (shadow (foreground . fg-dim))
      (line-number (foreground . fg-dim))
      (line-number-current-line (foreground . fg) (weight . bold))
      (hl-line (background . bg-hl-line))
      (highlight (background . bg-highlight))
      (region (background . bg-region))
      (diff-hl-insert (foreground . green))
      (diff-hl-change (foreground . blue))
      (diff-hl-delete (foreground . red))
      (show-paren-match (background . bg-paren-match))
      (show-paren-mismatch (background . bg-paren-mismatch))
      (vertical-border (foreground . border))
      (fringe (foreground . fg-dim))
      (mode-line (foreground . fg) (background . bg-mode-line))
      (mode-line-inactive (foreground . fg-dim) (background . bg-mode-line-inactive))
      (header-line (foreground . fg) (background . bg-mode-line-inactive))
      (mode-line-highlight (background . bg-highlight))
      (tab-bar (foreground . fg-dim) (background . bg-tab-bar))
      (tab-bar-tab (foreground . fg) (background . bg))
      (tab-bar-tab-inactive (foreground . fg-dim) (background . bg-tab-bar))
      (link (foreground . blue) (underline . #t))
      (error (foreground . red) (weight . bold))
      (warning (foreground . yellow) (weight . bold))
      (success (foreground . green) (weight . bold))
      (minibuffer-prompt (foreground . blue) (weight . bold))
      (git-header-label (foreground . fg-dim) (weight . bold))
      (git-branch-local (foreground . blue))
      (git-branch-remote (foreground . green))
      (git-hash (foreground . fg-dim))
      (git-diff-file-heading (foreground . fg) (weight . bold))
      (git-diff-hunk-heading (foreground . cyan))
      (git-diff-added (foreground . green))
      (git-diff-removed (foreground . red))
      (git-diff-meta (foreground . fg-dim) (slant . italic))
      (dired-header (foreground . cyan) (weight . bold))
      (dired-directory (foreground . blue) (weight . bold))
      (dired-symlink (foreground . magenta))
      (dired-mark (foreground . red) (weight . bold))
      (dired-marked (foreground . yellow) (weight . bold))
      (dired-flagged (foreground . red))
      (font-lock-comment-face (foreground . fg-dim) (slant . italic))
      (font-lock-doc-face (foreground . fg-dim) (slant . italic))
      (font-lock-string-face (foreground . blue))
      (font-lock-keyword-face (foreground . magenta) (weight . bold))
      (font-lock-builtin-face (foreground . magenta))
      (font-lock-function-name-face (foreground . red))
      (font-lock-variable-name-face (foreground . cyan))
      (font-lock-type-face (foreground . cyan) (weight . bold))
      (font-lock-constant-face (foreground . blue) (weight . bold))))

  (define (theme appearance palette)
    (list (cons 'appearance appearance) (cons 'palette palette) (cons 'tokens tokens)
          (cons 'faces faces)))

  (define builtin-themes
    (begin
      (define-theme 'profane-light
        (theme 'light
               '((bg . "#ffffff") (fg . "#000000") (fg-dim . "#595959") (cursor . fg)
                 (red . "#a10000") (green . "#005f00") (yellow . "#6b5300") (blue . "#0033b0")
                 (magenta . "#7a1b5c") (cyan . "#005a85") (accent . system-accent)
                 (bg-hl-line . "#e8edf3") (bg-highlight . "#d9e6f7") (bg-region . "#c6dbf5")
                 (bg-paren-match . "#b5d3f0") (bg-paren-mismatch . "#f4b9b9")
                 (bg-mode-line . "#c9d3e2") (bg-mode-line-inactive . "#eceff4")
                 (bg-tab-bar . "#e1e5ec") (border . "#7d8899")
                 ;; the 16 ANSI colors of terminals
                 (term-black . "#000000") (term-red . red) (term-green . green) (term-yellow . yellow)
                 (term-blue . blue) (term-magenta . magenta) (term-cyan . cyan) (term-white . "#a0a0a0")
                 (term-bright-black . "#595959") (term-bright-red . "#d04040") (term-bright-green . "#2f8f2f")
                 (term-bright-yellow . "#9a7a00") (term-bright-blue . "#3a5fd0") (term-bright-magenta . "#a84c8a")
                 (term-bright-cyan . "#2a82ad") (term-bright-white . "#d0d0d0"))))
      (define-theme 'profane-dark
        (theme 'dark
               '((bg . "#0e1220") (fg . "#ffffff") (fg-dim . "#a3a9b8") (cursor . fg)
                 (red . "#ff8a8f") (green . "#73d673") (yellow . "#e9c75e") (blue . "#86b6ff")
                 (magenta . "#f593e5") (cyan . "#72d9ee") (accent . system-accent)
                 (bg-hl-line . "#1c2336") (bg-highlight . "#26314b") (bg-region . "#2c3b5c")
                 (bg-paren-match . "#31466d") (bg-paren-mismatch . "#6b2b33")
                 (bg-mode-line . "#2b3654") (bg-mode-line-inactive . "#171c2c")
                 (bg-tab-bar . "#141929") (border . "#5c6888")
                 (term-black . "#555d7a") (term-red . red) (term-green . green) (term-yellow . yellow)
                 (term-blue . blue) (term-magenta . magenta) (term-cyan . cyan) (term-white . "#c8ccd8")
                 (term-bright-black . "#6b7390") (term-bright-red . "#ffb3b6") (term-bright-green . "#a0eaa0")
                 (term-bright-yellow . "#f5df9a") (term-bright-blue . "#b0d0ff") (term-bright-magenta . "#f9c0ef")
                 (term-bright-cyan . "#a0e8f5") (term-bright-white . "#ffffff"))))
      '(profane-light profane-dark)))

  ;; ---- UI style presets (plan §6): which chrome is on. minimal is the default. ----
  ;; The variables are consumed as the chrome lands (mode line and fringes with windows, M2;
  ;; pop-up shadows with canvas pop-ups, M2; scroll bars and motion M4/M8).

  (define ui-styles
    (begin
      (define-ui-style 'minimal
        '((ui-fringe-width . 1) (ui-scroll-bars . #f) (ui-popup-shadow . #f)
          (ui-motion . subtle) (ui-mode-line-style . flat)))
      (define-ui-style 'rich
        '((ui-fringe-width . 8) (ui-scroll-bars . overlay) (ui-popup-shadow . #t)
          (ui-motion . full) (ui-mode-line-style . raised)))
      #t)))
