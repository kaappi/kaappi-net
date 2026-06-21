#!/bin/bash
# Test async HTTP server handles concurrent requests
set -e

KAAPPI="${KAAPPI:-zig-out/bin/kaappi}"
PORT=19888
PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected: $expected"
        echo "    got:      $actual"
    fi
}

DIR="$(cd "$(dirname "$0")" && pwd)"

# Write server app
cat > /tmp/async_server.scm << 'SCHEOF'
(import (scheme base) (scheme write) (kaappi http))

(define (handler request)
  (make-response 200
    (string-append "path=" (request-path request))
    '(("Content-Type" . "text/plain"))))

(http-listen-async handler 19888)
SCHEOF

export DYLD_LIBRARY_PATH="$DIR/..:${DYLD_LIBRARY_PATH}"
$KAAPPI --lib-path "$DIR/../lib" \
        --lib-path "$DIR/../../kaappi-http/lib" \
        /tmp/async_server.scm &
SERVER_PID=$!
sleep 0.5

cleanup() { kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; }
trap cleanup EXIT

echo "=== Sequential requests ==="
check "req 1" "path=/" "$(curl -s http://127.0.0.1:$PORT/)"
check "req 2" "path=/hello" "$(curl -s http://127.0.0.1:$PORT/hello)"
check "req 3" "path=/world" "$(curl -s http://127.0.0.1:$PORT/world)"

echo "=== Concurrent requests ==="
# Fire 5 requests in parallel
for i in 1 2 3 4 5; do
    curl -s http://127.0.0.1:$PORT/concurrent/$i > /tmp/async_result_$i &
done
wait

for i in 1 2 3 4 5; do
    check "concurrent $i" "path=/concurrent/$i" "$(cat /tmp/async_result_$i)"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
