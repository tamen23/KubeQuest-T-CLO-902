#!/usr/bin/env bash
# Drives the debug failure-injection endpoints
# (sample-app-master/app/Http/Controllers/DebugController.php) for the
# defense demo's "broken deployment" / resource-limit sections
# (docs/deployment/defense.md).
#
# REQUIRES DEBUG_ENDPOINTS_ENABLED=true to be set on the crementation
# Deployment first — see crementation/values.yaml's env block. This script
# does not flip that flag itself (it's a deliberate two-step gate so nobody
# runs this against a normal deployment by accident). Edit the
# DEBUG_ENDPOINTS_ENABLED value in crementation/values.yaml to "true", then:
#
#   kustomize build --enable-helm applications/crementation/base | kubectl apply -f -
#
# (avoid `--set env[N].value=...` by array index — it silently targets the
# wrong entry if the env list is ever reordered; editing the source values
# file directly is the only reliable way with this chart's current template)
#
# Usage:
#   ./scripts/failure-demo.sh <ingress-ip-or-hostname> cpu [seconds]
#   ./scripts/failure-demo.sh <ingress-ip-or-hostname> memory [rounds]
#   ./scripts/failure-demo.sh <ingress-ip-or-hostname> crash
set -euo pipefail

TARGET="${1:?Usage: $0 <ingress-ip-or-hostname> {cpu|memory|crash} [param]}"
MODE="${2:?Usage: $0 <ingress-ip-or-hostname> {cpu|memory|crash} [param]}"

case "$MODE" in
  cpu)
    SECONDS_PARAM="${3:-30}"
    echo "== Burning CPU for ${SECONDS_PARAM}s on one worker =="
    echo "Watch: kubectl -n crementation top pods ; kubectl -n crementation get hpa crementation --watch"
    curl -sk -H "Host: crementation.local" \
      "https://${TARGET}/api/debug/burn-cpu?seconds=${SECONDS_PARAM}"
    echo
    ;;

  memory)
    ROUNDS="${3:-60}"
    echo "== Leaking ~10MB per request, ${ROUNDS} requests =="
    echo "Watch: kubectl -n crementation top pods ; kubectl -n crementation get pods --watch"
    echo "Expect an OOMKill once usage crosses resources.limits.memory (crementation/values.yaml, default 512Mi)"
    for i in $(seq 1 "$ROUNDS"); do
      curl -sk -H "Host: crementation.local" \
        "https://${TARGET}/api/debug/leak-memory?mb=10"
      echo " (round $i/$ROUNDS)"
      sleep 1
    done
    ;;

  crash)
    echo "== Triggering a single 500 (request-level crash, not container-level) =="
    curl -sk -o /dev/null -w '%{http_code}\n' -H "Host: crementation.local" \
      "https://${TARGET}/api/debug/crash"
    echo "For a container-level crash (to demo rollback), instead redeploy with a broken image tag —"
    echo "see docs/deployment/defense.md section 4."
    ;;

  *)
    echo "unknown mode: $MODE (expected cpu, memory, or crash)" >&2
    exit 1
    ;;
esac
