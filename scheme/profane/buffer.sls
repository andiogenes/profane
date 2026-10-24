;;; (profane buffer) — buffers, point, markers, undo and file contents. Unstable API (plan §10).
;;;
;;; Emacs-familiar names with Scheme conventions: positions are 0-based character positions
;;; (like string indices; Emacs's point-min is 1), predicates end in `?` (bob?, eol?), and `!`
;;; marks setters of objects (set-marker!). Editing primitives keep their Emacs names.
;;; Text lives in the C piece tree; a raw invalid byte reads as U+FFFD but stays intact in the
;;; buffer and on save.

(library (profane buffer)
  (export buffer? buffer-name buffer-live? buffer-file-name buffer-list
          get-buffer get-buffer-create generate-new-buffer kill-buffer
          current-buffer set-buffer with-current-buffer
          point point-min point-max buffer-size goto-char
          insert delete-region delete-char buffer-substring buffer-string
          char-after char-before forward-char backward-char
          bob? eob? bol? eol?
          line-beginning-position line-end-position line-number-at-pos forward-line count-lines
          marker? marker-buffer marker-position copy-marker set-marker! delete-marker!
          mark set-mark!
          erase-buffer
          undo-boundary undo redo buffer-disable-undo buffer-enable-undo
          buffer-modified? set-buffer-unmodified!
          find-file-noselect save-buffer
          ;; internal, for other (profane ...) libraries
          %buffer-handle %buffer-point-marker %buffer-locals)
  (import (chezscheme) (profane native))

  ;; ---- buffers ----

  (define-record-type (buffer %make-buffer buffer?)
    (fields (mutable name) (mutable handle) (mutable file-name)
            (mutable point-marker) (mutable mark-marker)
            locals) ; buffer-local variable values: symbol -> value, see (profane var)
    (nongenerative profane-buffer))

  (define-record-type (marker %make-marker marker?)
    (fields (mutable buffer) (mutable id))
    (nongenerative profane-marker))

  (define buffers (make-hashtable string-hash string=?)) ; name -> buffer
  (define buffer-order '())                              ; most recently created first

  (define (buffer-live? b) (and (buffer-handle b) #t))
  (define (%buffer-handle b) (live-handle b '%buffer-handle))
  (define (%buffer-point-marker b) (buffer-point-marker b))
  (define (%buffer-locals b) (buffer-locals b))

  (define (live-handle b who)
    (or (buffer-handle b) (error who "buffer has been killed" (buffer-name b))))

  (define (buffer-list) (filter buffer-live? buffer-order))

  (define (get-buffer name)
    (if (buffer? name) name (hashtable-ref buffers name #f)))

  (define (unique-name name)
    (if (not (hashtable-contains? buffers name))
        name
        (let loop ([i 2])
          (let ([candidate (format "~a<~a>" name i)])
            (if (hashtable-contains? buffers candidate) (loop (+ i 1)) candidate)))))

  (define (new-buffer name bytes)
    (let ([h (%buf-new bytes (bytevector-length bytes))])
      (when (zero? h) (error 'generate-new-buffer "out of memory" name))
      (let ([b (%make-buffer name h #f #f #f (make-eq-hashtable))])
        (buffer-point-marker-set! b (%buf-marker-new h 0 #f))
        (hashtable-set! buffers name b)
        (set! buffer-order (cons b buffer-order))
        b)))

  (define (generate-new-buffer name) (new-buffer (unique-name name) #vu8()))

  (define (get-buffer-create name)
    (or (get-buffer name) (new-buffer name #vu8())))

  (define (kill-buffer b)
    (let ([b (get-buffer b)])
      (when (and b (buffer-live? b))
        (%buf-free (buffer-handle b))
        (buffer-handle-set! b #f)
        (hashtable-delete! buffers (buffer-name b))
        (set! buffer-order (remq b buffer-order))
        (when (eq? b current) (set! current #f)))))

  ;; The current buffer; *scratch* is created on first use.
  (define current #f)

  (define (current-buffer)
    (unless (and current (buffer-live? current))
      (set! current (get-buffer-create "*scratch*")))
    current)

  (define (set-buffer b)
    (let ([buf (get-buffer b)])
      (unless (and buf (buffer-live? buf)) (error 'set-buffer "no such live buffer" b))
      (set! current buf)
      buf))

  ;; Expansions may not assign `current` in user code, so the macro calls into the library.
  (define (call-with-buffer b thunk)
    (let ([saved #f])
      (dynamic-wind
        (lambda () (set! saved current) (set-buffer b))
        thunk
        (lambda () (set! current saved)))))

  (define-syntax with-current-buffer
    (syntax-rules ()
      [(_ b body ...) (call-with-buffer b (lambda () body ...))]))

  (define (h who) (live-handle (current-buffer) who))

  ;; ---- point ----

  (define (point-min) 0)
  (define (point-max) (%buf-chars (h 'point-max)))
  (define (buffer-size) (point-max))

  (define (point) (%buf-marker-pos (h 'point) (buffer-point-marker (current-buffer))))

  (define (clamp pos) (max 0 (min pos (point-max))))

  (define (goto-char pos)
    (let ([pos (clamp (position-of pos))])
      (%buf-marker-set (h 'goto-char) (buffer-point-marker (current-buffer)) pos)
      pos))

  (define (position-of x) (if (marker? x) (marker-position x) x))

  ;; ---- text ----

  (define (insert . things)
    (for-each
     (lambda (x)
       (let* ([s (cond [(string? x) x] [(char? x) (string x)]
                       [else (error 'insert "not a string or character" x)])]
              [bv (string->utf8 s)]
              [at (point)])
         (unless (zero? (%buf-insert (h 'insert) at bv (bytevector-length bv)))
           (error 'insert "out of memory"))
         (goto-char (+ at (string-length s)))))
     things))

  (define (check-region who start end)
    (let ([start (position-of start)] [end (position-of end)])
      (let ([lo (min start end)] [hi (max start end)])
        (unless (and (>= lo 0) (<= hi (point-max)))
          (error who "region out of range" start end))
        (values lo hi))))

  (define (delete-region start end)
    (let-values ([(lo hi) (check-region 'delete-region start end)])
      (%buf-delete (h 'delete-region) lo hi)))

  (define delete-char
    (case-lambda
      [() (delete-char 1)]
      [(n) (let ([p (point)])
             (if (>= n 0)
                 (begin (when (> (+ p n) (point-max)) (error 'delete-char "end of buffer"))
                        (delete-region p (+ p n)))
                 (begin (when (< (+ p n) 0) (error 'delete-char "beginning of buffer"))
                        (delete-region (+ p n) p))))]))

  ;; utf8->string agrees with the core whenever the text is valid UTF-8; otherwise the counts
  ;; differ and the range is decoded character by character, raw bytes as U+FFFD.
  (define (buffer-substring start end)
    (let-values ([(lo hi) (check-region 'buffer-substring start end)])
      (let* ([handle (h 'buffer-substring)]
             [n (%buf-range-bytes handle lo hi)]
             [bv (make-bytevector n)])
        (%buf-copy handle lo hi bv n)
        (let ([s (utf8->string bv)])
          (if (= (string-length s) (- hi lo))
              s
              (let ([out (make-string (- hi lo))])
                (do ([i lo (+ i 1)]) ((= i hi) out)
                  (string-set! out (- i lo) (integer->char (%buf-char-at handle i))))))))))

  (define (buffer-string) (buffer-substring 0 (point-max)))
  (define (erase-buffer) (delete-region 0 (point-max)))

  (define char-after
    (case-lambda
      [() (char-after (point))]
      [(pos) (let ([c (%buf-char-at (h 'char-after) (position-of pos))])
               (and (>= c 0) (integer->char c)))]))

  (define char-before
    (case-lambda
      [() (char-before (point))]
      [(pos) (let ([pos (position-of pos)]) (and (> pos 0) (char-after (- pos 1))))]))

  (define forward-char
    (case-lambda
      [() (forward-char 1)]
      [(n) (let ([target (+ (point) n)])
             (cond [(< target 0) (goto-char 0) (error 'forward-char "beginning of buffer")]
                   [(> target (point-max)) (goto-char (point-max))
                    (error 'forward-char "end of buffer")]
                   [else (goto-char target)]))]))

  (define backward-char
    (case-lambda [() (forward-char -1)] [(n) (forward-char (- n))]))

  (define (bob?) (= (point) 0))
  (define (eob?) (= (point) (point-max)))
  (define (bol?) (or (bob?) (eqv? (char-before) #\newline)))
  (define (eol?) (or (eob?) (eqv? (char-after) #\newline)))

  ;; ---- lines (0-based line numbers internally; line-number-at-pos is 1-based, as shown) ----

  (define (line-index pos) (%buf-line-of (h 'line) pos))
  (define (line-start line) (%buf-line-start (h 'line) line))

  (define (line-end-of line)
    (let ([next (line-start (+ line 1))])
      (if (and (> next 0) (eqv? (char-after (- next 1)) #\newline)) (- next 1) next)))

  (define line-beginning-position
    (case-lambda
      [() (line-beginning-position 1)]
      [(n) (line-start (max 0 (+ (line-index (point)) (- n 1))))]))

  (define line-end-position
    (case-lambda
      [() (line-end-position 1)]
      [(n) (line-end-of (max 0 (+ (line-index (point)) (- n 1))))]))

  (define line-number-at-pos
    (case-lambda
      [() (line-number-at-pos (point))]
      [(pos) (+ 1 (line-index (position-of pos)))]))

  ;; Moves to the start of the Nth line from here and returns how many lines were left to move
  ;; (negative going backward), as Emacs does: a non-empty last line counts as moved.
  (define forward-line
    (case-lambda
      [() (forward-line 1)]
      [(n) (let* ([last (- (%buf-lines (h 'forward-line)) 1)]
                  [target (+ (line-index (point)) n)])
             (cond
               [(< target 0) (goto-char 0) target]
               [(> target last)
                (goto-char (point-max))
                (- target last (if (bol?) 0 1))]
               [else (goto-char (line-start target)) 0]))]))

  (define (count-lines start end)
    (let-values ([(lo hi) (check-region 'count-lines start end)])
      (if (= lo hi)
          0
          (+ (- (line-index hi) (line-index lo))
             (if (eqv? (char-before hi) #\newline) 0 1)))))

  ;; ---- markers ----

  (define copy-marker
    (case-lambda
      [(pos) (copy-marker pos #f)]
      [(pos advances?)
       (let* ([b (current-buffer)]
              [id (%buf-marker-new (h 'copy-marker) (clamp (position-of pos)) advances?)])
         (when (zero? id) (error 'copy-marker "out of memory"))
         (%make-marker b id))]))

  (define (marker-position m)
    (let ([b (marker-buffer m)])
      (and b (buffer-live? b)
           (let ([pos (%buf-marker-pos (buffer-handle b) (marker-id m))])
             (and (>= pos 0) pos)))))

  (define (set-marker! m pos)
    (let ([b (marker-buffer m)])
      (unless (and b (buffer-live? b)) (error 'set-marker! "marker points nowhere" m))
      (%buf-marker-set (buffer-handle b) (marker-id m) (max 0 (position-of pos)))
      m))

  (define (delete-marker! m)
    (let ([b (marker-buffer m)])
      (when (and b (buffer-live? b))
        (%buf-marker-free (buffer-handle b) (marker-id m)))
      (marker-buffer-set! m #f)))

  (define (mark)
    (let ([m (buffer-mark-marker (current-buffer))])
      (and m (%buf-marker-pos (h 'mark) m))))

  (define (set-mark! pos)
    (let* ([b (current-buffer)] [m (buffer-mark-marker b)] [pos (clamp (position-of pos))])
      (if m
          (%buf-marker-set (h 'set-mark!) m pos)
          (buffer-mark-marker-set! b (%buf-marker-new (h 'set-mark!) pos #f)))
      pos))

  ;; ---- undo ----

  (define (undo-boundary) (%buf-undo-boundary (h 'undo-boundary)) (void))

  (define (undo-or-redo native who)
    (let ([pos (native (h who))])
      (when (< pos 0) (error who (if (eq? who 'undo) "no further undo information"
                                     "no further redo information")))
      (goto-char pos)))

  ;; Emacs buffer-disable-undo: stops recording and drops the history (internal buffers such
  ;; as the echo area, whose text is replaced over and over).
  (define (buffer-disable-undo) (%buf-set-undo (h 'buffer-disable-undo) #f) (void))
  (define (buffer-enable-undo) (%buf-set-undo (h 'buffer-enable-undo) #t) (void))

  (define (undo) (undo-or-redo %buf-undo 'undo))
  (define (redo) (undo-or-redo %buf-redo 'redo))

  (define (buffer-modified?) (= 1 (%buf-modified (h 'buffer-modified?))))
  (define (set-buffer-unmodified!) (%buf-mark-saved (h 'set-buffer-unmodified!)) (void))

  ;; ---- files ----

  (define (read-file-bytes path)
    (let* ([port (open-file-input-port path)]
           [bv (get-bytevector-all port)])
      (close-port port)
      (if (eof-object? bv) #vu8() bv)))

  (define (file-name-nondirectory path)
    (let loop ([i (- (string-length path) 1)])
      (cond [(< i 0) path]
            [(char=? (string-ref path i) #\/) (substring path (+ i 1) (string-length path))]
            [else (loop (- i 1))])))

  ;; Returns the buffer visiting PATH, reading the file (bytes unchanged) if needed.
  (define (find-file-noselect path)
    (or (find (lambda (b) (equal? (buffer-file-name b) path)) (buffer-list))
        (let ([b (new-buffer (unique-name (file-name-nondirectory path))
                             (if (file-exists? path) (read-file-bytes path) #vu8()))])
          (buffer-file-name-set! b path)
          b)))

  ;; Writes the whole buffer to its file atomically (temp file + rename).
  (define (save-buffer)
    (let* ([b (current-buffer)] [path (buffer-file-name b)])
      (unless path (error 'save-buffer "buffer is not visiting a file" (buffer-name b)))
      (let* ([handle (h 'save-buffer)]
             [end (%buf-chars handle)]
             [n (%buf-range-bytes handle 0 end)]
             [bv (make-bytevector n)]
             [tmp (string-append path ".profane-save")])
        (%buf-copy handle 0 end bv n)
        (let ([port (open-file-output-port tmp (file-options no-fail))])
          (put-bytevector port bv)
          (close-port port))
        (rename-file tmp path)
        (%buf-mark-saved handle)
        path))))
