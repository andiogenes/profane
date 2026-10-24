;;; (profane search) — searching the project: consult-ripgrep (M-g s r) and consult-find
;;; (M-g s f), after Emacs's consult. Unstable API (plan §10).
;;;
;;; Both read a query in the minibuffer and show results as they arrive from a child process
;;; (ripgrep, fd or find; see (profane process)): each change of the input restarts the search
;;; (after search-debounce-ms, and not below search-min-input characters). The input is QUERY, or
;;; "#QUERY#FILTER": QUERY goes to the program, FILTER (words, any order) narrows what came back
;;; without searching again. ripgrep results are "file:line:text", with a preview that shows the
;;; match in the window and puts it back on C-g. RET jumps there, leaving the mark where point was.
;;; With a prefix argument they ask for the directory to search; otherwise it is the project root
;;; (the nearest directory with a .git, else the buffer's directory).
;;;
;;; ripgrep is required. find-file listing uses fd when it is installed (it skips what .gitignore
;;; skips and hidden files, unlike Emacs's find), else the system find.

(library (profane search)
  (export project-root find-command)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane command-loop)
          (profane minibuffer) (profane files) (profane process) (profane async) (profane var))

  (defvar ripgrep-args
    '("--null" "--line-buffered" "--color=never" "--max-columns=1000" "--path-separator" "/"
      "--smart-case" "--no-heading" "--with-filename" "--line-number" "--column" "--search-zip")
    "Arguments of consult-ripgrep's rg (consult's defaults, plus --column).")
  (defvar fd-args '("--color=never" "--full-path" "--fixed-strings")
    "Arguments of consult-find's fd, before the pattern.")
  (defvar search-use-fd #t "Whether consult-find uses fd when it is installed (else find).")
  (defvar search-max-results 5000 "Results kept from one search; the program is stopped at this many.")
  (defvar search-min-input 3 "Characters of query needed before searching.")
  (defvar search-debounce-ms 150 "Wait for typing to pause this long before (re)starting a search.")

  ;; ---- the project ----

  (define (parent-directory d)
    (let loop ([i (- (string-length d) 1)])
      (cond [(< i 0) ""] [(char=? (string-ref d i) #\/) (substring d 0 i)] [else (loop (- i 1))])))

  ;; The nearest directory at or above DIR holding a .git, with a trailing slash; DIR itself if none.
  (define (project-root dir)
    (let ([start (expand-file-name dir)])
      (let loop ([d (let ([s (expand-file-name dir)])
                      (if (and (> (string-length s) 1) (directory-name? s))
                          (substring s 0 (- (string-length s) 1))
                          s))])
        (cond [(file-exists? (string-append d "/.git")) (file-name-as-directory d)]
              [(string=? d "") (file-name-as-directory start)]
              [else (loop (parent-directory d))]))))

  ;; "#query#filter" -> query and filter; anything else is all query.
  (define (split-input input)
    (let ([n (string-length input)])
      (if (and (> n 0) (char=? (string-ref input 0) #\#))
          (let loop ([i 1])
            (cond [(= i n) (values (substring input 1 n) "")]
                  [(char=? (string-ref input i) #\#) (values (substring input 1 i) (substring input (+ i 1) n))]
                  [else (loop (+ i 1))]))
          (values input ""))))

  (define (words s)
    (let loop ([cs (string->list s)] [cur '()] [out '()])
      (define (flush) (if (null? cur) out (cons (list->string (reverse cur)) out)))
      (cond [(null? cs) (reverse (flush))]
            [(char=? (car cs) #\space) (loop (cdr cs) '() (flush))]
            [else (loop (cdr cs) (cons (car cs) cur) out)])))

  ;; ---- a search source: what the minibuffer asks for candidates ----
  ;; START is (lambda (query line! finished!) process): it starts the program, calls (line! text)
  ;; for each line of its output and (finished! exit-code stderr) at the end. The source's
  ;; procedure answers with what has arrived, filtered; more arriving updates the minibuffer.

  (define-record-type source
    (fields start (mutable query) (mutable results) (mutable count) (mutable process)
            (mutable timer) (mutable generation) (mutable stopped) (mutable update-pending)))

  (define (make-search-source start)
    (make-source start #f '() 0 #f #f 0 #f #f))

  (define (stop-process! src)
    (when (source-timer src) (async-cancel! (source-timer src)) (source-timer-set! src #f))
    (when (and (source-process src) (process-live? (source-process src)))
      (kill-process (source-process src)))
    (source-process-set! src #f))

  (define (source-stop! src)
    (source-stopped-set! src #t)
    (stop-process! src))

  (define (request-update! src)
    (unless (or (source-update-pending src) (source-stopped src))
      (source-update-pending-set! src #t)
      (async-after 30 (lambda ()
                        (source-update-pending-set! src #f)
                        (unless (source-stopped src) (minibuffer-update!))))))

  (define (add-result! src text)
    (when (< (source-count src) (var-ref 'search-max-results))
      (source-results-set! src (cons text (source-results src)))
      (source-count-set! src (+ 1 (source-count src)))
      (when (= (source-count src) (var-ref 'search-max-results))
        (stop-process! src))))

  (define (begin-search! src query)
    (stop-process! src)
    (let ([gen (+ 1 (source-generation src))])
      (source-generation-set! src gen)
      (source-results-set! src '())
      (source-count-set! src 0)
      (when (>= (string-length query) (var-ref 'search-min-input))
        (let ([launch
               (lambda ()
                 (source-timer-set! src #f)
                 (unless (source-stopped src)
                   (source-process-set!
                    src
                    ((source-start src) query
                     (lambda (text) (when (= gen (source-generation src)) (add-result! src text) (request-update! src)))
                     (lambda (code stderr)
                       (when (= gen (source-generation src))
                         (when (and (>= code 2) (= 0 (source-count src)))
                           (add-result! src (format "[~a]" (first-line (if (string=? stderr "") "search failed" stderr)))))
                         (request-update! src)))))))]
              [ms (var-ref 'search-debounce-ms)])
          (if (<= ms 0)
              (launch)
              (source-timer-set! src (async-after ms launch)))))))

  (define (first-line s)
    (let loop ([i 0])
      (cond [(= i (string-length s)) s] [(char=? (string-ref s i) #\newline) (substring s 0 i)] [else (loop (+ i 1))])))

  ;; The collection procedure for completing-read.
  (define (source-procedure src)
    (lambda (input)
      (let-values ([(query needle) (split-input input)])
        (unless (equal? query (source-query src))
          (source-query-set! src query)
          (begin-search! src query))
        (let ([all (reverse (source-results src))])
          (if (string=? (string-trim needle) "")
              all
              (filter (lambda (c) (completion-match? needle c)) all))))))

  (define (string-trim s)
    (let* ([n (string-length s)]
           [a (let loop ([i 0]) (if (and (< i n) (char=? (string-ref s i) #\space)) (loop (+ i 1)) i))]
           [b (let loop ([i n]) (if (and (> i a) (char=? (string-ref s (- i 1)) #\space)) (loop (- i 1)) i))])
      (substring s a b)))

  ;; Runs ARGV in DIR, splitting stdout into lines for LINE! and reporting the end.
  (define (start-lines argv dir line! finished!)
    (let ([pending ""] [stderr (open-output-string)])
      (let ([p (start-process
                (car argv) argv
                `((cwd . ,dir)
                  (filter . ,(lambda (p s)
                               (let loop ([text (string-append pending s)])
                                 (let ([nl (let find ([i 0])
                                             (cond [(= i (string-length text)) #f]
                                                   [(char=? (string-ref text i) #\newline) i]
                                                   [else (find (+ i 1))]))])
                                   (if nl
                                       (begin (line! (substring text 0 nl))
                                              (loop (substring text (+ nl 1) (string-length text))))
                                       (set! pending text))))))
                  (stderr-filter . ,(lambda (p s) (put-string stderr s)))
                  (sentinel . ,(lambda (p event)
                                 (unless (string=? pending "") (line! pending) (set! pending ""))
                                 (finished! (if (eq? (process-status p) 'signal) -1 (process-exit-status p))
                                            (get-output-string stderr))))))])
        (process-send-eof p) ; ripgrep searches stdin when it is not a terminal and has no path
        p)))

  (define (strip-dot-slash s)
    (if (and (>= (string-length s) 2) (string=? (substring s 0 2) "./")) (substring s 2 (string-length s)) s))

  ;; ---- where to search ----

  ;; Calls (K dir) with the directory to search: the project root, or one read from the user
  ;; with a prefix argument.
  (define (with-search-directory prompt k)
    (if (current-prefix-arg)
        (read-file-name prompt (lambda (d) (k (file-name-as-directory d))))
        (k (project-root (default-directory)))))

  ;; ---- consult-ripgrep ----

  (define (buffer-visiting path)
    (find (lambda (b) (equal? (buffer-file-name b) path)) (buffer-list)))

  ;; The position of byte column COL (1-based, as rg counts) on line LINE (1-based) of B.
  (define (match-position b line col)
    (with-current-buffer b
      (goto-char 0)
      (forward-line (- line 1))
      (let* ([bol (point)]
             [bytes (string->utf8 (buffer-substring bol (line-end-position)))]
             [k (max 0 (min (- col 1) (bytevector-length bytes)))]
             [head (make-bytevector k)])
        (bytevector-copy! bytes 0 head 0 k)
        (+ bol (string-length (utf8->string head))))))

  (define (parse-rg-line line)
    ;; "path\0LINE:COL:text" -> (candidate path line col)
    (let ([nul (let find ([i 0])
                 (cond [(= i (string-length line)) #f] [(char=? (string-ref line i) #\nul) i] [else (find (+ i 1))]))])
      (and nul
           (let* ([path (strip-dot-slash (substring line 0 nul))]
                  [rest (substring line (+ nul 1) (string-length line))]
                  [c1 (let find ([i 0]) (cond [(= i (string-length rest)) #f] [(char=? (string-ref rest i) #\:) i] [else (find (+ i 1))]))]
                  [c2 (and c1 (let find ([i (+ c1 1)]) (cond [(= i (string-length rest)) #f] [(char=? (string-ref rest i) #\:) i] [else (find (+ i 1))])))])
             (and c2
                  (let* ([ln (string->number (substring rest 0 c1))]
                         [col (string->number (substring rest (+ c1 1) c2))]
                         [text (substring rest (+ c2 1) (string-length rest))]
                         [text (if (> (string-length text) 300) (substring text 0 300) text)])
                    (and ln col (list (string-append path ":" (number->string ln) ":" text) path ln col))))))))

  (define-command (consult-ripgrep)
    "Search the project with ripgrep as you type, with a preview of the match."
    (let ([rg (executable-find "rg")])
      (unless rg (error 'consult-ripgrep "ripgrep (rg) is not installed (brew install ripgrep)"))
      (with-search-directory "Ripgrep in directory: " (lambda (dir) (ripgrep-in dir rg)))))

  (define (ripgrep-in dir rg)
    (let* ([w (selected-window)] [orig-buffer (window-buffer w)] [orig-point (window-point w)]
           [table (make-hashtable equal-hash equal?)] ; candidate -> (path line col)
           [opened '()]                   ; buffers created to preview a match
           [src (make-search-source
                 (lambda (query line! finished!)
                   (start-lines (append (list rg) (var-ref 'ripgrep-args) (list "-e" query "."))
                                dir
                                (lambda (text)
                                  (let ([m (parse-rg-line text)])
                                    (when m
                                      (hashtable-set! table (car m) (cdr m))
                                      (line! (car m)))))
                                finished!)))]
           [visit (lambda (path)
                    (let* ([full (expand-file-name path dir)] [existing (buffer-visiting full)]
                           [b (find-file-noselect full)])
                      (unless (or existing (memq b opened)) (set! opened (cons b opened)))
                      b))]
           [restore! (lambda ()
                       (when (and (window-live? w) (buffer-live? orig-buffer))
                         (set-window-buffer! w orig-buffer)
                         (set-window-point! w orig-point)))])
      (completing-read
       "Ripgrep: " (source-procedure src)
       (lambda (cand)
         (source-stop! src)
         (let ([m (hashtable-ref table cand #f)])
           (restore!)
           (cond
             [(not m) (for-each kill-buffer opened) (message "No match: ~a" cand)]
             [else
              (let ([b (visit (car m))])
                (for-each (lambda (o) (unless (eq? o b) (kill-buffer o))) opened)
                (when (window-live? w) (with-current-buffer orig-buffer (set-mark! (point))))
                (switch-to-buffer b)
                (goto-char (match-position b (cadr m) (caddr m))))])))
       'raw #t 'history 'ripgrep
       'preview (lambda (cand)
                  (let ([m (hashtable-ref table cand #f)] [cur (current-buffer)])
                    (when (and m (window-live? w))
                      (let ([b (visit (car m))])
                        (set-window-buffer! w b)
                        (set-window-point! w (match-position b (cadr m) (caddr m)))))
                    (set-buffer cur)))
       'quit (lambda ()
               (source-stop! src)
               (restore!)
               (for-each kill-buffer opened)))))

  ;; ---- consult-find ----

  (define (glob-escape w)
    (let ([out (open-output-string)])
      (string-for-each (lambda (c) (when (memv c '(#\\ #\* #\? #\[)) (put-char out #\\)) (put-char out c)) w)
      (get-output-string out)))

  (define (find-command query)
    ;; the program and arguments listing paths whose names contain every word of QUERY
    (let ([ws (words query)] [fd (and (var-ref 'search-use-fd) (executable-find "fd"))])
      (if fd
          (append (list fd) (var-ref 'fd-args)
                  (map (lambda (w) (string-append "--and=" w)) (cdr ws))
                  (list "--" (car ws)))
          (append (list (or (executable-find "find") "find") "." "-name" ".git" "-prune" "-o")
                  (apply append (map (lambda (w) (list "-ipath" (string-append "*" (glob-escape w) "*"))) ws))
                  (list "-print")))))

  (define-command (consult-find)
    "Find files and directories by the words in their path, as you type."
    (with-search-directory "Find in directory: "
      (lambda (dir)
        (let ([src (make-search-source
                    (lambda (query line! finished!)
                      (if (null? (words query))
                          #f
                          (start-lines (find-command query) dir
                                       (lambda (text) (line! (strip-dot-slash text)))
                                       finished!))))])
          (completing-read
           "Find: " (source-procedure src)
           (lambda (cand)
             (source-stop! src)
             (let ([path (expand-file-name cand dir)])
               (if (file-directory? path)
                   (message "~a is a directory (dired is not available yet)" path)
                   (switch-to-buffer (find-file-noselect path)))))
           'raw #t 'history 'find
           'quit (lambda () (source-stop! src))))))))
