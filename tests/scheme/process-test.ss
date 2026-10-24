(import (chezscheme) (srfi :64) (profane buffer) (profane keymap) (profane command)
        (profane command-loop) (profane async) (profane process))

(test-begin "process")

(define (sh script) (list "sh" "-c" script))
(define (pump-until pred)
  (let loop ([n 0]) (unless (or (pred) (> n 400)) (async-poll! 10) (loop (+ n 1)))))
(define (contains? s sub)
  (let ([n (string-length sub)])
    (let loop ([i 0])
      (cond [(> (+ i n) (string-length s)) #f]
            [(string=? (substring s i (+ i n)) sub) #t]
            [else (loop (+ i 1))]))))

;; ---- run-process: exit code, both streams ----
(test-equal "output, stderr, exit code"
  '(3 "hi\n" "err\n")
  (await (run-process (sh "echo hi; echo err >&2; exit 3"))))
(test-equal "killed by a signal: minus the signal" '(-15 "" "")
  (await (run-process (sh "kill -TERM $$"))))
(test-equal "cwd and env"
  '(0 "/ seen /x\n" "")
  (await (run-process (sh "echo $PWD $PF_Z $HOME") '((cwd . "/") (env . (("PF_Z" . "seen") ("HOME" . "/x")))))))

;; ---- filters and sentinels ----
(define chunks '())
(define events '())
(define p (start-process "t" (sh "printf 'one\\ntwo\\n'; sleep 0.05; printf three")
                         `((filter . ,(lambda (p s) (set! chunks (cons s chunks))))
                           (sentinel . ,(lambda (p e) (set! events (cons e events)))))))
(test-assert "running" (process-live? p))
(test-eq "status" 'run (process-status p))
(test-assert "pid" (> (process-pid p) 0))
(pump-until (lambda () (pair? events)))
(test-equal "filter got everything, in order" "one\ntwo\nthree" (apply string-append (reverse chunks)))
(test-equal "sentinel" '("finished\n") events)
(test-eq "exited" 'exit (process-status p))
(test-eqv "status code" 0 (process-exit-status p))
(test-assert "not live" (not (process-live? p)))
(test-assert "no longer listed" (not (memq p (process-list))))
(test-eq "its promise resolves with it" p (await (process-promise p)))

(define events2 '())
(define bad (start-process "bad" (sh "exit 2") `((sentinel . ,(lambda (p e) (set! events2 (cons e events2)))))))
(pump-until (lambda () (pair? events2)))
(test-equal "abnormal exit" '("exited abnormally with code 2\n") events2)

;; ---- a character split across reads is kept whole ----
(define text "")
(define split (start-process "u" (sh "printf '\\303'; sleep 0.1; printf '\\251t\\303\\251\\n'")
                             `((filter . ,(lambda (p s) (set! text (string-append text s)))))))
(await (process-promise split))
(test-equal "multibyte split over reads" "été\n" text)

;; ---- the default: output goes to the end of the buffer, point follows ----
(define out (generate-new-buffer "proc-out"))
(await (process-promise (start-process "b" (sh "echo one") `((buffer . ,out)))))
(await (process-promise (start-process "b" (sh "echo two >&2") `((buffer . ,out)))))
(test-equal "stdout and stderr in the buffer" "one\ntwo\n" (with-current-buffer out (buffer-string)))
(test-eqv "point followed" 8 (with-current-buffer out (point)))
(with-current-buffer out (goto-char 0))
(await (process-promise (start-process "b" (sh "echo three") `((buffer . ,out)))))
(test-eqv "point left alone when not at the end" 0 (with-current-buffer out (point)))

;; ---- input, EOF, signals ----
(define echoed "")
(define cat (start-process "cat" '("cat") `((filter . ,(lambda (p s) (set! echoed (string-append echoed s)))))))
(test-assert "send" (process-send-string cat "héllo\n"))
(pump-until (lambda () (>= (string-length echoed) 6)))
(test-equal "round trip" "héllo\n" echoed)
(test-assert "eof" (process-send-eof cat))
(await (process-promise cat))
(test-assert "send to an exited process fails" (not (process-send-string cat "x")))

(define sleeper (start-process "sleep" '("sleep" "30")))
(test-assert "signal" (interrupt-process sleeper))
(await (process-promise sleeper))
(test-eq "signalled" 'signal (process-status sleeper))
(test-eqv "the signal" 2 (process-exit-status sleeper))
(test-assert "signalling a dead process fails" (not (kill-process sleeper)))

;; ---- failures ----
(test-assert "a missing program is an error at start"
  (guard (c [else (contains? (condition-message c) "no such file")])
    (start-process "x" '("no-such-program-pf")) #f))
(test-eqv "its token was released" 0 (length (process-list)))

;; ---- pty ----
(define tty "")
(define pty (start-process "pty" (sh "test -t 0 && echo tty; stty size; read x; echo got:$x")
                           `((pty . #t) (rows . 12) (cols . 50)
                             (filter . ,(lambda (p s) (set! tty (string-append tty s)))))))
(process-send-string pty "abc\n")
(await (process-promise pty))
(test-assert "a terminal" (contains? tty "tty\r\n"))
(test-assert "of the given size" (contains? tty "12 50\r\n"))
(test-assert "input reached it" (contains? tty "got:abc"))

;; ---- backpressure: a flood of output is delivered whole ----
(define total 0)
(await (let ([pr (start-process "flood" (sh "head -c 5000000 /dev/zero | tr '\\0' x")
                                `((filter . ,(lambda (p s) (set! total (+ total (string-length s)))))))])
         (process-promise pr)))
(test-eqv "5 MB, none lost" 5000000 total)

;; ---- await inside a command parks it while the process runs ----
(set-buffer (generate-new-buffer "cmd"))
(define result #f)
(register-command! 'test-run
  (lambda () (set! result (await (run-process (sh "sleep 0.1; echo done"))))) "")
(define-key! (global-map) "<f9>" 'test-run)
(for-each handle-key '("<f9>"))
(test-assert "the command waits for the process" (command-busy?))
(let loop ([n 0])
  (when (and (command-busy?) (< n 400))
    (async-poll! 10)
    (resume-busy!)
    (loop (+ n 1))))
(test-equal "and gets its result" '(0 "done\n" "") result)

(test-end "process")
(test-exit)
