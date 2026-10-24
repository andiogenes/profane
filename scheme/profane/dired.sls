;;; (profane dired) — the directory editor, after Emacs's dired. Unstable API (plan §10).
;;;
;;; (dired "/some/dir") shows the directory in a read-only buffer, one line per entry:
;;;
;;;   * drwxr-xr-x  anton  staff     160  Oct 24 12:00  src
;;;
;;; (the first column holds the mark: * marked, D flagged for deletion). Directories come first
;;; (dired-group-directories-first); `s` cycles name / time / size order. Keys: RET f open, o open
;;; in the other window, ^ up, n p move, m u U t marks, d flag, x delete the flagged, D delete,
;;; R rename or move, C copy, + make a directory, g refresh, w copy the name, W copy the full path,
;;; q leave. R, C and D act on the marked files, else on the file at point, and ask before they
;;; replace or delete anything. C-x d reads a directory; find-file on a directory (and the
;;; search commands) open it here.

(library (profane dired)
  (export dired dired-buffer-directory)
  (import (chezscheme) (profane buffer) (profane window) (profane command) (profane keymap)
          (profane mode) (profane var) (profane face) (profane display) (profane minibuffer)
          (profane files) (profane fs) (profane macos) (profane simple))

  (defvar dired-group-directories-first #t "List directories before files in dired.")
  (defvar dired-sort 'name "How dired orders entries: name, time (newest first) or size (largest first)." '(local))
  (defvar delete-by-moving-to-trash #f "Delete files in dired by moving them to the macOS Trash.")
  (defvar dired-directory #f "The directory a dired buffer lists (with a trailing slash)." '(local))
  (defvar dired-entries (vector) "The entries of a dired buffer, one per line after the header." '(local))
  (defvar dired-name-column 0 "Where file names start on a dired line." '(local))

  (define dired-faces
    (begin
      (for-each (lambda (f) (define-face (car f) (cadr f) (caddr f)))
                '((dired-header () "The directory's name at the top of a dired buffer.")
                  (dired-directory () "Directories in dired.")
                  (dired-symlink () "Symbolic links in dired.")
                  (dired-mark () "The * of a marked file.")
                  (dired-marked () "The name of a marked file.")
                  (dired-flagged () "The name of a file flagged for deletion.")))
      #t))

  (define-major-mode dired-mode fundamental-mode "Dired" "Major mode of directory listings.")

  ;; ---- entries ----

  (define-record-type dentry (fields name path info target dir?))

  (define (join dir name)
    (if (directory-name? dir) (string-append dir name) (string-append dir "/" name)))

  (define (read-entries dir)
    (let loop ([names (append '("." "..") (directory-contents dir))] [out '()])
      (if (null? names)
          (reverse out)
          (let* ([path (join dir (car names))] [info (file-attributes path)])
            (loop (cdr names)
                  (if info
                      (cons (make-dentry (car names) path info
                                         (and (file-info-symlink? info) (file-symlink-target path))
                                         (let ([real (if (file-info-symlink? info) (file-attributes path #t) info)])
                                           (and real (file-info-directory? real))))
                            out)
                      out))))))

  (define (special? e) (member (dentry-name e) '("." "..")))

  (define (sort-entries entries mode group?)
    (let* ([specials (filter special? entries)]
           [rest (filter (lambda (e) (not (special? e))) entries)]
           [by-name (lambda (a b) (let ([x (dentry-name a)] [y (dentry-name b)])
                                    (if (string-ci=? x y) (string<? x y) (string-ci<? x y))))]
           [by (case mode
                 [(time) (lambda (a b) (let ([x (file-info-mtime (dentry-info a))] [y (file-info-mtime (dentry-info b))])
                                         (if (= x y) (by-name a b) (> x y))))]
                 [(size) (lambda (a b) (let ([x (file-info-size (dentry-info a))] [y (file-info-size (dentry-info b))])
                                         (if (= x y) (by-name a b) (> x y))))]
                 [else by-name])]
           [cmp (if group?
                    (lambda (a b) (cond [(and (dentry-dir? a) (not (dentry-dir? b))) #t]
                                        [(and (dentry-dir? b) (not (dentry-dir? a))) #f]
                                        [else (by a b)]))
                    by)])
      (append specials (list-sort cmp rest))))

  ;; ---- formatting ----

  (define (perm-string mode)
    (let* ([type (case (bitwise-and mode #o170000)
                   [(#o040000) #\d] [(#o120000) #\l] [(#o020000) #\c] [(#o060000) #\b]
                   [(#o010000) #\p] [(#o140000) #\s] [else #\-])]
           [bit (lambda (mask c) (if (zero? (bitwise-and mode mask)) #\- c))]
           [x (lambda (mask special special-on special-off)
                (let ([run (not (zero? (bitwise-and mode mask)))] [sp (not (zero? (bitwise-and mode special)))])
                  (cond [(and run sp) special-on] [sp special-off] [run #\x] [else #\-])))])
      (string type (bit #o400 #\r) (bit #o200 #\w) (x #o100 #o4000 #\s #\S)
              (bit #o040 #\r) (bit #o020 #\w) (x #o010 #o2000 #\s #\S)
              (bit #o004 #\r) (bit #o002 #\w) (x #o001 #o1000 #\t #\T))))

  (define months '#("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

  (define (pad-left s n) (if (>= (string-length s) n) s (string-append (make-string (- n (string-length s)) #\space) s)))
  (define (pad-right s n) (if (>= (string-length s) n) s (string-append s (make-string (- n (string-length s)) #\space))))
  (define (two n) (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

  ;; Like ls: month day time for the last six months, month day year otherwise.
  (define (format-time secs)
    (let* ([d (time-utc->date (make-time 'time-utc 0 secs))]
           [now (time-second (current-time))]
           [recent? (and (< secs (+ now 3600)) (> secs (- now (* 183 86400))))]
           [day (pad-left (number->string (date-day d)) 2)]
           [mon (vector-ref months (- (date-month d) 1))])
      (if recent?
          (string-append mon " " day " " (two (date-hour d)) ":" (two (date-minute d)))
          (string-append mon " " day "  " (number->string (date-year d))))))

  (define (widths entries)
    (let loop ([es entries] [ow 0] [gw 0] [sw 0])
      (if (null? es)
          (list ow gw sw)
          (let ([i (dentry-info (car es))])
            (loop (cdr es)
                  (max ow (string-length (user-name (file-info-uid i))))
                  (max gw (string-length (group-name (file-info-gid i))))
                  (max sw (string-length (number->string (file-info-size i)))))))))

  (define (name-column w) (+ 2 10 2 (car w) 2 (cadr w) 2 (caddr w) 2 12 2))

  (define (entry-line e mark w)
    (let ([i (dentry-info e)])
      (string-append (string mark) " " (perm-string (file-info-mode i)) "  "
                     (pad-right (user-name (file-info-uid i)) (car w)) "  "
                     (pad-right (group-name (file-info-gid i)) (cadr w)) "  "
                     (pad-left (number->string (file-info-size i)) (caddr w)) "  "
                     (format-time (file-info-mtime i)) "  "
                     (dentry-name e)
                     (if (dentry-target e) (string-append " -> " (dentry-target e)) ""))))

  ;; Inserts one entry's line at point with its faces (no newline).
  (define (insert-entry! e mark w)
    (let ([from (point)] [col (name-column w)])
      (insert (entry-line e mark w))
      (let ([name-start (+ from col)] [name-end (+ from col (string-length (dentry-name e)))])
        (cond [(char=? mark #\D) (put-text-property name-start name-end 'face 'dired-flagged)]
              [(char=? mark #\*) (put-text-property name-start name-end 'face 'dired-marked)]
              [(and (dentry-dir? e) (not (dentry-target e))) (put-text-property name-start name-end 'face 'dired-directory)]
              [(dentry-target e) (put-text-property name-start (+ name-end 4 (string-length (dentry-target e))) 'face 'dired-symlink)]
              [(dentry-dir? e) (put-text-property name-start name-end 'face 'dired-directory)])
        (unless (char=? mark #\space) (put-text-property from (+ from 1) 'face 'dired-mark)))))

  ;; ---- the buffer ----

  (define (dired-buffer-directory) (var-ref 'dired-directory))
  (define (entries-vector) (var-ref 'dired-entries))
  (define (header-text dir)
    (string-append "  " (if (and (> (string-length dir) 1) (directory-name? dir))
                            (substring dir 0 (- (string-length dir) 1))
                            dir)
                   ":"))

  ;; The line number (0-based) of entry INDEX.
  (define (entry-position index)
    (with-current-buffer (current-buffer)
      (let ([p (point)])
        (goto-char 0)
        (forward-line (+ index 1))
        (let ([pos (point)]) (goto-char p) pos))))

  (define (point-index) (- (line-number-at-pos) 2))

  (define (entry-at index)
    (let ([v (entries-vector)]) (and (>= index 0) (< index (vector-length v)) (vector-ref v index))))
  (define (this-entry) (entry-at (point-index)))
  (define (this-entry!)
    (or (this-entry) (error 'dired "no file on this line")))

  (define (mark-at index)
    (let ([pos (entry-position index)]) (or (char-after pos) #\space)))

  ;; name -> mark, for the marked lines.
  (define (current-marks)
    (let ([table (make-hashtable string-hash string=?)] [v (entries-vector)])
      (do ([i 0 (+ i 1)]) ((= i (vector-length v)) table)
        (let ([m (mark-at i)])
          (unless (char=? m #\space)
            (hashtable-set! table (dentry-name (vector-ref v i)) m))))))

  (define (goto-name! index)
    (let ([v (entries-vector)])
      (goto-char (entry-position (max 0 (min index (- (vector-length v) 1)))))
      (move-to-name!)))

  (define (move-to-name!)
    (let ([col (var-ref 'dired-name-column)])
      (goto-char (min (+ (line-beginning-position) col) (line-end-position)))))

  (define (index-of-name name)
    (let ([v (entries-vector)])
      (let loop ([i 0])
        (cond [(= i (vector-length v)) #f]
              [(string=? (dentry-name (vector-ref v i)) name) i]
              [else (loop (+ i 1))]))))

  ;; Rebuilds the listing, keeping marks (by name) and putting point on NAME (default: the file
  ;; it was on, else the first entry after . and ..).
  (define revert!
    (case-lambda
      [() (revert! #f)]
      [(want)
       (let* ([dir (var-ref 'dired-directory)]
              [keep (and (> (vector-length (entries-vector)) 0) (current-buffer-point-name))]
              [marks (if (> (vector-length (entries-vector)) 0) (current-marks) (make-hashtable string-hash string=?))]
              [entries (sort-entries (read-entries dir) (var-ref 'dired-sort) (var-ref 'dired-group-directories-first))]
              [w (widths entries)])
         (var-set! 'dired-entries (list->vector entries))
         (var-set! 'dired-name-column (name-column w))
         (with-inhibit-read-only
          (lambda ()
            (erase-buffer)
            (let ([from (point)])
              (insert (header-text dir))
              (put-text-property from (point) 'face 'dired-header)
              (insert "\n"))
            (for-each (lambda (e)
                        (insert-entry! e (hashtable-ref marks (dentry-name e) #\space) w)
                        (insert "\n"))
                      entries)))
         (set-buffer-unmodified!)
         (let ([i (or (and want (index-of-name want)) (and keep (index-of-name keep)) (min 2 (- (length entries) 1)))])
           (goto-name! (max 0 i))))]))

  (define (current-buffer-point-name)
    (let ([e (this-entry)]) (and e (dentry-name e))))

  (define (dired-buffers)
    (filter (lambda (b) (with-current-buffer b (eq? (var-ref 'major-mode) 'dired-mode))) (buffer-list)))

  (define (find-dired-buffer dir)
    (find (lambda (b) (with-current-buffer b (equal? (var-ref 'dired-directory) dir))) (dired-buffers)))

  (define (buffer-name-for dir)
    (let ([trimmed (if (and (> (string-length dir) 1) (directory-name? dir)) (substring dir 0 (- (string-length dir) 1)) dir)])
      (if (string=? trimmed "/") "/" (file-name-nondirectory trimmed))))

  ;; Shows DIR (a path; a file shows its directory with point on it) in the selected window.
  (define (dired path)
    (let* ([full (expand-file-name path)]
           [info (file-attributes full #t)])
      (unless info (error 'dired "no such file or directory" path))
      (let* ([file? (not (file-info-directory? info))]
             [dir (file-name-as-directory (if file? (file-name-directory full) full))]
             [name (and file? (file-name-nondirectory full))]
             [existing (find-dired-buffer dir)]
             [b (or existing (generate-new-buffer (buffer-name-for dir)))])
        (switch-to-buffer b)
        (unless existing
          (set-major-mode! 'dired-mode)
          (var-set! 'dired-directory dir)
          (var-set! 'default-directory dir)
          (buffer-disable-undo)
          (set-buffer-read-only! #t))
        (revert! name)
        b)))

  (define (revert-buffers-for! dirs)
    (for-each (lambda (b)
                (with-current-buffer b
                  (when (member (var-ref 'dired-directory) dirs) (revert!))))
              (dired-buffers)))

  ;; ---- moving around ----

  (define (move-lines! n)
    (let ([i (+ (point-index) n)] [last (- (vector-length (entries-vector)) 1)])
      (goto-name! (max 0 (min i last)))))

  (define-command (dired-next-line) "Move to the next file." (move-lines! (prefix-numeric-value)))
  (define-command (dired-previous-line) "Move to the previous file." (move-lines! (- (prefix-numeric-value))))

  ;; ---- opening ----

  (define (full-name e) (expand-file-name (dentry-path e)))

  (define-command (dired-find-file)
    "Open the file or directory at point."
    (let ([e (this-entry!)])
      (if (dentry-dir? e)
          (dired (full-name e))
          (switch-to-buffer (find-file-noselect (full-name e))))))

  (define (show-in-other-window! b) (display-buffer-in-other-window b #t))

  (define-command (dired-find-file-other-window)
    "Open the file or directory at point in the other window."
    (let ([e (this-entry!)])
      (if (dentry-dir? e)
          (let ([dir (full-name e)])
            (show-in-other-window! (current-buffer))
            (dired dir))
          (show-in-other-window! (find-file-noselect (full-name e))))))

  (define-command (dired-up-directory)
    "Go to the parent directory, with point on the directory we came from."
    (let* ([dir (var-ref 'dired-directory)]
           [here (file-name-nondirectory (substring dir 0 (max 0 (- (string-length dir) 1))))]
           [parent (expand-file-name ".." dir)])
      (if (string=? (file-name-as-directory parent) dir)
          (message "already at the top")
          (begin (dired parent)
                 (let ([i (index-of-name here)]) (when i (goto-name! i)))))))

  ;; ---- marks ----

  (define (set-mark-char! index ch)
    (let ([e (entry-at index)])
      (when (and e (not (special? e)))
        (let ([w (list 0 0 0)] [pos (entry-position index)])
          (with-inhibit-read-only
           (lambda ()
             (goto-char pos)
             (delete-char 1)
             (insert (string ch))
             (let ([name-start (+ pos (var-ref 'dired-name-column))]
                   [name-end (+ pos (var-ref 'dired-name-column) (string-length (dentry-name e)))])
               (put-text-property pos (+ pos 1) 'face (if (char=? ch #\space) 'default 'dired-mark))
               (put-text-property name-start name-end 'face
                                  (cond [(char=? ch #\D) 'dired-flagged]
                                        [(char=? ch #\*) 'dired-marked]
                                        [(and (dentry-dir? e) (not (dentry-target e))) 'dired-directory]
                                        [(dentry-target e) 'dired-symlink]
                                        [(dentry-dir? e) 'dired-directory]
                                        [else 'default])))))
          (set-buffer-unmodified!)))))

  (define (mark-this! ch)
    (let ([i (point-index)])
      (unless (entry-at i) (error 'dired "no file on this line"))
      (when (special? (entry-at i)) (error 'dired "cannot operate on . or .."))
      (set-mark-char! i ch)
      (goto-name! (min (+ i 1) (- (vector-length (entries-vector)) 1)))))

  (define-command (dired-mark) "Mark the file at point and move down." (mark-this! #\*))
  (define-command (dired-unmark) "Remove the mark from the file at point and move down." (mark-this! #\space))
  (define-command (dired-flag-file-deletion) "Flag the file at point for deletion and move down." (mark-this! #\D))

  (define-command (dired-unmark-all-marks)
    "Remove every mark."
    (let ([p (point-index)])
      (do ([i 0 (+ i 1)]) ((= i (vector-length (entries-vector))))
        (unless (char=? (mark-at i) #\space) (set-mark-char! i #\space)))
      (goto-name! p)))

  (define-command (dired-toggle-marks)
    "Mark the unmarked files and unmark the marked ones."
    (let ([p (point-index)] [v (entries-vector)])
      (do ([i 0 (+ i 1)]) ((= i (vector-length v)))
        (unless (special? (vector-ref v i))
          (set-mark-char! i (if (char=? (mark-at i) #\space) #\* #\space))))
      (goto-name! p)))

  ;; The files an operation acts on: those marked with MARK, else the one at point.
  (define (target-entries mark)
    (let* ([v (entries-vector)]
           [marked (let loop ([i 0] [out '()])
                     (cond [(= i (vector-length v)) (reverse out)]
                           [(char=? (mark-at i) mark) (loop (+ i 1) (cons (vector-ref v i) out))]
                           [else (loop (+ i 1) out)]))])
      (let ([chosen (if (pair? marked) marked (list (this-entry!)))])
        (when (exists special? chosen) (error 'dired "cannot operate on . or .."))
        chosen)))

  ;; ---- operations ----

  (define (count-phrase entries)
    (if (= (length entries) 1)
        (dentry-name (car entries))
        (format "~a files" (length entries))))

  (define (ask-yes prompt on-yes)
    (let ([b (current-buffer)])
      (read-from-minibuffer prompt
                            (lambda (answer)
                              (if (member answer '("yes" "y"))
                                  (with-current-buffer b (on-yes))
                                  (message "Cancelled"))))))

  ;; Runs (ACTION entry) for each entry; collects the failures' messages.
  (define (each-reporting entries action)
    (let loop ([es entries] [done 0] [failed '()])
      (if (null? es)
          (values done (reverse failed))
          (let ([r (guard (c [else (if (condition? c)
                                       (call-with-string-output-port (lambda (p) (display-condition c p)))
                                       "failed")])
                     (action (car es))
                     #f)])
            (loop (cdr es) (if r done (+ done 1)) (if r (cons r failed) failed))))))

  (define (report! verb done failed)
    (if (null? failed)
        (message "~a ~a file~a" verb done (if (= done 1) "" "s"))
        (message "~a ~a, ~a failed: ~a" verb done (length failed) (car failed))))

  (define (delete-entries! entries)
    (let ([dirs (length (filter (lambda (e) (and (dentry-dir? e) (not (dentry-target e)))) entries))])
      (ask-yes (format "Delete ~a~a? (yes or no) " (count-phrase entries)
                       (if (> dirs 0) " (directories recursively)" ""))
               (lambda ()
                 (let-values ([(done failed)
                               (each-reporting entries
                                               (lambda (e)
                                                 (if (var-ref 'delete-by-moving-to-trash)
                                                     (move-to-trash (full-name e))
                                                     (delete-recursively (full-name e)))))])
                   (revert!)
                   (report! "Deleted" done failed))))))

  (define-command (dired-do-delete)
    "Delete the marked files, or the file at point, after asking."
    (delete-entries! (target-entries #\*)))

  (define-command (dired-do-flagged-delete)
    "Delete the files flagged with d, after asking."
    (let ([flagged (let ([v (entries-vector)])
                     (let loop ([i 0] [out '()])
                       (cond [(= i (vector-length v)) (reverse out)]
                             [(char=? (mark-at i) #\D) (loop (+ i 1) (cons (vector-ref v i) out))]
                             [else (loop (+ i 1) out)])))])
      (if (null? flagged)
          (message "(No deletions requested)")
          (delete-entries! flagged))))

  ;; Where ENTRY goes when moved or copied to DEST: into DEST if that is a directory, else DEST.
  (define (destination entry dest many?)
    (let ([info (file-attributes dest #t)])
      (cond [(and info (file-info-directory? info)) (join dest (dentry-name entry))]
            [many? (error 'dired "target must be a directory" dest)]
            [(directory-name? dest) (error 'dired "no such directory" dest)]
            [else dest])))

  (define (transfer! verb entries action)
    (let* ([b (current-buffer)] [dir (var-ref 'dired-directory)]
           [prompt (format "~a ~a to: " verb (count-phrase entries))])
      (read-file-name
       prompt
       (lambda (dest)
         (with-current-buffer b
           (let* ([many? (> (length entries) 1)]
                  [pairs (map (lambda (e) (cons e (destination e dest many?))) entries)]
                  [existing (filter (lambda (p) (file-attributes (cdr p))) pairs)]
                  [run (lambda ()
                         (let-values ([(done failed)
                                       (each-reporting entries
                                                       (lambda (e) (action (full-name e) (cdr (assq e pairs)) (pair? existing))))])
                           (revert-buffers-for! (cons dir (map (lambda (p) (file-name-as-directory (file-name-directory (cdr p)))) pairs)))
                           (report! (string-append verb "d") done failed)))])
             (if (null? existing)
                 (run)
                 (ask-yes (format "~a exist~a; overwrite? (yes or no) "
                                  (if (= (length existing) 1) (dentry-name (car (car existing))) (format "~a files" (length existing)))
                                  (if (= (length existing) 1) "s" ""))
                          run))))))))

  (define-command (dired-do-rename)
    "Rename or move the marked files, or the file at point."
    (transfer! "Rename" (target-entries #\*)
               (lambda (src dst overwrite?) (move-path src dst overwrite?))))

  (define-command (dired-do-copy)
    "Copy the marked files, or the file at point."
    (transfer! "Copy" (target-entries #\*)
               (lambda (src dst overwrite?) (copy-recursively src dst overwrite?))))

  (define-command (dired-create-directory)
    "Create a directory (one level) and show it."
    (let ([b (current-buffer)])
      (read-file-name "Create directory: "
                      (lambda (path)
                        (with-current-buffer b
                          (make-directory (if (directory-name? path) (substring path 0 (- (string-length path) 1)) path))
                          (revert-buffers-for! (list (file-name-as-directory (file-name-directory (expand-file-name path)))))
                          (let ([i (index-of-name (file-name-nondirectory (if (directory-name? path) (substring path 0 (- (string-length path) 1)) path)))])
                            (when i (goto-name! i))))))))

  (define-command (dired-revert) "Read the directory again." (revert!) (message "Directory refreshed"))

  (define-command (dired-sort-toggle)
    "Cycle the order: name, time, size."
    (let ([next (case (var-ref 'dired-sort) [(name) 'time] [(time) 'size] [else 'name])])
      (var-set! 'dired-sort next)
      (revert!)
      (message "Sorted by ~a" next)))

  (define-command (dired-copy-filename-as-kill)
    "Copy the name of the file at point to the kill ring."
    (let ([name (dentry-name (this-entry!))])
      (kill-new name)
      (message "~a" name)))

  (define-command (dired-copy-full-filename-as-kill)
    "Copy the full path of the file at point (the directory, on the header line)."
    (let ([name (if (this-entry)
                    (full-name (this-entry))
                    (let ([d (var-ref 'dired-directory)]) (if (> (string-length d) 1) (substring d 0 (- (string-length d) 1)) d)))])
      (kill-new name)
      (message "~a" name)))

  (define-command (dired-quit) "Leave the dired buffer (it stays alive)."
    (let ([other (other-buffer (current-buffer))])
      (when other (switch-to-buffer other))))

  ;; ---- reading a directory, and the keys ----

  (define-command (dired-open)
    "Show a directory in dired."
    (read-file-name "Dired (directory): " (lambda (path) (dired path))))

  (define installed
    (begin
      (set-directory-handler! (lambda (path) (dired path)))
      #t))

  (define bindings
    (begin
      (define-key! (global-map) "C-x d" 'dired-open)
      (for-each (lambda (b) (define-key! (mode-keymap 'dired-mode) (car b) (cdr b)))
                '(("RET" . dired-find-file) ("f" . dired-find-file) ("o" . dired-find-file-other-window)
                  ("^" . dired-up-directory)
                  ("n" . dired-next-line) ("SPC" . dired-next-line) ("C-n" . dired-next-line) ("<down>" . dired-next-line)
                  ("p" . dired-previous-line) ("C-p" . dired-previous-line) ("<up>" . dired-previous-line)
                  ("m" . dired-mark) ("u" . dired-unmark) ("U" . dired-unmark-all-marks) ("t" . dired-toggle-marks)
                  ("d" . dired-flag-file-deletion) ("x" . dired-do-flagged-delete) ("D" . dired-do-delete)
                  ("R" . dired-do-rename) ("C" . dired-do-copy) ("+" . dired-create-directory)
                  ("g" . dired-revert) ("s" . dired-sort-toggle)
                  ("w" . dired-copy-filename-as-kill) ("W" . dired-copy-full-filename-as-kill)
                  ("q" . dired-quit)))
      #t)))
