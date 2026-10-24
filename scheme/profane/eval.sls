;;; (profane eval) — evaluating Scheme from the editor: M-: (eval-expression), C-x C-e
;;; (eval-last-sexp), eval-region, eval-buffer and load-file. Unstable API (plan §10).
;;;
;;; Code runs in the interaction environment, the one the socket REPL uses, so it sees the same
;;; libraries. Results are written, one per line, with whatever the code printed, into the echo
;;; area (and *Messages*); an error shows its message instead. A looping evaluation blocks the
;;; editor: C-g cannot interrupt it until engines exist (plan §0).

(library (profane eval)
  (export eval-string last-sexp-bounds)
  (import (chezscheme) (profane buffer) (profane command) (profane keymap) (profane minibuffer)
          (profane files) (profane repl))

  ;; Evaluates every datum in TEXT; returns what they printed and returned (or the error) as
  ;; one string without the final newline.
  (define (eval-string text)
    (let* ([session (make-repl-session)]
           [fed (repl-feed! session text)]       ; in order: Chez evaluates arguments in any order
           [rest (repl-finish! session)]
           [out (string-append fed rest)]
           [n (string-length out)])
      (if (and (> n 0) (char=? (string-ref out (- n 1)) #\newline))
          (substring out 0 (- n 1))
          out)))

  (define (show-result text)
    (if (string=? text "") (message "Evaluated") (message "~a" text)))

  ;; ---- the expression before point ----
  ;; The text up to point is cut into tokens (open, close, string, atom), skipping comments;
  ;; the last token ends the expression, and for a close its partner begins it.

  (define (delimiter? c)
    (or (char-whitespace? c) (memv c '(#\( #\) #\[ #\] #\" #\;))))

  ;; Tokens of TEXT as a list of (kind start end), in order.
  (define (tokenize text)
    (let ([n (string-length text)])
      (define (at i) (and (< i n) (string-ref text i)))
      (let loop ([i 0] [acc '()])
        (let ([c (at i)])
          (cond
            [(not c) (reverse acc)]
            [(char-whitespace? c) (loop (+ i 1) acc)]
            [(char=? c #\;)
             (let skip ([j i]) (if (and (at j) (not (char=? (at j) #\newline))) (skip (+ j 1)) (loop j acc)))]
            [(and (char=? c #\#) (eqv? (at (+ i 1)) #\|))
             (let skip ([j (+ i 2)] [depth 1])
               (cond [(not (at j)) (loop j acc)]
                     [(and (eqv? (at j) #\|) (eqv? (at (+ j 1)) #\#))
                      (if (= depth 1) (loop (+ j 2) acc) (skip (+ j 2) (- depth 1)))]
                     [(and (eqv? (at j) #\#) (eqv? (at (+ j 1)) #\|)) (skip (+ j 2) (+ depth 1))]
                     [else (skip (+ j 1) depth)]))]
            [(memv c '(#\( #\[)) (loop (+ i 1) (cons (list 'open i (+ i 1)) acc))]
            [(memv c '(#\) #\])) (loop (+ i 1) (cons (list 'close i (+ i 1)) acc))]
            [(char=? c #\")
             (let str ([j (+ i 1)])
               (cond [(not (at j)) (loop j (cons (list 'string i j) acc))]
                     [(char=? (at j) #\\) (str (+ j 2))]
                     [(char=? (at j) #\") (loop (+ j 1) (cons (list 'string i (+ j 1)) acc))]
                     [else (str (+ j 1))]))]
            [else
             ;; an atom; #\x is a character literal (#\( too), the rest runs to a delimiter
             (let ([start (if (and (char=? c #\#) (eqv? (at (+ i 1)) #\\)) (+ i 3) (+ i 1))])
               (let atom ([j start])
                 (if (and (at j) (not (delimiter? (at j))))
                     (atom (+ j 1))
                     (loop j (cons (list 'atom i j) acc)))))])))))

  ;; Quote marks and # stuck to the front of an expression belong to it.
  (define (with-prefix text start)
    (let back ([s start])
      (if (and (> s 0) (memv (string-ref text (- s 1)) '(#\' #\` #\, #\@ #\#)))
          (back (- s 1))
          s)))

  ;; (values start end) of the expression ending last before POS in TEXT's first POS characters.
  (define (last-sexp-bounds text pos)
    (let* ([prefix (substring text 0 pos)]
           [tokens (tokenize prefix)])
      (when (null? tokens) (error 'eval-last-sexp "no expression before point"))
      (let ([last (car (reverse tokens))])
        (case (car last)
          [(open) (error 'eval-last-sexp "no complete expression before point")]
          [(close)
           ;; match backward through the tokens, counting depth
           (let loop ([ts (cdr (reverse tokens))] [depth 1])
             (cond
               [(null? ts) (error 'eval-last-sexp "unbalanced parentheses")]
               [(eq? (caar ts) 'close) (loop (cdr ts) (+ depth 1))]
               [(eq? (caar ts) 'open)
                (if (= depth 1)
                    (values (with-prefix prefix (cadar ts)) (caddr last))
                    (loop (cdr ts) (- depth 1)))]
               [else (loop (cdr ts) depth)]))]
          [else (values (with-prefix prefix (cadr last)) (caddr last))]))))

  ;; ---- commands ----

  (define-command (eval-expression)
    "Read a Scheme expression in the minibuffer, evaluate it and show the result."
    (read-from-minibuffer "Eval: " (lambda (text) (show-result (eval-string text)))
                          "" 'history 'eval-expression))

  (define-command (eval-last-sexp)
    "Evaluate the expression before point and show the result."
    (let-values ([(start end) (last-sexp-bounds (buffer-string) (point))])
      (show-result (eval-string (buffer-substring start end)))))

  (define-command (eval-region)
    "Evaluate the text between point and the mark."
    (unless (mark) (error 'eval-region "the mark is not set"))
    (show-result (eval-string (buffer-substring (min (point) (mark)) (max (point) (mark))))))

  (define-command (eval-buffer)
    "Evaluate the whole buffer."
    (show-result (eval-string (buffer-string))))

  (define (read-text-file path)
    (call-with-port (open-file-input-port path)
      (lambda (p) (utf8->string (get-bytevector-all p)))))

  (define-command (load-file)
    "Evaluate a file chosen in the minibuffer, like load."
    (read-file-name "Load file: "
                    (lambda (path)
                      (if (file-exists? path)
                          (show-result (eval-string (read-text-file path)))
                          (message "~a does not exist" path)))))

  (define bindings
    (for-each (lambda (b) (define-key! (global-map) (car b) (cdr b)))
              '(("M-:" . eval-expression) ("C-x C-e" . eval-last-sexp)))))
