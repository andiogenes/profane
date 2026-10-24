;;; (profane sidebar) — a file tree in a side window, after neotree. Unstable API (plan §10).
;;;
;;; M-g t (sidebar-toggle) shows the project's directory tree in a window along the left edge of
;;; the frame, or hides it. The window is dedicated: buffers you switch to open in the other
;;; windows. In the tree:
;;;
;;;   RET   open the file in the main window, or expand/collapse the directory
;;;   TAB   expand/collapse the directory         n p   move              g   refresh
;;;   H     show/hide hidden and git-ignored files (hidden by default)
;;;   U     show the parent directory as the root   C   make the directory at point the root
;;;   d     open the directory in dired             q   hide the tree
;;;
;;; The root is the project root (the nearest .git, else the buffer's directory). Files git ignores
;;; are found with one `git ls-files` call when the tree is opened or refreshed.

(library (profane sidebar)
  (export sidebar-window)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane keymap)
          (profane mode) (profane var) (profane face) (profane display) (profane files)
          (profane fs) (profane process) (profane async) (profane search) (profane dired))

  (defvar sidebar-width 30 "Columns of the sidebar window.")
  (defvar sidebar-show-hidden #f "Show dotfiles and files git ignores in the sidebar.")
  (defvar sidebar-root #f "The directory a sidebar buffer shows (with a trailing slash)." '(local))
  (defvar sidebar-expanded #f "Expanded directories of a sidebar buffer (a table: path -> #t)." '(local))
  (defvar sidebar-nodes (vector) "The entries of a sidebar buffer, one per line after the first." '(local))
  (defvar sidebar-ignored #f "Paths git ignores, relative to the root (a table), or #f." '(local))

  (define sidebar-faces
    (begin
      (define-face 'sidebar-root '((inherit . dired-header)) "The tree's root directory.")
      (define-face 'sidebar-directory '((inherit . dired-directory)) "Directories in the sidebar.")
      #t))

  (define-major-mode sidebar-mode fundamental-mode "Sidebar" "Major mode of the file tree.")

  (define buffer-name* "*Sidebar*")

  (define (sidebar-window)
    (let ([b (get-buffer buffer-name*)])
      (and b (find (lambda (w) (eq? (window-buffer w) b)) (window-list)))))

  ;; The window files open in: the one the sidebar was opened from, while it lives.
  (define main-window #f)
  (define (pick-main-window)
    (let ([f (selected-frame)])
      (if (and main-window (window-live? main-window) (not (window-dedicated? main-window))
               (memq main-window (window-list f)))
          main-window
          (or (find (lambda (w) (not (or (window-dedicated? w) (window-minibuffer? w)))) (window-list f))
              (error 'sidebar "no window to open the file in")))))

  ;; ---- the tree ----

  (define-record-type node (fields name path depth dir?))

  (define (join dir name) (if (directory-name? dir) (string-append dir name) (string-append dir "/" name)))

  (define (dotfile? name) (and (> (string-length name) 0) (char=? (string-ref name 0) #\.)))

  (define (entries-of dir)
    (let* ([names (directory-contents dir)]
           [items (map (lambda (n)
                         (let* ([path (join dir n)] [info (file-attributes path #t)])
                           (list n path (and info (file-info-directory? info)))))
                       names)])
      (list-sort (lambda (a b)
                   (cond [(and (caddr a) (not (caddr b))) #t]
                         [(and (caddr b) (not (caddr a))) #f]
                         [else (let ([x (car a)] [y (car b)])
                                 (if (string-ci=? x y) (string<? x y) (string-ci<? x y)))]))
                 items)))

  (define (relative-to root path)
    (substring path (string-length root) (string-length path)))

  (define (build-nodes root expanded ignored show-hidden)
    (let walk ([dir root] [depth 0])
      (apply append
             (map (lambda (e)
                    (let* ([name (car e)] [path (cadr e)] [dir? (caddr e)]
                           [rel (string-append (relative-to root path) (if dir? "/" ""))])
                      (if (and (not show-hidden)
                               (or (dotfile? name) (and ignored (hashtable-contains? ignored rel))))
                          '()
                          (cons (make-node name path depth dir?)
                                (if (and dir? (hashtable-contains? expanded path))
                                    (walk path (+ depth 1))
                                    '())))))
                  (entries-of dir)))))

  (define (node-at index)
    (let ([v (var-ref 'sidebar-nodes)]) (and (>= index 0) (< index (vector-length v)) (vector-ref v index))))
  (define (point-index) (- (line-number-at-pos) 2))
  (define (this-node) (node-at (point-index)))
  (define (this-node!) (or (this-node) (error 'sidebar "no file on this line")))

  (define (root-title root)
    (let ([trimmed (if (and (> (string-length root) 1) (directory-name? root))
                       (substring root 0 (- (string-length root) 1))
                       root)])
      (string-append (if (string=? trimmed "/") "/" (file-name-nondirectory trimmed)) "/")))

  (define (goto-index! i)
    (let ([n (vector-length (var-ref 'sidebar-nodes))])
      (goto-char 0)
      (forward-line (+ 1 (max 0 (min i (- n 1)))))
      (when (= n 0) (goto-char 0))))

  (define (draw!)
    (let* ([root (var-ref 'sidebar-root)]
           [keep (let ([n (this-node)]) (and n (node-path n)))]
           [nodes (build-nodes root (var-ref 'sidebar-expanded) (var-ref 'sidebar-ignored)
                               (var-ref 'sidebar-show-hidden))])
      (var-set! 'sidebar-nodes (list->vector nodes))
      (with-inhibit-read-only
       (lambda ()
         (erase-buffer)
         (let ([from (point)])
           (insert (root-title root))
           (put-text-property from (point) 'face 'sidebar-root)
           (insert "\n"))
         (for-each
          (lambda (n)
            (let ([from (point)] [indent (* 2 (node-depth n))])
              (insert (make-string indent #\space)
                      (cond [(not (node-dir? n)) "  "]
                            [(hashtable-contains? (var-ref 'sidebar-expanded) (node-path n)) "\x25BE; "]
                            [else "\x25B8; "])
                      (node-name n))
              (when (node-dir? n)
                (put-text-property (+ from indent 2) (point) 'face 'sidebar-directory))
              (insert "\n")))
          nodes)))
      (set-buffer-unmodified!)
      (let ([i (and keep (let loop ([i 0] [ns nodes])
                           (cond [(null? ns) #f] [(string=? (node-path (car ns)) keep) i] [else (loop (+ i 1) (cdr ns))])))])
        (goto-index! (or i 0)))))

  ;; The paths under ROOT that git ignores, as a table, or #f (not a repository, no git).
  (define (fetch-ignored root)
    (let ([git (executable-find "git")])
      (and git
           (let ([r (await (run-process (list git "-C" root "ls-files" "--others" "--ignored"
                                              "--exclude-standard" "--directory" "-z")))])
             (and (= (car r) 0)
                  (let ([table (make-hashtable string-hash string=?)])
                    (let loop ([cs (string->list (cadr r))] [cur '()])
                      (cond [(null? cs) (unless (null? cur) (hashtable-set! table (list->string (reverse cur)) #t))]
                            [(char=? (car cs) #\nul)
                             (unless (null? cur) (hashtable-set! table (list->string (reverse cur)) #t))
                             (loop (cdr cs) '())]
                            [else (loop (cdr cs) (cons (car cs) cur))]))
                    table))))))

  ;; The sidebar buffer, in its mode, before any window shows it (a window reads the buffer's
  ;; display-line-numbers when it gets it).
  (define (prepare-buffer!)
    (let ([b (get-buffer-create buffer-name*)])
      (with-current-buffer b
        (unless (eq? (var-ref 'major-mode) 'sidebar-mode)
          (set-major-mode! 'sidebar-mode)
          (var-set! 'display-line-numbers #f)
          (var-set! 'sidebar-expanded (make-hashtable string-hash string=?))
          (buffer-disable-undo)
          (set-buffer-read-only! #t)))
      b))

  ;; Shows ROOT in the sidebar buffer (reading git's ignore list first, which may take a moment:
  ;; the command waits without blocking the editor). Expanded directories are remembered, so going
  ;; up and back down keeps the tree as it was.
  (define (load-root! b root)
    (let ([ignored (fetch-ignored root)])
      (with-current-buffer b
        (var-set! 'sidebar-root root)
        (var-set! 'sidebar-ignored ignored)
        (draw!))))

  (define (open-sidebar!)
    (let* ([root (project-root (default-directory))]
           [b (prepare-buffer!)]
           [from (selected-window)])
      (set! main-window from)
      (let ([existing (sidebar-window)])
        (cond
          [existing (select-window existing)]
          [else
           (let ([w (add-side-window (selected-frame) b 'left (var-ref 'sidebar-width))])
             (set-window-dedicated! w #t)
             (select-window w))]))
      (load-root! b root)))

  (define (close-sidebar!)
    (let ([w (sidebar-window)])
      (when w
        (let ([sole (null? (cdr (filter (lambda (x) (not (window-minibuffer? x))) (window-list))))])
          (unless sole
            (set-window-dedicated! w #f)
            (delete-window w))))))

  (define-command (sidebar-toggle)
    "Show the project's file tree in a side window, or hide it."
    (if (sidebar-window) (close-sidebar!) (open-sidebar!)))

  ;; ---- in the tree ----

  (define (toggle-dir! n)
    (let ([table (var-ref 'sidebar-expanded)])
      (if (hashtable-contains? table (node-path n))
          (hashtable-delete! table (node-path n))
          (hashtable-set! table (node-path n) #t))
      (draw!)))

  (define (open-file! n)
    (let ([w (pick-main-window)] [b (find-file-noselect (node-path n))])
      (set-window-buffer! w b)
      (select-window w)))

  (define-command (sidebar-enter)
    "Open the file at point in the main window, or expand/collapse the directory."
    (let ([n (this-node!)])
      (if (node-dir? n) (toggle-dir! n) (open-file! n))))

  (define-command (sidebar-toggle-node)
    "Expand or collapse the directory at point."
    (let ([n (this-node!)])
      (if (node-dir? n) (toggle-dir! n) (message "~a is not a directory" (node-name n)))))

  (define (move! delta)
    (let ([last (- (vector-length (var-ref 'sidebar-nodes)) 1)])
      (goto-index! (max 0 (min last (+ (point-index) delta))))))

  (define-command (sidebar-next-line) "Move to the next entry." (move! (prefix-numeric-value)))
  (define-command (sidebar-previous-line) "Move to the previous entry." (move! (- (prefix-numeric-value))))

  (define-command (sidebar-refresh)
    "Read the tree again."
    (let ([b (current-buffer)])
      (load-root! b (var-ref 'sidebar-root))
      (message "Tree refreshed")))

  (define-command (sidebar-toggle-hidden)
    "Show or hide dotfiles and files git ignores."
    (var-set! 'sidebar-show-hidden (not (var-ref 'sidebar-show-hidden)))
    (draw!)
    (message (if (var-ref 'sidebar-show-hidden) "Showing hidden files" "Hiding hidden files")))

  (define (parent-of dir)
    (file-name-as-directory (expand-file-name ".." dir)))

  (define-command (sidebar-up-root)
    "Show the parent directory as the root."
    (let ([root (var-ref 'sidebar-root)] [b (current-buffer)])
      (if (string=? (parent-of root) root)
          (message "already at the top")
          (load-root! b (parent-of root)))))

  (define-command (sidebar-set-root)
    "Make the directory at point the root."
    (let* ([n (this-node!)]
           [dir (file-name-as-directory (if (node-dir? n) (node-path n) (file-name-directory (node-path n))))])
      (load-root! (current-buffer) dir)))

  (define-command (sidebar-open-dired)
    "Open the directory at point (or the file's directory) in dired, in the main window."
    (let* ([n (this-node!)] [w (pick-main-window)])
      (select-window w)
      (dired (if (node-dir? n) (node-path n) (file-name-directory (node-path n))))))

  (define-command (sidebar-quit) "Hide the tree." (close-sidebar!))

  (define bindings
    (begin
      (for-each (lambda (b) (define-key! (mode-keymap 'sidebar-mode) (car b) (cdr b)))
                '(("RET" . sidebar-enter) ("TAB" . sidebar-toggle-node)
                  ("n" . sidebar-next-line) ("C-n" . sidebar-next-line) ("<down>" . sidebar-next-line)
                  ("p" . sidebar-previous-line) ("C-p" . sidebar-previous-line) ("<up>" . sidebar-previous-line)
                  ("g" . sidebar-refresh) ("H" . sidebar-toggle-hidden) ("U" . sidebar-up-root)
                  ("C" . sidebar-set-root) ("d" . sidebar-open-dired) ("q" . sidebar-quit)))
      #t)))
