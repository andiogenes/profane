;;; (profane secrets) — passwords and API keys in the macOS Keychain (Emacs's sensitive.el and
;;; auth-source, in effect). Unstable API (plan §10).
;;;
;;;   (secret-set! "profane/anthropic" "api-key" "sk-...")
;;;   (secret-get "profane/anthropic" "api-key")      ; => "sk-..." or #f
;;;
;;; A secret is a string stored as a generic password of the login keychain, found by SERVICE and
;;; ACCOUNT (both strings). The keychain, not profane, holds it: nothing is written to disk by
;;; profane and nothing is kept in memory longer than the caller keeps the string. The first read
;;; of an item by a differently signed build (an ad-hoc build changes with every rebuild) makes
;;; macOS ask the user to allow it. Without the shell (the Scheme tests) there is no keychain: set a
;;; backend with set-secrets-backend!, as the tests of its users do.

(library (profane secrets)
  (export secret-get secret-set! secret-delete! set-secrets-backend!)
  (import (chezscheme))

  (define (stash-string len)
    (let ([bv (make-bytevector len)])
      ((foreign-procedure "pf_app_stash_copy" (u8* size_t) void) bv len)
      (utf8->string bv)))

  ;; The system's message after a call that returned -2.
  (define (stash-error)
    (stash-string ((foreign-procedure "pf_app_stash_length" () integer-64))))

  ;; The keychain, as three procedures: (get service account) -> string or #f,
  ;; (set service account value), (delete service account) -> whether there was one.
  (define native-backend
    (and (foreign-entry? "pf_app_secret_get")
         (let ()
           (list
            (lambda (service account)
              (let* ([s (string->utf8 service)] [a (string->utf8 account)]
                     [n ((foreign-procedure "pf_app_secret_get" (u8* size_t u8* size_t) integer-64)
                         s (bytevector-length s) a (bytevector-length a))])
                (cond [(>= n 0) (stash-string n)]
                      [(= n -1) #f]
                      [else (error 'secret-get (stash-error))])))
            (lambda (service account value)
              (let* ([s (string->utf8 service)] [a (string->utf8 account)] [v (string->utf8 value)]
                     [n ((foreign-procedure "pf_app_secret_set" (u8* size_t u8* size_t u8* size_t) integer-64)
                         s (bytevector-length s) a (bytevector-length a) v (bytevector-length v))])
                (when (< n 0) (error 'secret-set! (stash-error)))))
            (lambda (service account)
              (let* ([s (string->utf8 service)] [a (string->utf8 account)]
                     [n ((foreign-procedure "pf_app_secret_delete" (u8* size_t u8* size_t) integer-64)
                         s (bytevector-length s) a (bytevector-length a))])
                (cond [(= n 0) #t]
                      [(= n -1) #f]
                      [else (error 'secret-delete! (stash-error))])))))))

  (define backend native-backend)

  (define set-secrets-backend!
    (case-lambda
      [(get set delete) (set! backend (list get set delete))]
      [(none) (set! backend (and none native-backend))]))

  (define (need-backend who)
    (or backend (error who "no keychain: needs the macOS application shell")))

  (define (secret-get service account) ((car (need-backend 'secret-get)) service account))
  (define (secret-set! service account value) ((cadr (need-backend 'secret-set!)) service account value))
  (define (secret-delete! service account) ((caddr (need-backend 'secret-delete!)) service account)))
