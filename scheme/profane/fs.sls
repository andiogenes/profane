;;; (profane fs) — file system queries and operations with real error messages: what dired and the
;;; sidebar are built on. Unstable API (plan §10).
;;;
;;; Failures raise (error who "message") with the system's text ("Permission denied", ...) and the
;;; path. Paths are strings (UTF-8); a trailing slash is not needed. Nothing here follows a
;;; symbolic link unless said: deleting or copying a link works on the link.

(library (profane fs)
  (export file-attributes file-info? file-info-mode file-info-size file-info-mtime file-info-uid
          file-info-gid file-info-nlink file-info-directory? file-info-symlink? file-info-regular?
          file-symlink-target user-name group-name
          copy-path copy-recursively delete-recursively move-path make-directory
          directory-contents)
  (import (chezscheme) (profane native))

  (define strerror (foreign-procedure "strerror" (int) string))

  (define (fail who rc path)
    (error who (format "~a: ~a" (strerror (- rc)) path)))

  (define (bytes s) (string->utf8 s))
  (define (blen bv) (bytevector-length bv))

  ;; ---- querying ----

  (define-record-type file-info
    (fields mode size mtime uid gid nlink))

  (define (type-bits info) (bitwise-and (file-info-mode info) #o170000))
  (define (file-info-directory? info) (= (type-bits info) #o040000))
  (define (file-info-symlink? info) (= (type-bits info) #o120000))
  (define (file-info-regular? info) (= (type-bits info) #o100000))

  ;; The attributes of PATH, or #f when it cannot be examined. A symbolic link is described
  ;; itself unless FOLLOW? is true.
  (define file-attributes
    (case-lambda
      [(path) (file-attributes path #f)]
      [(path follow?)
       (let* ([b (bytes path)] [out (make-bytevector 48)])
         (and (= 0 (%fs-stat b (blen b) (if follow? 1 0) out))
              (make-file-info (bytevector-s64-native-ref out 0) (bytevector-s64-native-ref out 8)
                              (bytevector-s64-native-ref out 16) (bytevector-s64-native-ref out 24)
                              (bytevector-s64-native-ref out 32) (bytevector-s64-native-ref out 40))))]))

  (define (file-symlink-target path)
    (let* ([b (bytes path)] [buf (make-bytevector 4096)] [n (%fs-readlink b (blen b) buf 4096)])
      (and (>= n 0) (utf8->string (let ([r (make-bytevector (min n 4096))]) (bytevector-copy! buf 0 r 0 (min n 4096)) r)))))

  (define names (make-hashtable equal-hash equal?))
  (define (owner-name kind id)
    (let ([key (cons kind id)])
      (or (hashtable-ref names key #f)
          (let* ([buf (make-bytevector 256)] [n (%fs-owner kind id buf 256)]
                 [name (if (>= n 0)
                           (utf8->string (let ([r (make-bytevector (min n 256))]) (bytevector-copy! buf 0 r 0 (min n 256)) r))
                           (number->string id))])
            (hashtable-set! names key name)
            name))))
  (define (user-name uid) (owner-name 0 uid))
  (define (group-name gid) (owner-name 1 gid))

  ;; The names in directory DIR, "." and ".." not included, sorted; '() if it cannot be read.
  (define (directory-contents dir)
    (guard (c [else '()]) (list-sort string<? (directory-list dir))))

  ;; ---- operations ----

  (define (join dir name)
    (if (and (> (string-length dir) 0) (char=? (string-ref dir (- (string-length dir) 1)) #\/))
        (string-append dir name)
        (string-append dir "/" name)))

  (define (directory? path)
    (let ([i (file-attributes path)]) (and i (file-info-directory? i))))

  (define (make-directory path)
    (let* ([b (bytes path)] [rc (%fs-mkdir b (blen b) #o777)])
      (unless (= rc 0) (fail 'make-directory rc path))))

  ;; Copies the file or link SRC to DST; an existing DST is an error unless OVERWRITE?.
  (define copy-path
    (case-lambda
      [(src dst) (copy-path src dst #f)]
      [(src dst overwrite?)
       (let* ([s (bytes src)] [d (bytes dst)] [rc (%fs-copy s (blen s) d (blen d) (if overwrite? 1 0))])
         (unless (= rc 0) (fail 'copy-path rc (if (= rc -17) dst src))))]))

  ;; Copies a file, link or directory tree. Directories merge into an existing DST directory.
  (define copy-recursively
    (case-lambda
      [(src dst) (copy-recursively src dst #f)]
      [(src dst overwrite?)
       (let ([info (file-attributes src)])
         (cond
           [(not info) (fail 'copy-recursively -2 src)]
           [(file-info-directory? info)
            (when (and (directory? dst) (string=? (canonical src) (canonical dst)))
              (error 'copy-recursively "cannot copy a directory into itself" src))
            (unless (directory? dst) (make-directory dst))
            (for-each (lambda (n) (copy-recursively (join src n) (join dst n) overwrite?))
                      (directory-contents src))]
           [else (copy-path src dst overwrite?)]))]))

  (define (canonical p)
    (let loop ([p p]) (if (and (> (string-length p) 1) (char=? (string-ref p (- (string-length p) 1)) #\/))
                          (loop (substring p 0 (- (string-length p) 1))) p)))

  (define (remove-one path)
    (let* ([b (bytes path)] [rc (%fs-remove b (blen b))])
      (unless (= rc 0) (fail 'delete-recursively rc path))))

  ;; Deletes a file, link (not its target) or directory with everything in it.
  (define (delete-recursively path)
    (let ([info (file-attributes path)])
      (unless info (fail 'delete-recursively -2 path))
      (when (file-info-directory? info)
        (for-each (lambda (n) (delete-recursively (join path n))) (directory-contents path)))
      (remove-one path)))

  ;; Renames SRC to DST; across file systems it copies and deletes. DST must not exist unless
  ;; it is an empty directory or OVERWRITE? is true for a file.
  (define move-path
    (case-lambda
      [(src dst) (move-path src dst #f)]
      [(src dst overwrite?)
       (when (and (not overwrite?) (file-attributes dst)) (fail 'move-path -17 dst))
       (let* ([s (bytes src)] [d (bytes dst)] [rc (%fs-rename s (blen s) d (blen d))])
         (cond [(= rc 0) (void)]
               [(= rc -18) (copy-recursively src dst overwrite?) (delete-recursively src)] ; EXDEV
               [else (fail 'move-path rc src)]))])))
