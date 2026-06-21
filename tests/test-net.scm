;; Tests for (kaappi net) — TCP client + TLS client
(import (scheme base) (scheme write) (kaappi ffi) (kaappi net))

(define pass 0)
(define fail 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1))
             (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1))
             (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

;; --- TCP: connect to a known service ---
(display "=== TCP ===") (newline)

;; Start a listener, connect to it, send/recv, close
(let ((listen-fd (tcp-listen "127.0.0.1" 19999)))
  (check "listen ok" #t (> listen-fd 0))

  ;; Connect from client side
  (let ((client-fd (tcp-connect "127.0.0.1" 19999)))
    (check "connect ok" #t (> client-fd 0))

    ;; Accept on server side
    (let ((server-fd (tcp-accept listen-fd)))
      (check "accept ok" #t (> server-fd 0))

      ;; Send from client
      (let* ((msg (string->utf8 "hello"))
             (n (tcp-send client-fd msg (bytevector-length msg))))
        (check "send 5 bytes" 5 n))

      ;; Recv on server
      (let ((buf (make-bytevector 256 0)))
        (let ((n (tcp-recv server-fd buf 256)))
          (check "recv 5 bytes" 5 n)
          (check "recv content" "hello"
            (utf8->string (bytevector-copy buf 0 n)))))

      ;; Send from server, recv on client
      (let* ((reply (string->utf8 "world"))
             (n (tcp-send server-fd reply (bytevector-length reply))))
        (check "send reply" 5 n))

      (let ((buf (make-bytevector 256 0)))
        (let ((n (tcp-recv client-fd buf 256)))
          (check "recv reply" 5 n)
          (check "recv reply content" "world"
            (utf8->string (bytevector-copy buf 0 n)))))

      (tcp-close server-fd))
    (tcp-close client-fd))
  (tcp-close listen-fd))

;; --- TLS: connect to a real HTTPS endpoint ---
(display "=== TLS ===") (newline)

(let ((ssl (tls-connect "api.github.com" 443)))
  (check "tls connect" #t (> ssl 0))

  ;; Send HTTP request
  (let* ((req "GET / HTTP/1.1\r\nHost: api.github.com\r\nUser-Agent: kaappi-net/1.0\r\nConnection: close\r\n\r\n")
         (bv (string->utf8 req))
         (n (tls-send ssl bv (bytevector-length bv))))
    (check "tls send" #t (> n 0)))

  ;; Read response
  (let ((buf (make-bytevector 4096 0)))
    (let ((n (tls-recv ssl buf 4096)))
      (check "tls recv" #t (> n 0))
      (let ((response (utf8->string (bytevector-copy buf 0 (min n 8)))))
        (check "tls http response" "HTTP/1.1" response))))

  (tls-close ssl))

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
