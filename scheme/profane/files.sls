;;; (profane files) — file names: expanding and abbreviating them, reading one in the minibuffer,
;;; and the commands that visit and save files (C-x C-f, C-x C-s, C-x C-w). Unstable API
;;; (plan §10).
;;;
;;;   (read-file-name prompt k [initial])   k receives an absolute path
;;;
;;; The minibuffer starts at the current buffer's directory (`default-directory`, buffer-local;
;;; else the directory of its file; else ~/). Candidates are the entries of the directory typed
;;; so far, shown by name (directories end in "/"); the ones containing the typed name come
;;; first when they start with it, then directories before files, then alphabetically. As with
;;; vertico-directory: RET on a directory goes into it, RET on a file (or on a path nothing
;;; matches) finishes, DEL right after a "/" deletes the whole component and M-DEL deletes a
;;; component. With the input ending in "/" nothing is selected, so RET finishes with that
;;; directory (find-file then says dired is not there yet) and C-n selects the first entry.

(library (profane files)
  (export expand-file-name abbreviate-file-name file-name-directory file-name-nondirectory
          file-name-as-directory directory-name? default-directory read-file-name
          directory-entries set-directory-handler! visit-directory)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane keymap) (profane minibuffer) (profane var))

  (defvar default-directory #f
    "Directory relative file names are taken from in this buffer (#f: the file's, else ~/)."
    '(local))

  ;; ---- names ----

  (define (home) (or (getenv "HOME") "/"))

  (define (directory-name? s)
    (and (> (string-length s) 0) (char=? (string-ref s (- (string-length s) 1)) #\/)))

  (define (file-name-as-directory s) (if (directory-name? s) s (string-append s "/")))

  ;; "/a/b/c.txt" -> "/a/b/"; no slash: "".
  (define (file-name-directory path)
    (let loop ([i (- (string-length path) 1)])
      (cond [(< i 0) ""]
            [(char=? (string-ref path i) #\/) (substring path 0 (+ i 1))]
            [else (loop (- i 1))])))

  (define (split-path s)
    (let loop ([cs (string->list s)] [cur '()] [out '()])
      (cond [(null? cs) (reverse (cons (list->string (reverse cur)) out))]
            [(char=? (car cs) #\/) (loop (cdr cs) '() (cons (list->string (reverse cur)) out))]
            [else (loop (cdr cs) (cons (car cs) cur) out)])))

  ;; An absolute path for NAME: ~ is the home directory, relative names are taken from DIR
  ;; (default: default-directory), "." and ".." and repeated slashes are resolved. A trailing
  ;; slash is kept.
  (define expand-file-name
    (case-lambda
      [(name) (expand-file-name name (default-directory))]
      [(name dir)
       (let* ([full (cond [(and (> (string-length name) 0) (char=? (string-ref name 0) #\~)
                                (or (= (string-length name) 1) (char=? (string-ref name 1) #\/)))
                           (string-append (home) (substring name 1 (string-length name)))]
                          [(and (> (string-length name) 0) (char=? (string-ref name 0) #\/)) name]
                          [else (string-append (file-name-as-directory (expand-file-name dir "/")) name)])]
              [parts (let loop ([ps (split-path full)] [acc '()])
                       (cond [(null? ps) (reverse acc)]
                             [(member (car ps) '("" ".")) (loop (cdr ps) acc)]
                             [(string=? (car ps) "..") (loop (cdr ps) (if (null? acc) acc (cdr acc)))]
                             [else (loop (cdr ps) (cons (car ps) acc))]))]
              [joined (apply string-append (map (lambda (p) (string-append "/" p)) parts))])
         (cond [(null? parts) "/"]
               [(directory-name? name) (string-append joined "/")]
               [else joined]))]))

  ;; /Users/me/x -> ~/x
  (define (abbreviate-file-name path)
    (let ([h (let ([h (home)]) (if (directory-name? h) (substring h 0 (- (string-length h) 1)) h))])
      (cond [(string=? path h) "~"]
            [(and (> (string-length path) (string-length h))
                  (string=? (substring path 0 (string-length h)) h)
                  (char=? (string-ref path (string-length h)) #\/))
             (string-append "~" (substring path (string-length h) (string-length path)))]
            [else path])))

  (define (default-directory)
    (file-name-as-directory
     (or (var-ref 'default-directory)
         (let ([f (buffer-file-name (current-buffer))]) (and f (file-name-directory f)))
         (home))))

  ;; As in Emacs, "//" in a typed name starts over at the root and "/~" at the home directory:
  ;; typing an absolute path after the proposed directory replaces it.
  (define (restart-at-root input)
    (let ([n (string-length input)])
      (let loop ([i (- n 1)])
        (cond [(< i 1) input]
              [(and (char=? (string-ref input i) #\/) (char=? (string-ref input (- i 1)) #\/))
               (substring input i n)]
              [(and (char=? (string-ref input i) #\~) (char=? (string-ref input (- i 1)) #\/))
               (substring input i n)]
              [else (loop (- i 1))]))))

  ;; ---- listing ----

  ;; The entries of DIR (a path), directories with a trailing "/", sorted by name; '() when it
  ;; cannot be read.
  (define (directory-entries dir)
    (guard (c [else '()])
      (let ([names (list-sort string<? (directory-list dir))])
        (map (lambda (n)
               (if (file-directory? (string-append (file-name-as-directory dir) n))
                   (string-append n "/")
                   n))
             names))))

  (define (starts-with? s prefix ci?)
    (and (<= (string-length prefix) (string-length s))
         (let ([a (substring s 0 (string-length prefix))])
           (if ci? (string-ci=? a prefix) (string=? a prefix)))))

  (define (contains? s sub ci?)
    (let ([n (string-length s)] [k (string-length sub)])
      (let loop ([i 0])
        (and (<= (+ i k) n)
             (or (let ([a (substring s i (+ i k))]) (if ci? (string-ci=? a sub) (string=? a sub)))
                 (loop (+ i 1)))))))

  ;; Candidates for the input typed so far: the typed directory part plus each matching entry.
  (define (file-candidates input*)
    (let* ([input (restart-at-root input*)]
           [typed-dir (file-name-directory input)]
           [name (substring input (string-length typed-dir) (string-length input))]
           [dir (expand-file-name (if (string=? typed-dir "") "." typed-dir))]
           [ci? (string=? name (string-downcase name))]
           [entries (filter (lambda (e) (contains? e name ci?)) (directory-entries dir))]
           [rank (lambda (e) (list (if (starts-with? e name ci?) 0 1) (if (directory-name? e) 0 1)))]
           [before? (lambda (a b)
                      (let ([ra (rank a)] [rb (rank b)])
                        (cond [(< (car ra) (car rb)) #t] [(> (car ra) (car rb)) #f]
                              [(< (cadr ra) (cadr rb)) #t] [(> (cadr ra) (cadr rb)) #f]
                              [else (string<? a b)])))])
      (map (lambda (e) (string-append typed-dir e)) (list-sort before? entries))))

  ;; "~/a/b/" -> "b/", "~/a/c.txt" -> "c.txt"
  (define (shown candidate)
    (let* ([trimmed (if (directory-name? candidate) (substring candidate 0 (- (string-length candidate) 1)) candidate)]
           [name (file-name-nondirectory trimmed)])
      (if (directory-name? candidate) (string-append name "/") name)))

  (define read-file-name
    (case-lambda
      [(prompt k) (read-file-name prompt k (abbreviate-file-name (default-directory)))]
      [(prompt k initial)
       (let ([dir (default-directory)])
         (completing-read prompt file-candidates
                          (lambda (text) (k (expand-file-name (restart-at-root text) dir)))
                          'initial initial 'raw #t 'files #t 'display shown 'history 'file-name
                          ;; with no name typed yet, RET finishes with the directory itself
                          'preselect (lambda (cands)
                                       (let ([input (minibuffer-contents)])
                                         (if (or (string=? input "") (directory-name? input)) #f 0)))))]))

  ;; What visiting a directory does: (profane dired) installs itself here (it needs this library
  ;; for reading file names, so it cannot be imported). Until then a message says there is none.
  (define directory-handler
    (lambda (path) (message "~a is a directory (dired is not available)" path)))
  (define (set-directory-handler! proc) (set! directory-handler proc))
  (define (visit-directory path) (directory-handler path))

  ;; ---- commands ----

  (define-command (find-file)
    "Visit a file chosen in the minibuffer (a new buffer if it does not exist yet)."
    (read-file-name "Find file: "
                    (lambda (path)
                      (cond
                        [(or (directory-name? path) (file-directory? path)) (visit-directory path)]
                        [else (switch-to-buffer (find-file-noselect path))]))))

  (define-command (save-buffer)
    "Save the current buffer to its file; ask for one if it has none."
    (cond
      [(buffer-file-name (current-buffer))
       => (lambda (path)
            (cond [(buffer-modified?) (save-buffer) (message "Wrote ~a" path)]
                  [else (message "(No changes need to be saved)")]))]
      [else ((command-procedure 'write-file))]))

  (define-command (write-file)
    "Write the current buffer to a file chosen in the minibuffer, and visit it."
    (let ([b (current-buffer)])
      (read-file-name "Write file: "
                      (lambda (path)
                        (with-current-buffer b
                          (set-visited-file-name! path)
                          (save-buffer)
                          (message "Wrote ~a" path))))))

  (define bindings
    (for-each (lambda (b) (define-key! (global-map) (car b) (cdr b)))
              '(("C-x C-f" . find-file) ("C-x C-s" . save-buffer) ("C-x C-w" . write-file)))))
