;; Reactor-integrated socket ports (#1478): socket-port / tcp-accept-port /
;; tcp-connect-port wrap a socket fd as a Kaappi port whose reads and writes
;; go through the fiber I/O reactor, so a blocking-looking read on a fiber
;; server suspends that fiber (and lets siblings run) instead of the 1ms
;; poll-then-sleep loop the raw tcp-recv path forced.
(import (scheme base) (scheme write) (kaappi ffi) (kaappi net) (kaappi fibers))

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

;; --- Sequential transfer over reactor-integrated ports ---
(display "=== socket-port sequential ===") (newline)
(let ((listen-fd (tcp-listen "127.0.0.1" 19110)))
  ;; connect + accept at top level (loopback backlog completes them); wrap
  ;; both ends as ports for the data transfer.
  (let* ((cfd (tcp-connect "127.0.0.1" 19110))
         (sfd (tcp-accept listen-fd))
         (cp (socket-port cfd))
         (sp (socket-port sfd)))
    (write-u8 65 cp)
    (write-bytevector (string->utf8 "BC") cp)
    (flush-output-port cp)
    (check "server reads first byte" 65 (read-u8 sp))
    (let ((buf (make-bytevector 2 0)))
      (read-bytevector! buf sp)
      (check "server reads the rest" "BC" (utf8->string buf)))
    ;; close-port owns the fd; don't tcp-close these two again.
    (close-port cp)
    (close-port sp))
  (tcp-close listen-fd))

;; --- Fiber server + client: the read must PARK on the reactor, not spin ---
(display "=== socket-port fibers (reactor wakeup) ===") (newline)
(let ((listen-fd (tcp-listen "127.0.0.1" 19111)))
  (let* ((cfd (tcp-connect "127.0.0.1" 19111))
         (sfd (tcp-accept listen-fd))
         (cp (socket-port cfd))
         (sp (socket-port sfd))
         (got #f))
    ;; Server fiber blocks on read (parks on the reactor until the client
    ;; writes), then echoes the byte + 1.
    (define server
      (spawn (lambda ()
               (let ((b (read-u8 sp)))
                 (set! got b)
                 (write-u8 (+ b 1) sp)
                 (flush-output-port sp)))))
    ;; Client fiber writes, then blocks on read for the echo (parks too).
    (define client
      (spawn (lambda ()
               (write-u8 65 cp)
               (flush-output-port cp)
               (read-u8 cp))))
    (let ((reply (fiber-join client)))
      (fiber-join server)
      (check "server received the byte via a parked read" 65 got)
      (check "client received the echo via a parked read" 66 reply))
    (close-port cp)
    (close-port sp))
  (tcp-close listen-fd))

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
