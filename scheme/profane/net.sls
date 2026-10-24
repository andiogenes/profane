;;; (profane net) — network connections over TCP, with TLS. Unstable API (plan §10).
;;;
;;;   (define c (open-network-stream "example.com" 443
;;;               '((tls . #t) (filter . ,(lambda (c bytes) ...)) (sentinel . ,(lambda (c event) ...)))))
;;;   (await (connection-ready c))
;;;   (connection-send c "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
;;;
;;; Connecting is asynchronous (Network.framework, in the macOS shell). Options (an alist): tls (#t:
;;; TLS, verified against the system's trust and the host name), insecure (with tls: accept any
;;; certificate, for tests and self-signed servers), alpn (a list of protocol names to offer, e.g.
;;; ("h2" "http/1.1"); connection-protocol tells which was chosen), filter ((filter conn bytes):
;;; data arrived, a bytevector), sentinel ((sentinel conn event): "open\n", "closed\n" or
;;; "failed: message\n"). Like processes, data arrives on the main thread between commands and
;;; the shell stops receiving while the editor has not caught up.
;;;
;;; connection-ready is a promise resolved with the connection once it is open and rejected with
;;; an error carrying the system's message if it fails (refused, unreachable, a certificate that
;;; does not verify). Without the macOS shell there are no connections.

(library (profane net)
  (export open-network-stream connection? connection-status connection-open? connection-protocol
          connection-ready connection-send connection-close connection-host connection-port)
  (import (chezscheme) (profane native) (profane buffer) (profane command) (profane async))

  (define-record-type connection
    (fields host port id token (mutable status) (mutable protocol) ready filter sentinel)
    (nongenerative profane-connection))

  (define (connection-open? c) (eq? (connection-status c) 'open))

  (define (opt options key default)
    (let ([a (assq key options)]) (if a (cdr a) default)))

  (define (report who c)
    (message "~a: ~a" who
             (if (condition? c)
                 (call-with-string-output-port (lambda (p) (display-condition c p)))
                 c)))

  (define (call-sentinel c event)
    (when (connection-sentinel c)
      (guard (e [else (report 'connection-sentinel e)])
        ((connection-sentinel c) c event))))

  (define (blob strings)
    (apply bytevector-append* (map (lambda (s) (bytevector-append* (string->utf8 s) (bytevector 0))) strings)))
  (define (bytevector-append* . bvs)
    (let* ([n (fold-left + 0 (map bytevector-length bvs))] [out (make-bytevector n)])
      (let loop ([bvs bvs] [at 0])
        (unless (null? bvs)
          (bytevector-copy! (car bvs) 0 out at (bytevector-length (car bvs)))
          (loop (cdr bvs) (+ at (bytevector-length (car bvs))))))
      out))

  (define (entry name) (and (foreign-entry? name) name))

  ;; Starts connecting to HOST:PORT and returns the connection at once (see connection-ready).
  (define open-network-stream
    (case-lambda
      [(host port) (open-network-stream host port '())]
      [(host port options)
       (unless (entry "pf_net_connect") (error 'open-network-stream "needs the macOS application shell"))
       (let* ([tls (opt options 'tls #f)] [flags (+ (if tls 1 0) (if (and tls (opt options 'insecure #f)) 2 0))]
              [alpn (blob (opt options 'alpn '()))]
              [h (string->utf8 host)]
              [box* (box #f)]
              [token (async-token-new
                      (lambda (kind data) (on-event (unbox box*) kind data)))]
              [id ((foreign-procedure "pf_net_connect" (u8* size_t int int unsigned-64 u8* size_t) integer-64)
                   h (bytevector-length h) port flags token alpn (bytevector-length alpn))])
         (when (< id 0)
           (async-token-release! token)
           (error 'open-network-stream "bad host or port" host port))
         (let ([c (make-connection host port id token 'connecting "" (make-promise)
                                   (opt options 'filter #f) (opt options 'sentinel #f))])
           (set-box! box* c)
           c))]))

  (define (on-event c kind data)
    (case kind
      [(1) (connection-status-set! c 'open)
           (connection-protocol-set! c (utf8->string data))
           (promise-resolve! (connection-ready c) c)
           (call-sentinel c "open\n")]
      [(2) (when (connection-filter c)
             (guard (e [else (report 'connection-filter e)])
               ((connection-filter c) c data)))
           ((foreign-procedure "pf_net_consumed" (unsigned-32 size_t) int)
            (connection-id c) (bytevector-length data))]
      [(3) (finish! c 'closed "closed\n"
                    (condition (make-error) (make-message-condition "connection closed before it opened")))]
      [(4) (let ([message (utf8->string data)])
             (finish! c 'failed (string-append "failed: " message "\n")
                      (condition (make-error) (make-message-condition message) (make-irritants-condition (list (connection-host c))))))]))

  (define (finish! c status event reason)
    (connection-status-set! c status)
    (async-token-release! (connection-token c))
    (promise-reject! (connection-ready c) reason) ; no effect once it has opened
    (call-sentinel c event))

  ;; Sends a bytevector or a string (as UTF-8). #f if the connection is not usable.
  (define (connection-send c data)
    (let ([bv (if (string? data) (string->utf8 data) data)])
      (and (memq (connection-status c) '(connecting open))
           (= 0 ((foreign-procedure "pf_net_send" (unsigned-32 u8* size_t) int)
                 (connection-id c) bv (bytevector-length bv))))))

  (define (connection-close c)
    (and (memq (connection-status c) '(connecting open))
         (= 0 ((foreign-procedure "pf_net_close" (unsigned-32) int) (connection-id c))))))
