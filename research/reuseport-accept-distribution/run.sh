#!/usr/bin/env bash
# Build and sweep the P7 accept-distribution harness over N in {2,4,8,cores}.
# See README.md for the method and the recorded results/decision.
set -euo pipefail

cd "$(dirname "$0")"
M="${1:-10000}"

CC="${CC:-cc}"
"$CC" -O2 -Wall -o reuseport_accept reuseport_accept.c -lpthread

# Processor count (portable across macOS and Linux).
if command -v nproc >/dev/null 2>&1; then
  CORES="$(nproc)"
else
  CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi

for N in 2 4 8 "$CORES"; do
  echo "======== N=$N ========"
  ./reuseport_accept "$N" "$M"
  echo
done
