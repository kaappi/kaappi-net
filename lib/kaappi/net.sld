(define-library (kaappi net)
  (import (scheme base) (kaappi ffi))
  (export tcp-connect tcp-listen tcp-accept
          tcp-send tcp-recv tcp-close tcp-last-error
          tls-connect tls-send tls-recv tls-close
          set-nonblocking poll-read nb-accept)
  (begin

    (define %lib (ffi-open "libkaappi_net"))

    ;; TCP
    (define %connect  (ffi-fn %lib "knet_tcp_connect" '(string int int) 'int))
    (define %listen   (ffi-fn %lib "knet_tcp_listen" '(string int int) 'int))
    (define %accept   (ffi-fn %lib "knet_tcp_accept" '(int) 'int))
    (define %send     (ffi-fn %lib "knet_tcp_send" '(pointer pointer long) 'int))
    (define %recv     (ffi-fn %lib "knet_tcp_recv" '(pointer pointer long) 'int))
    (define %close    (ffi-fn %lib "knet_tcp_close" '(int) 'int))
    (define %last-error (ffi-fn %lib "knet_last_error" '() 'int))

    ;; TLS
    (define %tls-set-host (ffi-fn %lib "knet_tls_set_host" '(string) 'void))
    (define %tls-connect  (ffi-fn %lib "knet_tls_connect" '(long long) 'pointer))
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

    (define %set-nonblocking (ffi-fn %lib "knet_set_nonblocking" '(int) 'int))
    (define %poll-read       (ffi-fn %lib "knet_poll_read" '(int int) 'int))
    (define %nb-accept       (ffi-fn %lib "knet_nb_accept" '(int) 'int))

    (define (set-nonblocking fd)
      (let ((rc (%set-nonblocking fd)))
        (if (< rc 0) (error "set-nonblocking failed" (%last-error)) rc)))

    (define (poll-read fd timeout-ms)
      (%poll-read fd timeout-ms))

    (define (nb-accept listen-fd)
      (%nb-accept listen-fd))

    ;; --- TLS API ---

    (define (tls-connect host port . args)
      (let ((timeout (if (pair? args) (car args) 5000)))
        (%tls-set-host host)
        (let ((ssl (%tls-connect port timeout)))
          (if (= ssl 0)
              (error "tls-connect failed" host port (%last-error))
              ssl))))

    (define (tls-send ssl buf len)
      (let ((n (%tls-send buf ssl len)))
        (if (< n 0) (error "tls-send failed" (%last-error)) n)))

    (define (tls-recv ssl buf len)
      (let ((n (%tls-recv buf ssl len)))
        (if (< n 0) (error "tls-recv failed" (%last-error)) n)))

    (define (tls-close ssl)
      (%tls-close ssl))))
