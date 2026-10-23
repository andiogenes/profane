;;; (profane repl) — incremental read/eval/print over a stream of source text.
;;; Transport-agnostic: the socket REPL in the platform shell feeds chunks in and writes the
;;; returned output back. Unstable API (plan §10).

(library (profane repl)
  (export make-repl-session repl-session? repl-feed! repl-finish!)
  (import (chezscheme))

  (define-record-type repl-session
    (fields (mutable pending) environment)
    (protocol
     (lambda (new)
       (case-lambda
         [() (new "" (interaction-environment))]
         [(env) (new "" env)]))))

  ;; Feeds TEXT and evaluates every complete datum; returns everything they printed.
  (define (repl-feed! session text)
    (process! session (string-append (repl-session-pending session) text) #f))

  ;; Evaluates what is left as if the stream ended; an incomplete datum becomes an error.
  (define (repl-finish! session)
    (process! session (repl-session-pending session) #t))

  (define (process! session text final?)
    (call-with-string-output-port
     (lambda (out)
       (let loop ([text text])
         (let-values ([(status value rest) (read-one text final?)])
           (repl-session-pending-set! session (if (eq? status 'incomplete) text rest))
           (case status
             [(datum) (eval-print value (repl-session-environment session) out) (loop rest)]
             [(error) (print-condition value out)]
             [else (void)]))))))

  ;; Returns (values status value rest) with status one of datum, incomplete, error, empty.
  (define (read-one text final?)
    (let ([port (open-string-input-port text)])
      (guard (c [(and (not final?) (lexical-eof? c)) (values 'incomplete #f text)]
                [else (values 'error c "")])
        (let* ([datum (read port)]
               [pos (port-position port)]
               [rest (substring text pos (string-length text))])
          (cond
            [(eof-object? datum) (values 'empty #f "")]
            ;; `abc` or `42` at the very end may still be growing in the next chunk.
            [(and (not final?) (string=? rest "") (not (delimited-end? text pos)))
             (values 'incomplete #f text)]
            [else (values 'datum datum rest)])))))

  (define (delimited-end? text pos)
    (and (> pos 0) (memv (string-ref text (- pos 1)) '(#\) #\] #\" #\|)) #t))

  ;; Chez's reader raises "~? at char ~a of ~s" with the real message in the irritants,
  ;; so match against the rendered condition.
  (define (lexical-eof? c)
    (and (lexical-violation? c)
         (string-contains? (call-with-string-output-port (lambda (p) (display-condition c p)))
                           "unexpected end-of-file")))

  (define (string-contains? s sub)
    (let ([n (string-length s)] [m (string-length sub)])
      (let loop ([i 0])
        (cond
          [(> (+ i m) n) #f]
          [(string=? (substring s i (+ i m)) sub) #t]
          [else (loop (+ i 1))]))))

  (define (eval-print datum env out)
    (guard (c [else (print-condition c out)])
      (call-with-values
       (lambda ()
         (parameterize ([current-output-port out] [current-error-port out])
           (eval datum env)))
       (lambda vals
         (for-each (lambda (v)
                     (unless (eq? v (void))
                       (write v out)
                       (newline out)))
                   vals)))))

  (define (print-condition c out)
    (if (condition? c)
        (display-condition c out)
        (format out "Exception: non-condition object raised: ~s" c))
    (newline out)))
