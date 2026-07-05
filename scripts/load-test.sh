#!/usr/bin/env bash
# =============================================================================
# KubeQuest — load test / autoscaling demo (zero external dependencies)
# =============================================================================
# The brief (project.pdf p.5): "in order to demonstrate some features, such as
# auto-scaling, execute some live scripts ... to send lots of requests to your
# applications". This drives the HPA (crementation/values.yaml: 2->5 replicas
# at 70% CPU) using nothing but bash + curl — no `hey`/`ab`/`wrk` to install,
# so it works on any machine that already has curl (i.e. everywhere).
#
# It hits /api/debug/burn-cpu (DebugController::burnCpu), which busy-loops one
# worker at 100% CPU for N seconds — far more reliable for triggering the HPA
# than hammering "/" (the counter page is too cheap to push real CPU load).
# Requires DEBUG_ENDPOINTS_ENABLED=true (off by default — see README).
#
# Usage:
#   ./scripts/load-test.sh <host> [duration_seconds] [concurrency]
#
# Example (nip.io hostname from your deploy):
#   ./scripts/load-test.sh crementation.35.181.119.189.nip.io 120 30
#
# Watch it scale live, in another terminal:
#   kubectl -n crementation get hpa crementation --watch
#   kubectl -n crementation get pods -l app.kubernetes.io/name=crementation --watch
# =============================================================================
set -euo pipefail

HOST="${1:?Usage: $0 <host> [duration_seconds] [concurrency]}"
DURATION="${2:-120}"
CONCURRENCY="${3:-30}"
BURN_SECONDS=30   # each request keeps a worker busy this long — must be >= the curl loop's own pace

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

say "Load test: $CONCURRENCY concurrent workers hitting /api/debug/burn-cpu for ${DURATION}s"
echo "Host: $HOST"
echo "(each hit busy-loops a PHP worker at 100% CPU for ${BURN_SECONDS}s server-side)"

END=$((SECONDS + DURATION))
PIDS=()

worker() {
  local id="$1"
  local n=0
  while [ "$SECONDS" -lt "$END" ]; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$((BURN_SECONDS + 10))" \
      -H "Host: $HOST" "https://${HOST}/api/debug/burn-cpu?seconds=${BURN_SECONDS}" 2>/dev/null || echo "000")
    n=$((n + 1))
    echo "  [worker $id] request #$n -> HTTP $code"
  done
}

for i in $(seq 1 "$CONCURRENCY"); do
  worker "$i" &
  PIDS+=("$!")
done

say "Running... (watch the HPA in another terminal, see the usage note above)"
wait "${PIDS[@]}"

say "Load test finished"
echo "Give the HPA ~1-2 min to scale back down (default stabilization window)."
echo "Check final state:  kubectl -n crementation get hpa,pods -l app.kubernetes.io/name=crementation"
