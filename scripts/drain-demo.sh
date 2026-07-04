#!/usr/bin/env bash
# PodDisruptionBudget + node-drain demo: cordon & drain the node currently
# running a crementation app pod, and show that (a) the PDB keeps at least one
# replica available and (b) the app stays reachable throughout.
#
# Pair this with scripts/zero-downtime-test.sh in another terminal pointed at
# the ingress to visually prove zero dropped requests during the drain.
#
# Usage:
#   ./scripts/drain-demo.sh
set -euo pipefail

NS=crementation
APP_LABEL=app.kubernetes.io/name=crementation

echo "== PodDisruptionBudget =="
kubectl -n "$NS" get pdb

echo
echo "== app pods and their nodes =="
kubectl -n "$NS" get pods -l "$APP_LABEL" -o wide

# Pick a node that hosts an app pod.
NODE=$(kubectl -n "$NS" get pods -l "$APP_LABEL" \
  -o jsonpath='{.items[0].spec.nodeName}')
echo
echo "== draining node: $NODE =="
echo "(the PDB will make this block until a replacement pod is Ready elsewhere)"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s

echo
echo "== app pods after drain (should have rescheduled off $NODE) =="
kubectl -n "$NS" get pods -l "$APP_LABEL" -o wide

echo
echo "== uncordon $NODE when done =="
echo "  kubectl uncordon $NODE"
