(import (chezscheme) (srfi :64) (profane native) (profane buffer) (profane var) (profane mode)
        (profane command) (profane command-loop) (profane window) (profane files)
        (profane display) (profane themes) (profane simple) (profane git marks))

(for-each invoke-library '((profane simple) (profane window) (profane display) (profane themes)
                           (profane files) (profane git marks)))

(test-begin "git-marks")

(define dir (let ([p (format "/tmp/pf-marks-~a" (random 1000000000))])
              (system (format "mkdir -p ~a" p))
              p))
(define file (string-append dir "/a.txt"))
(system (format "cd ~a && printf '1\\n2\\n3\\n4\\n5\\n' > a.txt && printf 'x\\n' > u.txt && git init -q && git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m init" dir))

(define f (select-frame (make-headless-frame 400 300)))
(define b (find-file-noselect file))
(switch-to-buffer b)

(test-equal "unchanged: no marks" '() (diff-hl-buffer-marks b))

(with-current-buffer b
  (goto-char 2)            ; after "1\n"
  (insert "new\n"))
(test-equal "an added line" '((1 1 1)) (diff-hl-buffer-marks b))

(with-current-buffer b
  (goto-char (buffer-size))
  (insert "6\n"))
(test-equal "a second hunk, in line order" '((1 1 1) (6 1 1)) (diff-hl-buffer-marks b))

(with-current-buffer b
  (goto-char 0)
  (delete-char 6))   ; "1\nnew\n"
(test-assert "removing the first line marks the top"
             (equal? (car (diff-hl-buffer-marks b)) '(0 0 3)))

(let ([u (find-file-noselect (string-append dir "/u.txt"))])
  (test-eq "untracked files have none" #f (diff-hl-buffer-marks u)))
(test-eq "so do buffers without a file" #f (diff-hl-buffer-marks (get-buffer-create "nofile")))

;; The mode pushes marks to windows on redisplay without error, and toggles off cleanly.
(set-minor-mode! 'diff-hl-mode #t)
(redisplay-prepare!)
(with-current-buffer b (insert "z"))
(redisplay-prepare!)
(set-minor-mode! 'diff-hl-mode #f)
(redisplay-prepare!)
(test-assert "mode on and off" #t)

(var-set! 'diff-hl-max-size 3)
(test-eq "big buffers are skipped" #f (diff-hl-buffer-marks b))

(system (format "rm -rf ~a" dir))
(delete-headless-frame! f)
(test-end "git-marks")
(test-exit)
