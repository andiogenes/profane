(import (chezscheme) (srfi :64) (profane fs))

(test-begin "fs")

(define root (format "/tmp/pf-fs-~a-~a" (time-second (current-time)) (time-nanosecond (current-time))))
(define (path . parts) (apply string-append root (map (lambda (p) (string-append "/" p)) parts)))
(define (write-file! p text) (call-with-output-file p (lambda (port) (put-string port text)) 'replace))
(define (read-file p) (call-with-input-file p get-string-all))
(define (fails? thunk) (guard (c [else (condition-message c)]) (thunk) #f))
(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0]) (cond [(> (+ i n) (string-length s)) #f] [(string=? (substring s i (+ i n)) sub) #t] [else (loop (+ i 1))]))))

(make-directory root)
(make-directory (path "d"))
(write-file! (path "a.txt") "alpha")
(write-file! (path "d" "inner.txt") "inner")
(make-directory (path "d" "deep"))
(write-file! (path "d" "deep" "x") "x")

;; ---- info ----
(let ([i (file-attributes (path "a.txt"))])
  (test-assert "regular" (file-info-regular? i))
  (test-eqv "size" 5 (file-info-size i))
  (test-assert "recent" (> (file-info-mtime i) 1600000000)))
(test-assert "directory" (file-info-directory? (file-attributes (path "d"))))
(test-eqv "missing is #f" #f (file-attributes (path "nope")))
(test-assert "owner name" (string? (user-name (file-info-uid (file-attributes (path "a.txt"))))))
(test-equal "unknown ids show the number" "987654" (user-name 987654))
(test-equal "contents are sorted, without . and .." '("a.txt" "d") (directory-contents root))
(test-equal "unreadable is empty" '() (directory-contents (path "nope")))

;; ---- copy, move ----
(copy-path (path "a.txt") (path "b.txt"))
(test-equal "copied" "alpha" (read-file (path "b.txt")))
(test-assert "no overwrite by default" (contains? (fails? (lambda () (copy-path (path "a.txt") (path "b.txt")))) "exists"))
(write-file! (path "a.txt") "changed")
(copy-path (path "a.txt") (path "b.txt") #t)
(test-equal "overwritten" "changed" (read-file (path "b.txt")))
(test-assert "missing source" (contains? (fails? (lambda () (copy-path (path "nope") (path "c")))) "No such file"))

(copy-recursively (path "d") (path "d2"))
(test-equal "tree copied" "x" (read-file (path "d2" "deep" "x")))
(test-assert "not into itself" (fails? (lambda () (copy-recursively (path "d") (path "d")))))

(move-path (path "b.txt") (path "moved.txt"))
(test-assert "moved" (and (not (file-attributes (path "b.txt"))) (file-attributes (path "moved.txt"))))
(test-assert "move refuses an existing target" (contains? (fails? (lambda () (move-path (path "moved.txt") (path "a.txt")))) "exists"))
(move-path (path "d2") (path "d3"))
(test-equal "a directory moves whole" "x" (read-file (path "d3" "deep" "x")))

;; ---- delete ----
(delete-recursively (path "d3"))
(test-eqv "tree deleted" #f (file-attributes (path "d3")))
(test-assert "deleting nothing is an error" (fails? (lambda () (delete-recursively (path "d3")))))
(test-assert "making an existing directory fails" (contains? (fails? (lambda () (make-directory (path "d")))) "exists"))

(system (string-append "rm -rf " root))
(test-end "fs")
(test-exit)
