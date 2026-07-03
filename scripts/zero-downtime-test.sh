#!/usr/bin/env bash
# Zero-downtime deploy proof (the brief explicitly lists "guarantee
# zero-downtime deployment"). Hammers the crementation app with back-to-back
# requests while you trigger a rolling update in another terminal, and counts
# how many requests failed. With the chart's updateStrategy (maxUnavailable: 0,
# maxSurge: 1) + readinessProbe + minReadySeconds, that count should be 0.
#
# Usage:
#   ./scripts/zero-downtime-test.sh <ingress-ip-or-hostname> [duration-seconds]
#
# In a SEPARATE terminal, while this runs, trigger a rollout, e.g.:
#   kubectl -n crementation rollout restart deploy/crementation
# (or a real `helm upgrade ... --set image.tag=<new>`).
set -euo pipefail

TARGET="${1:?Usage: $0 <ingress-ip-or-hostname> [duration-seconds]}"
DURATION="${2:-60}"

ok=0
fail=0
end=$(( $(date +%s) + DURATION ))

echo "Probing https://${TARGET}/ (Host: crementation.local) for ${DURATION}s."
echo "Trigger 'kubectl -n crementation rollout restart deploy/crementation' now."
echo

while [ "$(date +%s)" -lt "$end" ]; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' \
    --max-time 3 -H "Host: crementation.local" "https://${TARGET}/" || echo 000)
  if [ "$code" = "200" ]; then
    ok=$((ok+1))
    printf '.'
  else
    fail=$((fail+1))
    printf '\n[%s] FAILED request (HTTP %s)\n' "$(date +%T)" "$code"
  fi
done

echo
echo "===================================="
echo "  successful (200): $ok"
echo "  failed:           $fail"
if [ "$fail" -eq 0 ]; then
  echo "  RESULT: zero downtime ✔"
else
  echo "  RESULT: $fail dropped requests — investigate readinessProbe / maxUnavailable"
fi
echo "===================================="
