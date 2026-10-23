(import (chezscheme) (srfi :64) (profane repl))

(test-begin "repl")

(let ([s (make-repl-session)])
  (test-equal "value" "3\n" (repl-feed! s "(+ 1 2)\n"))
  (test-equal "several data" "1\n2\n" (repl-feed! s "1 2 "))
  (test-equal "no output for definitions" "" (repl-feed! s "(define x 10)\n"))
  (test-equal "definitions persist" "11\n" (repl-feed! s "(+ x 1)\n"))
  (test-equal "multiple values" "1\n2\n" (repl-feed! s "(values 1 2)\n"))
  (test-equal "void prints nothing" "" (repl-feed! s "(void)\n"))
  (test-equal "captures output" "hi\n" (repl-feed! s "(begin (display \"hi\") (newline))\n"))
  (test-equal "condition" "Exception in car: 1 is not a pair\n" (repl-feed! s "(car 1)\n"))
  (test-equal "non-condition raise"
              "Exception: non-condition object raised: oops\n"
              (repl-feed! s "(raise 'oops)\n"))
  (test-equal "session survives errors" "4\n" (repl-feed! s "(* 2 2)\n")))

(let ([s (make-repl-session)])
  (test-equal "incomplete list waits" "" (repl-feed! s "(+ 1"))
  (test-equal "incomplete string waits" "" (repl-feed! s " (string-length \"ab"))
  (test-equal "completes across chunks" "6\n" (repl-feed! s "c\")\n 2)\n")))

(let ([s (make-repl-session)])
  (test-equal "trailing atom may still grow" "" (repl-feed! s "12"))
  (test-equal "atom completes" "123\n" (repl-feed! s "3\n"))
  (test-equal "atom flushed at finish" "" (repl-feed! s "45"))
  (test-equal "finish evaluates the tail" "45\n" (repl-finish! s)))

(let ([s (make-repl-session)])
  (test-equal "comment only" "" (repl-feed! s "; nothing here\n"))
  (test-equal "block comment spans chunks" "" (repl-feed! s "#| open"))
  (test-equal "block comment closes" "7\n" (repl-feed! s " |# 7\n")))

(let ([s (make-repl-session)])
  (test-assert "syntax error is reported"
               (let ([out (repl-feed! s ")\n")])
                 (and (> (string-length out) 0) (char=? #\E (string-ref out 0)))))
  (test-equal "recovers after syntax error" "5\n" (repl-feed! s "5\n")))

(let ([s (make-repl-session)])
  (repl-feed! s "(+ 1")
  (test-assert "incomplete datum is an error at finish"
               (let ([out (repl-finish! s)])
                 (and (> (string-length out) 0) (char=? #\E (string-ref out 0))))))

(let ([s (make-repl-session (copy-environment (scheme-environment)))])
  (repl-feed! s "(define only-here 1)\n")
  (test-equal "custom environment is isolated" "1\n" (repl-feed! s "only-here\n"))
  (test-error "other sessions don't see it" #t (top-level-value 'only-here)))

(test-end "repl")
(test-exit)
