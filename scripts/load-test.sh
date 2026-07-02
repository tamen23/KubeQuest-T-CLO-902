#!/usr/bin/env bash
# Reusable load-test script for the KubeQuest defense demo
# (docs/deployment/defense.md's autoscaling section).
#
# Usage:
#   ./scripts/load-test.sh <ingress-ip-or-hostname> [duration] [concurrency]
#
# Example:
#   ./scripts/load-test.sh 13.36.139.46 180s 50
#
# Requires `hey` (https://github.com/rakyll/hey) on PATH. Install with:
#   go install github.com/rakyll/hey@latest
# or download a prebuilt binary from the releases page — no Go toolchain
# needed either way.
set -euo pipefail

TARGET="${1:?Usage: $0 <ingress-ip-or-hostname> [duration] [concurrency]}"
DURATION="${2:-180s}"
CONCURRENCY="${3:-50}"

if ! command -v hey >/dev/null 2>&1; then
  echo "error: 'hey' is not installed or not on PATH." >&2
  echo "  install: https://github.com/rakyll/hey#installation" >&2
  exit 1
fi

echo "== Plain load (drives HPA CPU scaling on / requests) =="
echo "target=${TARGET} duration=${DURATION} concurrency=${CONCURRENCY}"
hey -z "${DURATION}" -c "${CONCURRENCY}" \
  -host crementation.local \
  "https://${TARGET}/"

echo
echo "== Watch scaling live in another terminal with: =="
echo "  kubectl -n crementation get hpa crementation --watch"
echo "  kubectl -n crementation get pods --watch"
