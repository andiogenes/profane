;;; The owner's keybindings and settings, ported from their Emacs init.el (plan §2). Loaded at
;;; startup by boot.ss, before the user's own init.ss in ~/Library/Application Support/profane.
;;; Everything here is a plain call into the public API, so it doubles as an example.
;;; Evaluated in the interaction environment, where (profane keymap) and friends are imported.

;;; Previous / next buffer (M-[ and M-] work in GUI Emacs only; profane is always GUI).
(define-key! (global-map) "M-[" 'previous-buffer)
(define-key! (global-map) "M-]" 'next-buffer)

;;; ace-window on M-o.
(define-key! (global-map) "M-o" 'ace-window)

;;; One key for both ends of the buffer, and of a completion list.
(define-key! (global-map) "C-M-v" 'edge-of-buffer)

;;; avy: jump to a visible word by label.
(define-key! (global-map) "C-x C-j" 'avy-goto-word-1)

;;; consult: buffers with preview, the kill ring. (imenu, ripgrep search and xref wait for
;;; modes and tree-sitter; M-g t neotree for its package.)
(define-key! (global-map) "M-g b" 'consult-buffer)
(define-key! (global-map) "M-g y" 'consult-yank-from-kill-ring)

;;; vertico-count 5 is the default already; show-paren-delay 0 is how show-paren works here.
(var-set! 'vertico-count 5)
