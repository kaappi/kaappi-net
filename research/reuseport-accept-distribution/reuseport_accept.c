/* reuseport_accept.c — KEP-0002 Phase 6 / open-problems P7 harness.
 *
 * Measures how the kernel distributes inbound TCP connections across N
 * listener sockets that all bind the same port with SO_REUSEPORT. This is
 * exactly the http-listen-parallel topology: N threads, each with its own
 * SO_REUSEPORT listen socket, each accepting independently. The question it
 * settles is KEP-0002 §9's: does SO_REUSEPORT actually load-balance on this
 * kernel, or does it (as BSD folklore claims for Darwin) pile every
 * connection onto one socket?
 *
 * Method: N acceptor threads (one per listener) count the accepts the kernel
 * hands them; a single client loop opens M short-lived connections. Each
 * acceptor writes one byte before closing so the client can wait for the
 * accept to actually happen — this guarantees exactly M accepts and lets the
 * client RST-close (SO_LINGER 0) to avoid TIME_WAIT / ephemeral-port
 * exhaustion across back-to-back runs. Reports per-listener counts, a
 * chi-squared statistic against the uniform expectation, and the max/min
 * ratio that KEP-0002 §9's pre-registered decision criterion is stated in
 * terms of.
 *
 * Usage: reuseport_accept <N> <M> [port]
 *   N    number of SO_REUSEPORT listeners (2, 4, 8, ...)
 *   M    number of connections the client opens
 *   port TCP port to bind (default 0 => pick an ephemeral port and print it)
 *
 * Build: cc -O2 -o reuseport_accept reuseport_accept.c -lpthread
 * (or run ./run.sh, which builds and sweeps N in {2,4,8,cores}).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <poll.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#ifndef SO_REUSEPORT
#error "SO_REUSEPORT not available on this platform"
#endif

#define MAX_LISTENERS 256

static int   g_n;                                 /* number of listeners */
static int   g_m;                                 /* target connection count */
static int   g_listen_fds[MAX_LISTENERS];         /* one per listener */
static _Atomic long g_counts[MAX_LISTENERS];      /* accepts observed per listener */
static _Atomic long g_total;                      /* accepts observed across all */
static _Atomic int  g_stop;                       /* set once M accepts are in */

/* Acceptor thread: poll its own listener, accept, count, send a sync byte,
 * close. Polling (rather than a bare blocking accept) lets the thread notice
 * g_stop and exit cleanly once the run is done. */
static void *acceptor(void *arg) {
    long idx = (long)arg;
    int lfd = g_listen_fds[idx];
    struct pollfd pfd = { .fd = lfd, .events = POLLIN };
    while (!atomic_load(&g_stop)) {
        int rc = poll(&pfd, 1, 100);
        if (rc <= 0) continue;              /* timeout or EINTR: re-check stop */
        if (!(pfd.revents & POLLIN)) continue;
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) continue;              /* transient (EAGAIN/EINTR): keep going */
        atomic_fetch_add(&g_counts[idx], 1);
        atomic_fetch_add(&g_total, 1);
        /* Tell the client the accept happened, then close. */
        char b = 'x';
        ssize_t w = write(cfd, &b, 1);
        (void)w;
        close(cfd);
    }
    return NULL;
}

/* Open one SO_REUSEPORT listener on the shared port. Returns fd or -1. */
static int make_listener(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    /* REUSEADDR + REUSEPORT: REUSEPORT is the one under test; REUSEADDR keeps
     * back-to-back runs from tripping over lingering TIME_WAIT on the port. */
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) < 0) {
        perror("setsockopt(SO_REUSEPORT)");
        close(fd);
        return -1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(fd);
        return -1;
    }
    if (listen(fd, 1024) < 0) {
        perror("listen");
        close(fd);
        return -1;
    }
    return fd;
}

/* Discover the port actually bound (when the caller passed 0). */
static int bound_port(int fd) {
    struct sockaddr_in a;
    socklen_t len = sizeof(a);
    if (getsockname(fd, (struct sockaddr *)&a, &len) < 0) return -1;
    return ntohs(a.sin_port);
}

/* Client: M short-lived connections, each waited to completion (read the
 * server's sync byte) so we never race the accept, then RST-closed. */
static void run_client(int port) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);

    for (int i = 0; i < g_m; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { perror("client socket"); continue; }
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            /* Ephemeral exhaustion or transient refusal: back off and retry. */
            close(fd);
            usleep(1000);
            i--;
            continue;
        }
        char b;
        ssize_t r = read(fd, &b, 1);        /* blocks until an acceptor writes */
        (void)r;
        struct linger lg = { .l_onoff = 1, .l_linger = 0 };  /* RST on close */
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
        close(fd);
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <N-listeners> <M-connections> [port]\n", argv[0]);
        return 2;
    }
    g_n = atoi(argv[1]);
    g_m = atoi(argv[2]);
    int port = (argc > 3) ? atoi(argv[3]) : 0;
    if (g_n < 1 || g_n > MAX_LISTENERS || g_m < 1) {
        fprintf(stderr, "bad N (1..%d) or M\n", MAX_LISTENERS);
        return 2;
    }

    for (int i = 0; i < g_n; i++) {
        g_listen_fds[i] = make_listener(port);
        if (g_listen_fds[i] < 0) return 1;
        if (i == 0 && port == 0) port = bound_port(g_listen_fds[0]);
    }

    pthread_t th[MAX_LISTENERS];
    for (long i = 0; i < g_n; i++)
        pthread_create(&th[i], NULL, acceptor, (void *)i);

    run_client(port);

    /* Client done: all M connections have been accepted (each waited on its
     * sync byte). Stop the acceptors and join. */
    atomic_store(&g_stop, 1);
    for (int i = 0; i < g_n; i++) pthread_join(th[i], NULL);
    for (int i = 0; i < g_n; i++) close(g_listen_fds[i]);

    /* Report. */
    long total = atomic_load(&g_total);
    double expected = (double)total / g_n;
    double chi2 = 0.0;
    long mx = 0, mn = total;
    for (int i = 0; i < g_n; i++) {
        long c = atomic_load(&g_counts[i]);
        if (c > mx) mx = c;
        if (c < mn) mn = c;
        double d = (double)c - expected;
        chi2 += (expected > 0) ? (d * d) / expected : 0.0;
    }

    struct utsname u;
    if (uname(&u) == 0)
        printf("platform %s %s\n", u.sysname, u.machine);
    printf("N=%d M=%d port=%d\n", g_n, g_m, port);
    for (int i = 0; i < g_n; i++) {
        long c = atomic_load(&g_counts[i]);
        printf("  listener[%d]: %ld (%.2f%%)\n",
               i, c, total ? 100.0 * c / total : 0.0);
    }
    printf("  total accepted:    %ld (target %d)\n", total, g_m);
    printf("  expected/listener: %.2f\n", expected);
    printf("  chi-squared:       %.2f (df=%d)\n", chi2, g_n - 1);
    if (mn > 0)
        printf("  max/min ratio:     %.2f  [decision metric]\n", (double)mx / mn);
    else
        printf("  max/min ratio:     inf (min=0)  [decision metric]\n");
    return 0;
}
