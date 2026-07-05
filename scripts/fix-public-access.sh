#!/usr/bin/env bash
# =============================================================================
# KubeQuest — re-apply nip.io hostnames + Let's Encrypt (standalone, idempotent)
# =============================================================================
# Run this ANYTIME after touching an ingress (re-applying the app/infra
# manifests reverts the live nip.io/letsencrypt patch back to the chart's
# committed defaults — *.local + internal-ca). Safe to re-run as many times as
# you want; it only patches, never destroys anything else.
#
# Usage (on kube-1):
#   INGRESS_PUBLIC_IP=<ingress-EIP> bash scripts/fix-public-access.sh
# =============================================================================
set -euo pipefail
IP="${INGRESS_PUBLIC_IP:?export INGRESS_PUBLIC_IP=<ingress-EIP> first}"

for e in "crementation:crementation:crementation" "grafana:prometheus-grafana:monitoring" \
         "dashboard:kubernetes-dashboard:dashboard" "argocd:argocd-server:argocd" "dex:dex:auth"; do
  sub="${e%%:*}"; rest="${e#*:}"; name="${rest%%:*}"; ns="${rest##*:}"
  host="$sub.$IP.nip.io"
  kubectl -n "$ns" get ingress "$name" >/dev/null 2>&1 || { echo "  (skip $name — no ingress in $ns)"; continue; }

  current_host=$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
  current_issuer=$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null)
  if [ "$current_host" = "$host" ] && [ "$current_issuer" = "letsencrypt-prod" ]; then
    echo "  ✓ $host already correct"
    continue
  fi

  kubectl -n "$ns" annotate ingress "$name" cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite >/dev/null 2>&1
  kubectl -n "$ns" patch ingress "$name" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$host\"}]" >/dev/null 2>&1
  if [ -n "$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.spec.tls}' 2>/dev/null)" ]; then
    kubectl -n "$ns" patch ingress "$name" --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/tls/0/hosts/0\",\"value\":\"$host\"}]" >/dev/null 2>&1
    sec=$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)
    kubectl -n "$ns" delete certificate "$sec" secret "$sec" >/dev/null 2>&1  # force LE re-issue
  fi
  if [ "$sub" = "crementation" ]; then
    kubectl -n "$ns" set env deploy/"$name" "APP_URL_HOST=$host" >/dev/null 2>&1
  fi
  echo "  → $host -> letsencrypt-prod (re-patched)"
done

echo ""
echo "Certs re-issue over the next ~30-60s. Check with:"
echo "  kubectl get certificate -A"
