(define-library (kaappi net)
  (import (scheme base) (kaappi fibers) (kaappi ffi))
  (export tcp-connect tcp-listen tcp-listen-reuseport tcp-accept
          reuseport-balances?
          tcp-send tcp-recv tcp-close tcp-last-error
          tls-connect tls-send tls-recv tls-close
          set-nonblocking poll-read poll-write nb-accept)
  (begin

    (define %lib (ffi-open "libkaappi_net"))

    ;; TCP
    (define %connect  (ffi-fn %lib "knet_tcp_connect" '(string int int) 'int))
    (define %listen   (ffi-fn %lib "knet_tcp_listen" '(string int int) 'int))
    (define %listen-reuseport (ffi-fn %lib "knet_tcp_listen_reuseport" '(string int int) 'int))
    (define %reuseport-balances (ffi-fn %lib "knet_reuseport_balances" '() 'int))
    (define %accept   (ffi-fn %lib "knet_tcp_accept" '(int) 'int))
    (define %send     (ffi-fn %lib "knet_tcp_send" '(pointer pointer long) 'int))
    (define %recv     (ffi-fn %lib "knet_tcp_recv" '(pointer pointer long) 'int))
    (define %close    (ffi-fn %lib "knet_tcp_close" '(int) 'int))
    (define %last-error (ffi-fn %lib "knet_last_error" '() 'int))

    ;; TLS
    (define %tls-set-host (ffi-fn %lib "knet_tls_set_host" '(string) 'void))
    (define %tls-connect-start (ffi-fn %lib "knet_tls_connect_start" '(long long) 'pointer))
    (define %tls-handshake (ffi-fn %lib "knet_tls_handshake" '(pointer) 'int))
    (define %tls-get-fd   (ffi-fn %lib "knet_tls_get_fd" '(pointer) 'int))
    (define %tls-send     (ffi-fn %lib "knet_tls_send" '(pointer pointer long) 'int))
    (define %tls-recv     (ffi-fn %lib "knet_tls_recv" '(pointer pointer long) 'int))
    (define %tls-close    (ffi-fn %lib "knet_tls_close" '(pointer) 'void))

    ;; --- TCP API ---

    (define (tcp-connect host port . args)
      (let ((timeout (if (pair? args) (car args) 5000)))
        (let ((fd (%connect host port timeout)))
          (if (< fd 0)
              (error "tcp-connect failed" host port (%last-error))
              fd))))

    (define (tcp-listen host port . args)
      (let ((backlog (if (pair? args) (car args) 128)))
        (let ((fd (%listen host port backlog)))
          (if (< fd 0)
              (error "tcp-listen failed" host port (%last-error))
              fd))))

    ;; Like tcp-listen but sets SO_REUSEPORT, so several sockets (one per OS
    ;; thread, typically) can bind the same port. On Linux the kernel then
    ;; load-balances inbound connections across them; this is the foundation
    ;; of http-listen-parallel's kernel-balanced path. See
    ;; research/reuseport-accept-distribution/ for why Darwin needs a
    ;; userspace fallback instead.
    (define (tcp-listen-reuseport host port . args)
      (let ((backlog (if (pair? args) (car args) 128)))
        (let ((fd (%listen-reuseport host port backlog)))
          (if (< fd 0)
              (error "tcp-listen-reuseport failed" host port (%last-error))
              fd))))

    ;; #t iff SO_REUSEPORT load-balances accepts across sockets on this
    ;; platform (Linux), #f where it does not (Darwin/BSD). A parallel
    ;; server uses this to choose the kernel-balanced path vs a userspace
    ;; fd distributor.
    (define (reuseport-balances?) (= 1 (%reuseport-balances)))

    (define (tcp-accept listen-fd)
      (let ((fd (%accept listen-fd)))
        (if (< fd 0)
            (error "tcp-accept failed" (%last-error))
            fd)))

    (define (tcp-send fd buf len)
      (let ((n (%send buf fd len)))
        (if (< n 0) (error "tcp-send failed" (%last-error)) n)))

    (define (tcp-recv fd buf len)
      (let ((n (%recv buf fd len)))
        (if (< n 0) (error "tcp-recv failed" (%last-error)) n)))

    (define (tcp-close fd)
      (let ((rc (%close fd)))
        (if (< rc 0) (error "tcp-close failed" (%last-error)) rc)))

    (define (tcp-last-error) (%last-error))

    ;; --- Non-blocking API ---
    ;;
    ;; SUPERSEDED (kaappi >= 0.15, KEP-0001 Phase 3, kaappi/kaappi#1441):
    ;; the core port layer now suspends the calling fiber on EAGAIN via the
    ;; per-thread reactor, so manual set-nonblocking / poll-read / nb-accept
    ;; polling loops are no longer the recommended way to multiplex
    ;; connections — spawn one fiber per connection and let blocking reads
    ;; and writes park it instead. These helpers remain for compatibility
    ;; and for code that must run on older kaappi releases.

    (define %set-nonblocking (ffi-fn %lib "knet_set_nonblocking" '(int) 'int))
    (define %poll-read       (ffi-fn %lib "knet_poll_read" '(int int) 'int))
    (define %poll-write      (ffi-fn %lib "knet_poll_write" '(int int) 'int))
    (define %nb-accept       (ffi-fn %lib "knet_nb_accept" '(int) 'int))

    (define (set-nonblocking fd)
      (let ((rc (%set-nonblocking fd)))
        (if (< rc 0) (error "set-nonblocking failed" (%last-error)) rc)))

    (define (poll-read fd timeout-ms)
      (%poll-read fd timeout-ms))

    (define (poll-write fd timeout-ms)
      (%poll-write fd timeout-ms))

    (define (nb-accept listen-fd)
      (%nb-accept listen-fd))

    ;; --- TLS API ---
    ;;
    ;; The underlying fd is non-blocking from the moment it's created
    ;; (knet_tls_connect_start). Handshake/send/recv can each ask for
    ;; either direction (SSL_ERROR_WANT_READ/WANT_WRITE — renegotiation
    ;; means a "recv" can legitimately want to write and vice versa), so
    ;; every retry polls whichever direction the sentinel names for a
    ;; short bounded slice (%tls-poll-timeout-ms), then calls (yield) so
    ;; an already-ready sibling fiber gets a turn before the next attempt.
    ;;
    ;; (yield) here is a deliberate design choice: yield sets a flag the
    ;; *existing* dispatch loop checks, so it returns up through one frame
    ;; instead of recursing into a new one — a flat suspend/resume, the
    ;; same shape waitForFd uses for other blocking I/O.
    ;;
    ;; Historical note: this loop originally used (yield) to work around a
    ;; core bug where thread-sleep! always drove the scheduler via a nested
    ;; runSchedulerStep/runUntil call regardless of the calling fiber's
    ;; context, so two fibers each retrying through many short waits piled
    ;; up that many nested native stack frames (each only unwinding once
    ;; its own timer fired) — under load this showed up as multi-second
    ;; stalls, not a clean hang. That bug was fixed in kaappi core #1463:
    ;; threadSleepFn now takes the same dispatched-from-scheduler
    ;; yield-retry path waitForFd uses, so thread-sleep! is no longer
    ;; dangerous in a retry loop. The (yield) form is kept because yield
    ;; plus a short poll timeout is just as reasonable a design here.

    (define %tls-poll-timeout-ms 1)

    (define (%tls-await fd rc)
      (let ((ready (if (= rc -2) (poll-read fd %tls-poll-timeout-ms) (poll-write fd %tls-poll-timeout-ms))))
        (cond
          ((= ready 1) #t)
          ((= ready 0) (yield) #f)
          (else (error "tls poll failed" (%last-error))))))

    (define (tls-connect host port . args)
      (let ((timeout (if (pair? args) (car args) 5000)))
        (%tls-set-host host)
        (let ((ssl (%tls-connect-start port timeout)))
          (if (= ssl 0)
              (error "tls-connect failed" host port (%last-error))
              (let ((fd (%tls-get-fd ssl)))
                (let loop ()
                  (let ((rc (%tls-handshake ssl)))
                    (cond
                      ((= rc 1) ssl)
                      ((< rc -1)
                       (%tls-await fd rc)
                       (loop))
                      (else
                       (%tls-close ssl)
                       (error "tls-connect failed" host port (%last-error)))))))))))

    (define (tls-send ssl buf len)
      (let ((fd (%tls-get-fd ssl)))
        (let loop ()
          (let ((n (%tls-send buf ssl len)))
            (cond
              ((>= n 0) n)
              ((< n -1) (%tls-await fd n) (loop))
              (else (error "tls-send failed" (%last-error))))))))

    (define (tls-recv ssl buf len)
      (let ((fd (%tls-get-fd ssl)))
        (let loop ()
          (let ((n (%tls-recv buf ssl len)))
            (cond
              ((>= n 0) n)
              ((< n -1) (%tls-await fd n) (loop))
              (else (error "tls-recv failed" (%last-error))))))))

    (define (tls-close ssl)
      (%tls-close ssl))))
