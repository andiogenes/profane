;;; Minimal in-repo subset of SRFI 64 (Chez Scheme ships none). Covers what profane's suites
;;; use: test-begin/test-end, test-assert, test-equal, test-eqv, test-eq, test-error and the
;;; runner's pass/fail counts. Swap for a full implementation if suites outgrow it.

(library (srfi :64)
  (export test-begin test-end test-assert test-equal test-eqv test-eq test-error
          test-runner-current test-runner-pass-count test-runner-fail-count test-exit)
  (import (chezscheme))

  (define-record-type test-runner
    (fields (mutable groups) (mutable pass-count) (mutable fail-count)))

  (define current (make-test-runner '() 0 0))
  (define (test-runner-current) current)

  (define (test-begin name)
    (test-runner-groups-set! current (cons name (test-runner-groups current))))

  (define test-end
    (case-lambda
      [() (test-end #f)]
      [(name)
       (let ([groups (test-runner-groups current)])
         (when (null? groups) (error 'test-end "no open test group"))
         (when (and name (not (equal? name (car groups))))
           (error 'test-end "group mismatch" name (car groups)))
         (test-runner-groups-set! current (cdr groups))
         (when (null? (cdr groups))
           (printf "~a: ~a passed, ~a failed~%" (car groups)
                   (test-runner-pass-count current) (test-runner-fail-count current))))]))

  (define (report! ok? name detail)
    (if ok?
        (test-runner-pass-count-set! current (+ 1 (test-runner-pass-count current)))
        (begin
          (test-runner-fail-count-set! current (+ 1 (test-runner-fail-count current)))
          (printf "FAIL ~a~@[: ~a~]~%" (or name "(unnamed)") detail))))

  ;; Exits with status 1 if any test failed.
  (define (test-exit)
    (exit (if (zero? (test-runner-fail-count current)) 0 1)))

  (define (run-guarded thunk name)
    (guard (c [else (report! #f name
                             (call-with-string-output-port
                              (lambda (p) (if (condition? c) (display-condition c p) (write c p)))))
                    #f])
      (thunk)))

  (define (compare same? name expected thunk)
    (run-guarded
     (lambda ()
       (let ([actual (thunk)])
         ;; Formatted only on failure: values may be large or cyclic (records).
         (if (same? expected actual)
             (report! #t name #f)
             (report! #f name (parameterize ([print-graph #t])
                                (format "expected ~s, got ~s" expected actual))))))
     name))

  (define-syntax test-assert
    (syntax-rules ()
      [(_ expr) (test-assert #f expr)]
      [(_ name expr)
       (run-guarded (lambda () (report! (and expr #t) name 'expr)) name)]))

  (define-syntax define-comparison
    (syntax-rules ()
      [(_ id same?)
       (define-syntax id
         (syntax-rules ()
           [(_ expected expr) (compare same? #f expected (lambda () expr))]
           [(_ name expected expr) (compare same? name expected (lambda () expr))]))]))

  (define-comparison test-equal equal?)
  (define-comparison test-eqv eqv?)
  (define-comparison test-eq eq?)

  (define-syntax test-error
    (syntax-rules ()
      [(_ expr) (test-error #f #t expr)]
      [(_ type expr) (test-error #f type expr)]
      [(_ name type expr)
       (report! (guard (c [else #t]) expr #f) name "expected an error")])))
