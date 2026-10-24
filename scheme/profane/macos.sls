;;; (profane macos) — what macOS offers beyond the editor: the pasteboard, opening URLs and files,
;;; AppleScript, other apps' window bounds. Unstable API (plan §10).
;;;
;;; Everything here is a foreign entry registered by the shell, absent in the standalone Chez of
;;; the Scheme tests: then the pasteboard has no backend (see set-pasteboard-backend!, which tests
;;; use) and the rest says so. $PROFANE_PASTEBOARD names a private pasteboard to use instead of the
;;; general one.

(library (profane macos)
  (export pasteboard-string pasteboard-set! pasteboard-change-count set-pasteboard-backend!
          open-url open-file run-applescript app-window-bounds)
  (import (chezscheme))

  (define (entry name) (and (foreign-entry? name) name))

  ;; The text the last foreign call kept (see PFMacOS.h), LEN bytes of it.
  (define (stash-string len)
    (let ([bv (make-bytevector len)])
      ((foreign-procedure "pf_app_stash_copy" (u8* size_t) void) bv len)
      (utf8->string bv)))

  (define (need-shell who)
    (error who "needs the macOS application shell"))

  ;; ---- pasteboard ----
  ;; A backend is three procedures: () -> string or #f, (string) -> change count, () -> change
  ;; count. The default talks to NSPasteboard. The change count rises whenever anything (profane
  ;; or another app) replaces the contents, which is how the kill ring notices a copy made elsewhere.

  (define native-backend
    (and (entry "pf_app_pasteboard_string")
         (list (lambda ()
                 (let ([n ((foreign-procedure "pf_app_pasteboard_string" () integer-64))])
                   (and (>= n 0) (stash-string n))))
               (lambda (text)
                 (let ([bv (string->utf8 text)])
                   ((foreign-procedure "pf_app_pasteboard_set" (u8* size_t) integer-64)
                    bv (bytevector-length bv))))
               (lambda () ((foreign-procedure "pf_app_pasteboard_count" () integer-64))))))

  (define backend native-backend)

  ;; GET, SET and COUNT as above, or #f for no pasteboard at all.
  (define set-pasteboard-backend!
    (case-lambda
      [(get set count) (set! backend (list get set count))]
      [(none) (set! backend (and none native-backend))]))

  (define (pasteboard-string) (and backend ((car backend))))
  (define (pasteboard-set! text) (and backend ((cadr backend) text)))
  (define (pasteboard-change-count) (and backend ((caddr backend))))

  ;; ---- opening things ----

  ;; Hands URL (a string with a scheme) to its default app; a file: URL opens the file. ACTIVATE
  ;; #f keeps that app in the background. #f if URL is not a URL.
  (define open-url
    (case-lambda
      [(url) (open-url url #t)]
      [(url activate?)
       (unless (entry "pf_app_open_url") (need-shell 'open-url))
       (let ([bv (string->utf8 url)])
         (= 1 ((foreign-procedure "pf_app_open_url" (u8* size_t int) int)
               bv (bytevector-length bv) (if activate? 1 0))))]))

  (define (percent-encode-path path)
    (let ([out (open-output-string)])
      (for-each
       (lambda (b)
         (if (or (<= 48 b 57) (<= 65 b 90) (<= 97 b 122) (memv b '(45 46 95 126 47)))
             (put-char out (integer->char b))
             (put-string out (string-append "%" (if (< b 16) "0" "") (string-upcase (number->string b 16))))))
       (bytevector->u8-list (string->utf8 path)))
      (get-output-string out)))

  ;; Opens the file or directory at PATH in its default app (like `open PATH`).
  (define open-file
    (case-lambda
      [(path) (open-file path #t)]
      [(path activate?)
       (let ([abs (if (and (> (string-length path) 0) (char=? (string-ref path 0) #\/))
                      path
                      (string-append (current-directory) "/" path))])
         (open-url (string-append "file://" (percent-encode-path abs)) activate?))]))

  ;; ---- AppleScript ----

  ;; Runs SOURCE in this process and returns its result as text (the empty string for a result
  ;; with none, such as a record). Blocks the editor until the script ends, so a script talking to
  ;; a busy app can hang it: wrap the calls in `with timeout of N seconds`. The first script to
  ;; control another app makes macOS ask the user for permission. Raises the script's error.
  (define (run-applescript source)
    (unless (entry "pf_app_applescript") (need-shell 'run-applescript))
    (let* ([bv (string->utf8 source)]
           [n ((foreign-procedure "pf_app_applescript" (u8* size_t) integer-64)
               bv (bytevector-length bv))])
      (if (< n 0)
          (error 'run-applescript (stash-string (- n)) source)
          (stash-string n))))

  ;; ---- other apps' windows ----

  ;; The on-screen windows of the app named APP (as the window server names it: "Google Chrome",
  ;; "Finder") or with process id APP (an integer), front to back, as lists (x y width height) in
  ;; points from the top left of the main display. Needs no permission; titles would, so they are
  ;; not given.
  (define (app-window-bounds app)
    (unless (entry "pf_app_window_bounds") (need-shell 'app-window-bounds))
    (let* ([bv (string->utf8 (if (number? app) (number->string app) app))]
           [n ((foreign-procedure "pf_app_window_bounds" (u8* size_t) integer-64)
               bv (bytevector-length bv))]
           [text (stash-string n)])
      (let loop ([lines (split-lines text)] [out '()])
        (if (null? lines)
            (reverse out)
            (loop (cdr lines)
                  (cons (map string->number (split-words (car lines))) out))))))

  (define (split-on char s)
    (let loop ([cs (string->list s)] [cur '()] [out '()])
      (cond [(null? cs) (reverse (if (null? cur) out (cons (list->string (reverse cur)) out)))]
            [(char=? (car cs) char) (loop (cdr cs) '() (if (null? cur) out (cons (list->string (reverse cur)) out)))]
            [else (loop (cdr cs) (cons (car cs) cur) out)])))
  (define (split-lines s) (split-on #\newline s))
  (define (split-words s) (split-on #\space s)))
