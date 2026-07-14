#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

static int last_errno = 0;
static SSL_CTX *tls_ctx = NULL;
static char tls_host[256] = {0};

/* =======================================================================
   TCP Client
   ======================================================================= */

/* (string, int, int) -> int */
int knet_tcp_connect(const char *host, int port, int timeout_ms) {
    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%d", port);

    int rc = getaddrinfo(host, port_str, &hints, &res);
    if (rc != 0) { last_errno = rc; return -1; }

    int fd = -1;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (timeout_ms > 0) {
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            rc = connect(fd, rp->ai_addr, rp->ai_addrlen);
            if (rc < 0 && errno == EINPROGRESS) {
                struct pollfd pfd = { .fd = fd, .events = POLLOUT };
                rc = poll(&pfd, 1, timeout_ms);
                if (rc <= 0) { close(fd); fd = -1; continue; }
                int err = 0; socklen_t len = sizeof(err);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                if (err) { close(fd); fd = -1; last_errno = err; continue; }
            } else if (rc < 0) { last_errno = errno; close(fd); fd = -1; continue; }
            fcntl(fd, F_SETFL, flags);
        } else {
            if (connect(fd, rp->ai_addr, rp->ai_addrlen) < 0) {
                last_errno = errno; close(fd); fd = -1; continue;
            }
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        break;
    }
    freeaddrinfo(res);
    if (fd < 0 && last_errno == 0) last_errno = ECONNREFUSED;
    return fd;
}

/* =======================================================================
   TCP Server
   ======================================================================= */

/* Shared listen path. When reuseport is set, also set SO_REUSEPORT so several
   sockets (typically one per OS thread) can bind the same port — the
   foundation of http-listen-parallel. On Linux (>=3.9) the kernel then hashes
   inbound connections across those sockets; on Darwin it does not balance
   (see research/reuseport-accept-distribution/), which is why the parallel
   server there falls back to a userspace fd distributor. */
static int do_tcp_listen(const char *host, int port, int backlog, int reuseport) {
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;

    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%d", port);

    int rc = getaddrinfo(host, port_str, &hints, &res);
    if (rc != 0) { last_errno = rc; return -1; }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { last_errno = errno; freeaddrinfo(res); return -1; }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (reuseport &&
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) < 0) {
        last_errno = errno; close(fd); freeaddrinfo(res); return -1;
    }

    if (bind(fd, res->ai_addr, res->ai_addrlen) < 0) {
        last_errno = errno; close(fd); freeaddrinfo(res); return -1;
    }
    freeaddrinfo(res);

    if (listen(fd, backlog) < 0) {
        last_errno = errno; close(fd); return -1;
    }
    return fd;
}

/* (string, int, int) -> int */
int knet_tcp_listen(const char *host, int port, int backlog) {
    return do_tcp_listen(host, port, backlog, 0);
}

/* (string, int, int) -> int — like knet_tcp_listen but with SO_REUSEPORT. */
int knet_tcp_listen_reuseport(const char *host, int port, int backlog) {
    return do_tcp_listen(host, port, backlog, 1);
}

/* () -> int — 1 if SO_REUSEPORT actually load-balances accepts on this
   platform, 0 otherwise. Linux (>=3.9) hashes the connection 4-tuple across
   all sockets sharing the port; Darwin/BSD permit the shared bind but pile
   every connection onto the last-bound socket (measured in
   research/reuseport-accept-distribution/). http-listen-parallel uses this to
   choose the kernel-balanced path vs the userspace fd distributor. */
int knet_reuseport_balances(void) {
#ifdef __linux__
    return 1;
#else
    return 0;
#endif
}

/* (int) -> int */
int knet_tcp_accept(int listen_fd) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0) { last_errno = errno; return -1; }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

/* =======================================================================
   TCP I/O
   ======================================================================= */

/* (pointer, pointer, long) -> int */
int knet_tcp_send(void *buf, void *fd_ptr, long len) {
    int fd = (int)(intptr_t)fd_ptr;
    ssize_t n = send(fd, buf, (size_t)len, 0);
    if (n < 0) { last_errno = errno; return -1; }
    return (int)n;
}

/* (pointer, pointer, long) -> int */
int knet_tcp_recv(void *buf, void *fd_ptr, long len) {
    int fd = (int)(intptr_t)fd_ptr;
    ssize_t n = recv(fd, buf, (size_t)len, 0);
    if (n < 0) { last_errno = errno; return -1; }
    return (int)n;
}

/* (int) -> int */
int knet_tcp_close(int fd) {
    int rc = close(fd);
    if (rc < 0) last_errno = errno;
    return rc;
}

/* () -> int */
int knet_last_error(void) {
    return last_errno;
}

/* =======================================================================
   Non-blocking helpers
   ======================================================================= */

/* (int) -> int — set O_NONBLOCK on fd, returns 0 or -1 */
int knet_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) { last_errno = errno; return -1; }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        last_errno = errno; return -1;
    }
    return 0;
}

/* (int, int) -> int — poll fd for readability
   Returns 1 if ready, 0 if timeout, -1 on error. Retries on EINTR: with
   timeout_ms == 0 a signal essentially never lands mid-syscall, but a
   nonzero (blocking) timeout gives it a real window, and every existing
   caller here polls with a timeout appropriate to being retried by the
   caller anyway. Checks POLLIN before POLLHUP/POLLERR: a peer that sends
   a final response and closes in the same instant (HTTP Connection:
   close) sets both, and there's still unread data sitting in the socket
   buffer — treating that as a hard error drops the response. Only a
   hangup/error with *no* pending data is a real "never becomes readable"
   condition. */
int knet_poll_read(int fd, int timeout_ms) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int rc;
    do {
        rc = poll(&pfd, 1, timeout_ms);
    } while (rc < 0 && errno == EINTR);
    if (rc < 0) { last_errno = errno; return -1; }
    if (rc == 0) return 0;
    if (pfd.revents & POLLIN) return 1;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
    return 1;
}

/* (int, int) -> int — poll fd for writability
   Returns 1 if ready, 0 if timeout, -1 on error. See knet_poll_read for
   why EINTR is retried and POLLOUT is checked before POLLHUP/POLLERR. */
int knet_poll_write(int fd, int timeout_ms) {
    struct pollfd pfd = { .fd = fd, .events = POLLOUT };
    int rc;
    do {
        rc = poll(&pfd, 1, timeout_ms);
    } while (rc < 0 && errno == EINTR);
    if (rc < 0) { last_errno = errno; return -1; }
    if (rc == 0) return 0;
    if (pfd.revents & POLLOUT) return 1;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
    return 1;
}

/* (int) -> int — non-blocking accept, returns fd, -2 for EAGAIN, -1 for error */
int knet_nb_accept(int listen_fd) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
        last_errno = errno;
        return -1;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

/* =======================================================================
   TLS (OpenSSL)

   Non-blocking convention shared by knet_tls_handshake/send/recv, mirroring
   knet_nb_accept's -1 (error) / -2 (EAGAIN) precedent but split into two
   directions since OpenSSL's record layer can ask for the *opposite*
   direction mid-operation (renegotiation):
     >=1  bytes transferred (send/recv) or handshake complete
      0   clean shutdown (recv only)
     -1   hard error (last_errno holds an SSL_get_error() code)
     -2   would block on read  — caller polls read-readiness and retries
     -3   would block on write — caller polls write-readiness and retries
   The underlying fd is set non-blocking as soon as it exists (right after
   knet_tcp_connect) so the caller (lib/kaappi/net.sld) can drive the
   handshake/send/recv loop via poll-read/poll-write + thread-sleep!,
   yielding the fiber scheduler instead of blocking the OS thread.
   ======================================================================= */

static void tls_init(void) {
    if (tls_ctx) return;
    tls_ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_default_verify_paths(tls_ctx);
    SSL_CTX_set_verify(tls_ctx, SSL_VERIFY_PEER, NULL);
}

/* (string) -> void */
void knet_tls_set_host(const char *host) {
    strncpy(tls_host, host, sizeof(tls_host) - 1);
    tls_host[sizeof(tls_host) - 1] = '\0';
}

static int knet_tls_classify(SSL *ssl, int rc) {
    int err = SSL_get_error(ssl, rc);
    if (err == SSL_ERROR_WANT_READ) return -2;
    if (err == SSL_ERROR_WANT_WRITE) return -3;
    last_errno = err;
    return -1;
}

/* (long, long) -> pointer — opens the TCP connection and creates (but does
   not complete) the SSL object; the handshake itself is driven step-wise
   by knet_tls_handshake so it never blocks the OS thread. */
void *knet_tls_connect_start(long port, long timeout_ms) {
    tls_init();
    int fd = knet_tcp_connect(tls_host, (int)port, (int)timeout_ms);
    if (fd < 0) return NULL;
    knet_set_nonblocking(fd);

    SSL *ssl = SSL_new(tls_ctx);
    SSL_set_fd(ssl, fd);
    SSL_set_tlsext_host_name(ssl, tls_host);
    SSL_set1_host(ssl, tls_host);
    return ssl;
}

/* (pointer) -> int — advances the handshake by one non-blocking step.
   1 = complete, -2/-3 = would block (poll then retry), -1 = failed. */
int knet_tls_handshake(void *ssl_ptr) {
    SSL *ssl = (SSL *)ssl_ptr;
    int rc = SSL_connect(ssl);
    if (rc == 1) return 1;
    return knet_tls_classify(ssl, rc);
}

/* (pointer) -> int — the underlying fd, so the caller can poll it. */
int knet_tls_get_fd(void *ssl_ptr) {
    return SSL_get_fd((SSL *)ssl_ptr);
}

/* (pointer, pointer, long) -> int */
int knet_tls_send(void *buf, void *ssl_ptr, long len) {
    SSL *ssl = (SSL *)ssl_ptr;
    int n = SSL_write(ssl, buf, (int)len);
    if (n <= 0) return knet_tls_classify(ssl, n);
    return n;
}

/* (pointer, pointer, long) -> int */
int knet_tls_recv(void *buf, void *ssl_ptr, long len) {
    SSL *ssl = (SSL *)ssl_ptr;
    int n = SSL_read(ssl, buf, (int)len);
    if (n <= 0) {
        int err = SSL_get_error(ssl, n);
        if (err == SSL_ERROR_ZERO_RETURN) return 0;
        if (err == SSL_ERROR_WANT_READ) return -2;
        if (err == SSL_ERROR_WANT_WRITE) return -3;
        last_errno = err;
        return -1;
    }
    return n;
}

/* (pointer) -> void */
void knet_tls_close(void *ssl_ptr) {
    SSL *ssl = (SSL *)ssl_ptr;
    int fd = SSL_get_fd(ssl);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    if (fd >= 0) close(fd);
}
