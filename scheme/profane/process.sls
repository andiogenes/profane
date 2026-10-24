;;; (profane process) — child processes over pipes or a pseudo-terminal. Unstable API (plan §10).
;;;
;;;   (start-process "name" '("sh" "-c" "echo hi") '((filter . ,proc) (sentinel . ,proc)))
;;;
;;; Options (an alist): cwd, env (("NAME" . "value") ...: added to the environment), pty (#t: run on a
;;; terminal), rows/cols (the pty size), merge-stderr (#t: one output stream), buffer (output goes
;;; to its end unless there is a filter), filter ((filter process string): stdout), stderr-filter
;;; (defaults to filter; with neither, stderr also goes to the buffer), binary (#t: the filters get
;;; the raw bytes, a bytevector, undecoded; for a terminal), sentinel ((sentinel process
;;; event): the process changed state; event is "finished\n", "exited abnormally with code 1\n",
;;; "killed\n", ...). Output arrives on the main thread between commands, decoded as UTF-8 (a
;;; character split across reads is kept whole). The reader stops while the editor has not caught
;;; up (core/process), so a chatty child cannot flood it.
;;;
;;; (await (process-promise p)) waits for the exit; (await (run-process argv options)) runs to
;;; completion and gives (code stdout stderr). An aborted wait (C-g) leaves the process running.

(library (profane process)
  (export start-process process? process-name process-pid process-status process-live?
          process-exit-status process-buffer process-list process-promise
          process-send-string process-send-bytes process-send-eof
          signal-process kill-process interrupt-process process-resize!
          run-process executable-find)
  (import (except (chezscheme) process) (profane native) (profane buffer) (profane command) (profane async)
          (profane var))

  (define-record-type process
    (fields name handle pid (mutable state) (mutable code) (mutable signal) buffer
            (mutable filter) (mutable stderr-filter) (mutable sentinel) (mutable token)
            promise (mutable out-tail) (mutable err-tail) binary?)
    (nongenerative profane-process))

  ;; Where programs are looked for by executable-find. An app started from the Dock gets a minimal
  ;; PATH (no Homebrew), so the usual Homebrew directories are always added; (a login-shell PATH
  ;; import is a later seam).
  (define (default-exec-path)
    (let* ([path (or (getenv "PATH") "")]
           [dirs (let loop ([cs (string->list path)] [cur '()] [out '()])
                   (define (flush) (if (null? cur) out (cons (list->string (reverse cur)) out)))
                   (cond [(null? cs) (reverse (flush))]
                         [(char=? (car cs) #\:) (loop (cdr cs) '() (flush))]
                         [else (loop (cdr cs) (cons (car cs) cur) out)]))])
      (append dirs (filter (lambda (d) (not (member d dirs))) '("/opt/homebrew/bin" "/usr/local/bin")))))

  (defvar exec-path (default-exec-path) "Directories searched for programs by executable-find.")

  (define access (foreign-procedure "access" (string int) int))

  ;; The full path of the executable PROGRAM in exec-path (a name with a slash is taken as it is),
  ;; or #f.
  (define (executable-find program)
    (define (executable? f) (and (file-exists? f) (not (file-directory? f)) (= 0 (access f 1))))
    (if (memv #\/ (string->list program))
        (and (executable? program) program)
        (let loop ([dirs (var-ref 'exec-path)])
          (cond [(null? dirs) #f]
                [(let ([f (string-append (car dirs) "/" program)]) (and (executable? f) f)) => values]
                [else (loop (cdr dirs))]))))

  (define processes (make-eqv-hashtable)) ; token -> live process

  (define (process-status p) (process-state p))
  (define (process-live? p) (eq? (process-state p) 'run))
  (define (process-exit-status p) (if (eq? (process-state p) 'signal) (process-signal p) (process-code p)))
  (define (process-list) (vector->list (hashtable-values processes)))

  (define (opt options key default)
    (let ([a (assq key options)]) (if a (cdr a) default)))

  (define (bv-append . bvs)
    (let* ([n (fold-left + 0 (map bytevector-length bvs))] [out (make-bytevector n)])
      (let loop ([bvs bvs] [at 0])
        (unless (null? bvs)
          (bytevector-copy! (car bvs) 0 out at (bytevector-length (car bvs)))
          (loop (cdr bvs) (+ at (bytevector-length (car bvs))))))
      out))

  ;; "a\0b\0": strings as NUL-terminated UTF-8, one after another.
  (define (blob strings)
    (apply bv-append (map (lambda (s) (bv-append (string->utf8 s) (bytevector 0))) strings)))

  ;; The bytes of TAIL + DATA that are whole characters, and the incomplete ending left over.
  (define (split-incomplete all)
    (let ([n (bytevector-length all)])
      (let loop ([i (- n 1)])
        (if (or (< i 0) (< i (- n 4)))
            (values all (bytevector))
            (let ([b (bytevector-u8-ref all i)])
              (cond
                [(= (bitwise-and b #xC0) #x80) (loop (- i 1))]
                [else
                 (let ([need (cond [(>= b #xF0) 4] [(>= b #xE0) 3] [(>= b #xC0) 2] [else 1])])
                   (if (> need (- n i))
                       (let ([head (make-bytevector i)] [tail (make-bytevector (- n i))])
                         (bytevector-copy! all 0 head 0 i)
                         (bytevector-copy! all i tail 0 (- n i))
                         (values head tail))
                       (values all (bytevector))))]))))))

  (define (report who c)
    (message "~a: ~a" who
             (if (condition? c)
                 (call-with-string-output-port (lambda (p) (display-condition c p)))
                 c)))

  ;; Output with no filter goes to the end of the process buffer; point follows if it was there.
  (define (insert-at-end! buffer string)
    (when (and buffer (buffer-live? buffer))
      (with-current-buffer buffer
        (let ([at-end (= (point) (point-max))] [old (point)])
          (goto-char (point-max))
          (insert string)
          (unless at-end (goto-char old))))))

  (define (deliver! p stderr? string)
    (unless (string=? string "")
      (let ([filter (if stderr?
                        (or (process-stderr-filter p) (process-filter p))
                        (process-filter p))])
        (guard (c [else (report 'process-filter c)])
          (if filter
              (filter p string)
              (insert-at-end! (process-buffer p) string))))))

  (define (on-output p stderr? data)
    (if (process-binary? p)
        (let ([filter (if stderr? (or (process-stderr-filter p) (process-filter p)) (process-filter p))])
          (when filter
            (guard (c [else (report 'process-filter c)]) (filter p data))))
        (on-text-output p stderr? data))
    (%proc-consumed (process-handle p) (bytevector-length data)))

  (define (on-text-output p stderr? data)
    (let ([all (bv-append (if stderr? (process-err-tail p) (process-out-tail p)) data)])
      (let-values ([(head tail) (split-incomplete all)])
        (if stderr? (process-err-tail-set! p tail) (process-out-tail-set! p tail))
        (deliver! p stderr? (utf8->string head)))))

  (define (signal-name n)
    (case n
      [(1) "hangup"] [(2) "interrupt"] [(3) "quit"] [(9) "killed"] [(15) "terminated"]
      [else (format "signal ~a" n)]))

  (define (on-exit p data)
    (let ([code (bytevector-s32-native-ref data 0)] [sig (bytevector-s32-native-ref data 4)])
      (for-each (lambda (stderr?)
                  (let ([tail (if stderr? (process-err-tail p) (process-out-tail p))])
                    (when (> (bytevector-length tail) 0)
                      (deliver! p stderr? (utf8->string tail)))))
                '(#f #t))
      (process-state-set! p (if (> sig 0) 'signal 'exit))
      (process-code-set! p code)
      (process-signal-set! p sig)
      (hashtable-delete! processes (process-token p))
      (async-token-release! (process-token p))
      (%proc-release (process-handle p))
      (let ([event (cond [(> sig 0) (format "~a\n" (signal-name sig))]
                         [(= code 0) "finished\n"]
                         [else (format "exited abnormally with code ~a\n" code)])])
        (when (process-sentinel p)
          (guard (c [else (report 'process-sentinel c)])
            ((process-sentinel p) p event))))
      (promise-resolve! (process-promise p) p)))

  (define (start-process name argv . rest)
    (let* ([options (if (null? rest) '() (car rest))]
           [pty? (opt options 'pty #f)]
           [env (opt options 'env '())]
           [env (if (and pty? (not (assoc "TERM" env))) (cons '("TERM" . "xterm-256color") env) env)]
           [cwd (opt options 'cwd #f)]
           [flags (+ (if pty? 1 0) (if (opt options 'merge-stderr #f) 2 0))]
           [argv-blob (blob argv)]
           [env-blob (blob (map (lambda (e) (string-append (car e) "=" (cdr e))) env))]
           [cwd-blob (if cwd (string->utf8 cwd) (bytevector))]
           [p-box (box #f)]
           [token (async-token-new
                   (lambda (kind data)
                     (let ([p (unbox p-box)])
                       (case kind
                         [(1) (on-output p #f data)]
                         [(2) (on-output p #t data)]
                         [(3) (on-exit p data)]))))]
           [handle (%proc-spawn argv-blob (bytevector-length argv-blob) env-blob
                                (bytevector-length env-blob) cwd-blob (bytevector-length cwd-blob)
                                flags token (opt options 'rows 0) (opt options 'cols 0))])
      (when (< handle 0)
        (async-token-release! token)
        (error 'start-process (format "cannot start ~a: ~a" (car argv)
                                      (case (- handle)
                                        [(2) "no such file or directory"]
                                        [(13) "permission denied"]
                                        [else (format "error ~a" (- handle))])) argv))
      (let ([p (make-process name handle (%proc-pid handle) 'run #f 0 (opt options 'buffer #f)
                             (opt options 'filter #f) (opt options 'stderr-filter #f)
                             (opt options 'sentinel #f) token (make-promise)
                             (bytevector) (bytevector) (and (opt options 'binary #f) #t))])
        (set-box! p-box p)
        (hashtable-set! processes token p)
        p)))

  (define (process-send-bytes p bv)
    (and (process-live? p) (= 0 (%proc-write (process-handle p) bv (bytevector-length bv)))))
  (define (process-send-string p string) (process-send-bytes p (string->utf8 string)))
  (define (process-send-eof p) (and (process-live? p) (= 0 (%proc-eof (process-handle p)))))

  (define signals '((hup . 1) (int . 2) (quit . 3) (kill . 9) (term . 15) (stop . 17) (cont . 19)
                    (usr1 . 30) (usr2 . 31)))

  ;; SIGNAL is a number or one of hup int quit kill term stop cont usr1 usr2. The whole process
  ;; group gets it. #f if the process is gone.
  (define (signal-process p signal)
    (let ([n (if (symbol? signal) (cdr (or (assq signal signals) (error 'signal-process "unknown signal" signal))) signal)])
      (and (process-live? p) (= 0 (%proc-signal (process-handle p) n)))))
  (define (kill-process p) (signal-process p 'kill))
  (define (interrupt-process p) (signal-process p 'int))

  (define (process-resize! p rows cols)
    (and (process-live? p) (= 0 (%proc-resize (process-handle p) rows cols))))

  ;; A promise resolved with (code stdout stderr) when ARGV has run to completion; code is the
  ;; exit status, or minus the signal that killed it. OPTIONS as for start-process (the filters, buffer
  ;; and sentinel are replaced by the collecting).
  (define (run-process argv . rest)
    (let* ([options (if (null? rest) '() (car rest))]
           [out (open-output-string)] [err (open-output-string)]
           [result (make-promise)]
           [p (start-process
               (car argv) argv
               (append `((filter . ,(lambda (p s) (put-string out s)))
                         (stderr-filter . ,(lambda (p s) (put-string err s)))
                         (buffer . #f)
                         (sentinel . ,(lambda (p event) (void))))
                       options))])
      (promise-then (process-promise p)
                    (lambda (pp)
                      (promise-resolve! result
                                        (list (if (eq? (process-state p) 'signal)
                                                  (- (process-signal p))
                                                  (process-code p))
                                              (get-output-string out) (get-output-string err)))))
      result)))
