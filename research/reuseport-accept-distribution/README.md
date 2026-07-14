# P7 — `SO_REUSEPORT` accept-distribution harness

The first task of KEP-0002 Phase 6 (kaappi#1471). Before writing any
multi-core HTTP code, this harness settles the one empirical question the
architecture hinges on: **does `SO_REUSEPORT` actually load-balance inbound
connections across listeners on this kernel?**

Linux (≥ 3.9) hashes the connection 4-tuple across all sockets sharing a
`SO_REUSEPORT` port, so accepts spread evenly. Classic BSD `SO_REUSEPORT`
merely *permits* the shared bind and does not balance — FreeBSD added
`SO_REUSEPORT_LB` precisely to get balancing, and macOS has no equivalent.
Since macOS is Kaappi's primary dev platform, the skew has to be measured,
not assumed. KEP-0002 §9 pre-registered the decision rule:

> If Darwin's max/min per-listener ratio > 3 at N = cores, implement the
> §9 userspace fd-distributor fallback; otherwise document the skew and
> ship the plain `SO_REUSEPORT` path everywhere.

## Method

`reuseport_accept.c` reproduces the `http-listen-parallel` topology exactly:
N acceptor threads, each with its **own** `SO_REUSEPORT` listen socket on one
shared port, each accepting independently. A single client loop opens M
short-lived connections; each acceptor tags every accept with its listener
index. We report per-listener counts, a chi-squared statistic against the
uniform expectation, and the **max/min ratio** the decision rule is stated in.

Each acceptor writes one sync byte before closing so the client can wait for
the accept to actually land — that guarantees exactly M accepts and lets the
client RST-close (`SO_LINGER` 0) to avoid TIME_WAIT / ephemeral-port
exhaustion across back-to-back runs.

```sh
./run.sh              # build + sweep N in {2,4,8,cores}, M=10000
./run.sh 50000        # same, M=50000
cc -O2 -o reuseport_accept reuseport_accept.c -lpthread   # build only
./reuseport_accept 8 10000                                # one run, N=8
```

## Results (M = 10000 connections/run)

### macOS aarch64 — Darwin 25.5.0, Apple Silicon, 12 cores

| N  | per-listener spread          | chi-squared (df=N−1) | max/min |
|----|------------------------------|----------------------|---------|
| 2  | `[0, 10000]`                 | 10000 (df=1)         | **inf** |
| 4  | `[0, 0, 0, 10000]`           | 30000 (df=3)         | **inf** |
| 8  | `[0×7, 10000]`               | 70000 (df=7)         | **inf** |
| 12 | `[0×11, 10000]`              | 110000 (df=11)       | **inf** |

100% of connections go to the **last-bound** listener at every N; all others
get zero. The folklore is exactly right.

### Linux x86_64 — Ubuntu 24.04, kernel 6.8.0

| N  | per-listener % range | chi-squared (df=N−1) | max/min |
|----|----------------------|----------------------|---------|
| 2  | 49.24–50.76%         | 2.31  (df=1)         | 1.03    |
| 4  | 23.89–25.72%         | 7.91  (df=3)         | 1.08    |
| 8  | 11.81–13.35%         | 14.96 (df=7)         | 1.13    |
| 12 | 7.79–8.91%           | 15.55 (df=11)        | 1.14    |

Near-uniform. (chi-squared critical value at p=0.05, df=11, is 19.68; the
observed 15.55 is well under it — the small per-N wobble is single-sample
noise, not skew. The decision metric, max/min ≈ 1.0–1.14, is unambiguous.)

## Decision

Darwin's max/min ratio at N = cores is **inf ≫ 3**, so the pre-registered
criterion fires: **implement the KEP-0002 §9 Darwin userspace fd-distributor
fallback** (one acceptor thread handing accepted fds to workers over a shared
channel). Linux keeps the plain kernel-balanced `SO_REUSEPORT` path — the
`reuseport` socket option in `kaappi-net` plus one `http-listen-fiber` per
thread, zero fd passing.

This is recorded in kaappi#1471 and cross-linked into KEP-0002 §9.
