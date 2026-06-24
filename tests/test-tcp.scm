;; Offline TCP tests for (kaappi net)
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

;; --- TCP loopback ---
(display "=== TCP loopback ===") (newline)

(let ((listen-fd (tcp-listen "127.0.0.1" 19100)))
  (check "listen returns positive fd" #t (> listen-fd 0))

  (let ((client-fd (tcp-connect "127.0.0.1" 19100)))
    (check "connect returns positive fd" #t (> client-fd 0))

    (let ((server-fd (tcp-accept listen-fd)))
      (check "accept returns positive fd" #t (> server-fd 0))

      ;; client → server
      (let* ((msg (string->utf8 "hello"))
             (n (tcp-send client-fd msg (bytevector-length msg))))
        (check "send 5 bytes" 5 n))

      (let ((buf (make-bytevector 256 0)))
        (let ((n (tcp-recv server-fd buf 256)))
          (check "recv 5 bytes" 5 n)
          (check "recv content" "hello"
            (utf8->string (bytevector-copy buf 0 n)))))

      ;; server → client
      (let* ((reply (string->utf8 "world"))
             (n (tcp-send server-fd reply (bytevector-length reply))))
        (check "send reply" 5 n))

      (let ((buf (make-bytevector 256 0)))
        (let ((n (tcp-recv client-fd buf 256)))
          (check "recv reply" 5 n)
          (check "recv reply content" "world"
            (utf8->string (bytevector-copy buf 0 n)))))

      ;; larger message
      (let* ((big (make-bytevector 4000 65))
             (n (tcp-send client-fd big (bytevector-length big))))
        (check "send 4000 bytes" 4000 n))

      (let ((buf (make-bytevector 8192 0)))
        (let ((n (tcp-recv server-fd buf 8192)))
          (check "recv 4000 bytes" 4000 n)
          (check "recv big first byte" 65 (bytevector-u8-ref buf 0))
          (check "recv big last byte" 65 (bytevector-u8-ref buf 3999))))

      (tcp-close server-fd))
    (tcp-close client-fd))
  (tcp-close listen-fd))

;; --- Non-blocking ---
(display "=== Non-blocking ===") (newline)

(let ((listen-fd (tcp-listen "127.0.0.1" 19101)))

  ;; set-nonblocking on listen socket
  (let ((rc (set-nonblocking listen-fd)))
    (check "set-nonblocking ok" 0 rc))

  ;; nb-accept on empty socket returns -2 (EAGAIN)
  (let ((rc (nb-accept listen-fd)))
    (check "nb-accept empty returns -2" -2 rc))

  ;; poll-read with short timeout on empty socket returns 0
  (let ((rc (poll-read listen-fd 10)))
    (check "poll-read timeout returns 0" 0 rc))

  ;; connect a client so poll-read and nb-accept succeed
  (let ((client-fd (tcp-connect "127.0.0.1" 19101)))
    ;; poll-read should now find the pending connection
    (let ((rc (poll-read listen-fd 100)))
      (check "poll-read with pending connection" 1 rc))

    ;; nb-accept should succeed
    (let ((server-fd (nb-accept listen-fd)))
      (check "nb-accept with pending client" #t (> server-fd 0))

      ;; send data and poll-read on the receiving end
      (let* ((msg (string->utf8 "async"))
             (n (tcp-send client-fd msg 5)))
        (check "async send" 5 n))

      (let ((rc (poll-read server-fd 100)))
        (check "poll-read data ready" 1 rc))

      (let ((buf (make-bytevector 64 0)))
        (let ((n (tcp-recv server-fd buf 64)))
          (check "async recv" 5 n)
          (check "async recv content" "async"
            (utf8->string (bytevector-copy buf 0 n)))))

      (tcp-close server-fd))
    (tcp-close client-fd))
  (tcp-close listen-fd))

;; --- tcp-last-error ---
(display "=== Error handling ===") (newline)

;; tcp-last-error returns an integer
(let ((err (tcp-last-error)))
  (check "tcp-last-error returns integer" #t (integer? err)))

;; connecting to a refused port should raise an error
(check "connect to refused port raises"
  #t
  (guard (e (#t #t))
    (tcp-connect "127.0.0.1" 19199 100)
    #f))

;; --- tcp-close ---
(display "=== Close ===") (newline)

(let ((fd (tcp-listen "127.0.0.1" 19102)))
  (let ((rc (tcp-close fd)))
    (check "close returns 0" 0 rc)))

;; --- Results ---
(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
