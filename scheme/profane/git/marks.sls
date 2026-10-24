;;; (profane git marks) — thin bars in the left fringe for lines that differ from the index, after
;;; Emacs's diff-hl: green added, blue changed, red a tick where lines were removed. Unstable API
;;; (plan §10).
;;;
;;; diff-hl-mode (global) compares each window's file buffer with the file's version in the index
;;; (libgit2, core/git) whenever the buffer's text changed; buffers that are not files in a
;;; repository, untracked files and buffers over diff-hl-max-size characters show none. The index
;;; is not watched yet (FSEvents, plan §8k): M-x diff-hl-refresh after staging outside profane.

(library (profane git marks)
  (export diff-hl-buffer-marks)
  (import (chezscheme) (profane native) (profane buffer) (profane window) (profane command)
          (profane mode) (profane var) (profane hook))

  (defvar diff-hl-max-size 1000000
    "Buffers with more characters than this get no git marks.")

  (define max-marks 1024)

  ;; The marks of buffer B against the index: a list of (line count kind) with kind 1 added, 2
  ;; changed, 3 removed; #f if B is not a tracked file.
  (define (diff-hl-buffer-marks b)
    (let ([path (buffer-file-name b)])
      (and path
           (<= (with-current-buffer b (buffer-size)) (var-ref 'diff-hl-max-size))
           (let* ([out (make-bytevector (* 12 max-marks) 0)]
                  [pb (string->utf8 path)]
                  [n (%git-buffer-marks (%buffer-handle b) pb (bytevector-length pb) out
                                        max-marks)])
             (and (>= n 0)
                  (let loop ([i (- (min n max-marks) 1)] [acc '()])
                    (if (< i 0)
                        acc
                        (loop (- i 1)
                              (cons (list (bytevector-u32-native-ref out (* 12 i))
                                          (bytevector-u32-native-ref out (+ (* 12 i) 4))
                                          (bytevector-u32-native-ref out (+ (* 12 i) 8)))
                                    acc)))))))))

  ;; window -> (buffer . version) the marks were computed for
  (define shown (make-weak-eq-hashtable))

  (define (push-marks! w marks)
    (let* ([n (length marks)] [bv (make-bytevector (* 12 n) 0)])
      (let loop ([ms marks] [i 0])
        (unless (null? ms)
          (bytevector-u32-native-set! bv (* 12 i) (car (car ms)))
          (bytevector-u32-native-set! bv (+ (* 12 i) 4) (cadr (car ms)))
          (bytevector-u32-native-set! bv (+ (* 12 i) 8) (caddr (car ms)))
          (loop (cdr ms) (+ i 1))))
      (%win-set-line-marks (%window-handle w) bv n)))

  (define (update-window! w)
    (unless (window-minibuffer? w)
      (let* ([b (window-buffer w)]
             [key (cons b (if (var-ref 'diff-hl-mode) (%buf-version (%buffer-handle b)) #f))]
             [old (hashtable-ref shown w #f)])
        (unless (and old (eq? (car old) (car key)) (equal? (cdr old) (cdr key)))
          (hashtable-set! shown w key)
          (push-marks! w (or (and (var-ref 'diff-hl-mode) (diff-hl-buffer-marks b)) '()))))))

  (define (update-all! f) (for-each update-window! (window-list f)))

  (define (refresh!)
    (hashtable-clear! shown)
    (let ([f (selected-frame)]) (when f (update-all! f))))

  (define-minor-mode diff-hl-mode (global)
    "Show lines that differ from the index as bars in the left fringe."
    (refresh!))

  (define-command (diff-hl-refresh)
    "Recompute the git marks (after staging or committing outside profane)."
    (refresh!))

  (define installed (begin (add-hook! 'pre-redisplay-hook update-all!) #t)))
