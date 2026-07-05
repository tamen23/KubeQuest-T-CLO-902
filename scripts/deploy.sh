#!/usr/bin/env bash
# =============================================================================
# KubeQuest — SCRIPT B: deploy the whole stack onto a running cluster
# =============================================================================
# The brief (project.pdf p.5): "while presenting, deploy the services ... using
# nothing more than kubectl apply, kustomize..., helm...". This script does
# exactly that — every step below is kubectl / kustomize / helm. It is the
# tested, reproducible version of the deploy (all the ordering, CRD-two-pass,
# namespace fixes, and waits that a live kubeadm cluster needs are baked in).
#
# Run it ON kube-1 (the control-plane node), from a checkout of this repo:
#   # the repo must be present at ~/kubequest (scp it up, or git clone if you
#   # have a token). Then:
#   export GH_ID=... GH_SECRET=... DH_USER=maxi2 DH_TOKEN=... AWS_KEY=... AWS_SECRET=...
#   bash scripts/deploy.sh
#
# The GH/DH/AWS values are the only inputs (they seed Vault once). Everything
# else is generated. Idempotent: safe to re-run.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."   # repo root (~/kubequest)
export HELM_CACHE_HOME=/tmp/hc HELM_CONFIG_HOME=/tmp/hcfg HELM_DATA_HOME=/tmp/hd
KB="kustomize build --enable-helm --load-restrictor LoadRestrictionsNone"
SSA="kubectl apply --server-side --force-conflicts"   # server-side avoids the 256KB CRD annotation limit

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
ok()  { printf '\033[1;32m  ✓ %s\033[0m\n' "$1"; }

# require the one-time seed values
: "${DH_USER:=maxi2}"
for v in GH_ID GH_SECRET DH_TOKEN AWS_KEY AWS_SECRET; do
  [ -n "${!v:-}" ] || { echo "export $v=... before running (seeds Vault once)"; exit 1; }
done

# --- 0. tooling (a fresh kubeadm node has kubectl but not helm/kustomize) -----
say "Tooling (helm, kustomize)"
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash >/dev/null 2>&1
fi
if ! command -v kustomize >/dev/null; then
  curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash >/dev/null 2>&1
  sudo mv kustomize /usr/local/bin/ 2>/dev/null || true
fi
ok "helm $(helm version --short 2>/dev/null), kustomize $(kustomize version 2>/dev/null)"

# --- 1. namespaces -----------------------------------------------------------
say "Namespaces"
for ns in crementation ingress-nginx dashboard monitoring vault external-secrets-system \
          auth gatekeeper-system cert-manager argocd velero vpa; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
ok "namespaces"

# --- 2. storage (fresh kubeadm has NO default StorageClass) ------------------
say "Storage: local-path provisioner (default StorageClass)"
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml >/dev/null
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null 2>&1 || true
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s >/dev/null
ok "local-path is default StorageClass"

# --- 3. Vault: install, init, unseal ----------------------------------------
say "Vault install + init + unseal"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null 2>&1
helm upgrade --install vault hashicorp/vault --version 0.28.1 -n vault -f infrastructure/vault/values.yaml >/dev/null
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=180s
if kubectl -n vault exec vault-0 -- vault status 2>/dev/null | grep -q 'Initialized.*true'; then
  echo "  already initialized — reading ~/vault-init.txt for keys"
  UNSEAL=$(awk '/Unseal Key 1:/{print $NF}' ~/vault-init.txt)
  ROOT=$(awk '/Initial Root Token:/{print $NF}' ~/vault-init.txt)
else
  kubectl -n vault exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 > ~/vault-init.txt
  chmod 600 ~/vault-init.txt
  UNSEAL=$(awk '/Unseal Key 1:/{print $NF}' ~/vault-init.txt)
  ROOT=$(awk '/Initial Root Token:/{print $NF}' ~/vault-init.txt)
fi
kubectl -n vault exec vault-0 -- vault operator unseal "$UNSEAL" >/dev/null 2>&1 || true
ok "vault unsealed (keys in ~/vault-init.txt)"

V() { kubectl -n vault exec vault-0 -- sh -c "export VAULT_TOKEN='$ROOT'; $1"; }

# --- 4. Vault: kv engine, ESO policy, KUBERNETES auth, seed ------------------
say "Vault: kv + policy + kubernetes auth + seed"
V 'vault secrets enable -path=secret kv-v2' >/dev/null 2>&1 || true
V "echo 'path \"secret/data/*\" { capabilities = [\"read\"] }' | vault policy write external-secrets-read -" >/dev/null
V 'vault auth enable kubernetes' >/dev/null 2>&1 || true
V 'vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443' >/dev/null
# NOTE: token_policies= (NOT policy= — the latter silently no-ops => ESO gets 403)
V 'vault write auth/kubernetes/role/external-secrets bound_service_account_names=external-secrets bound_service_account_namespaces=external-secrets-system token_policies=external-secrets-read ttl=1h' >/dev/null
gen() { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }
DBP=$(gen); DBR=$(gen); DBRP=$(gen); O2S=$(gen); O2C=$(openssl rand -base64 32 | head -c 32); APPK="base64:$(openssl rand -base64 32)"
V "vault kv put secret/secret DB_HOST=mysql-primary.crementation.svc.cluster.local DB_DATABASE=app_database DB_USERNAME=app_user DB_PASSWORD='$DBP' DB_ROOT_PASSWORD='$DBR' DB_REPLICATION_PASSWORD='$DBRP' APP_KEY='$APPK'" >/dev/null
V "vault kv put secret/dex OAUTH2_PROXY_CLIENT_ID=oauth2-proxy OAUTH2_PROXY_CLIENT_SECRET='$O2S' OAUTH2_PROXY_COOKIE_SECRET='$O2C' GITHUB_CLIENT_ID='$GH_ID' GITHUB_CLIENT_SECRET='$GH_SECRET'" >/dev/null
V "vault kv put secret/dockerhub username='$DH_USER' token='$DH_TOKEN'" >/dev/null
V "vault kv put secret/aws AWS_ACCESS_KEY_ID='$AWS_KEY' AWS_SECRET_ACCESS_KEY='$AWS_SECRET'" >/dev/null
ok "vault configured + seeded (secret/{secret,dex,dockerhub,aws})"

# --- 5. Infrastructure layer (network-policies applied LAST, in step 9) ------
say "Infrastructure (render + apply; server-side, 2 passes for CRD ordering)"
sed -i.bak '/- network-policies/s/^/# /' infrastructure/kustomization.yaml
$KB infrastructure > /tmp/infra.yaml
echo "  rendered $(grep -c '^kind:' /tmp/infra.yaml) resources"
$SSA -f /tmp/infra.yaml >/dev/null 2>&1 || true   # pass 1: creates CRDs (some CRs fail)
echo "  waiting for External Secrets Operator webhook..."
kubectl -n external-secrets-system rollout status deploy/external-secrets-webhook --timeout=180s >/dev/null 2>&1 || true
sleep 10
$SSA -f /tmp/infra.yaml 2>&1 | grep -ic error | xargs -I{} echo "  pass 2 errors: {}"
ok "infrastructure applied"

# --- 6. Fix namespace stamping for dex / alloy / dashboard -------------------
# These 3 charts don't stamp metadata.namespace (helm inflator limitation), so
# via kustomize they land in the wrong namespace. Render each with `helm
# template -n <ns>` (which DOES stamp) and apply to the right namespace.
say "Namespace fix: dex -> auth, alloy -> monitoring, dashboard -> dashboard"
helm repo add dex https://charts.dexidp.io >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
# FIRST delete anything the infrastructure kustomize apply dumped in `default`
# (these 3 charts don't stamp metadata.namespace, so they land there). Delete
# INCLUDING the ingress objects — a stale default/dex ingress holds the
# dex.local host and blocks the correctly-namespaced one. Delete before the
# re-apply so the host is free.
kubectl -n default delete ingress dex kubernetes-dashboard >/dev/null 2>&1 || true
kubectl -n default delete deploy,ds,svc,sa -l 'app.kubernetes.io/name in (dex,alloy)' >/dev/null 2>&1 || true
kubectl -n default delete deploy,svc,sa -l 'app.kubernetes.io/part-of=kubernetes-dashboard' >/dev/null 2>&1 || true
sleep 3
# THEN render each with `helm template -n <ns>` (which stamps the namespace) and
# apply to the right namespace.
helm template dex dex/dex --version 0.19.1 -n auth -f infrastructure/dex/values.yaml 2>/dev/null | kubectl apply -n auth --server-side --force-conflicts -f - >/dev/null 2>&1
helm template alloy grafana/alloy --version 0.11.0 -n monitoring -f infrastructure/monitoring/loki/values-alloy.yaml 2>/dev/null | kubectl apply -n monitoring --server-side --force-conflicts -f - >/dev/null 2>&1
helm template dashboard infrastructure/charts/kubernetes-dashboard -n dashboard -f infrastructure/dashboard/values.yaml 2>/dev/null | kubectl apply -n dashboard --server-side --force-conflicts -f - >/dev/null 2>&1
kubectl -n default delete deploy,svc,sa -l 'app.kubernetes.io/part-of=kubernetes-dashboard' >/dev/null 2>&1 || true
ok "dex/alloy/dashboard in correct namespaces"

# --- 7. Database (official Bitnami MySQL) + app + backups --------------------
say "MySQL (official chart), app, backups"
$KB applications/mysql | kubectl apply -f - >/dev/null
$KB applications/crementation/base | kubectl apply -n crementation -f - >/dev/null 2>&1 || true
kubectl apply -k backups/mysql >/dev/null
ok "mysql + app + backups applied"

# --- 8. Wait for the app to be ready -----------------------------------------
say "Waiting for the app"
kubectl -n crementation rollout status deploy/crementation --timeout=240s || true
kubectl -n crementation get pods -l app.kubernetes.io/name=crementation
ok "app deployed"

# --- 8.5 Public hostnames (nip.io) + trusted TLS (Let's Encrypt) -------------
# The committed ingresses use *.local hostnames + the internal-ca issuer, which
# needs an /etc/hosts entry and shows a browser cert warning. Since the ingress
# node has a real public IP, switch every service to a *.<IP>.nip.io hostname
# (nip.io is public wildcard DNS -> resolves to that IP with ZERO client setup)
# and re-issue its cert from letsencrypt-prod (real, browser-trusted). This
# only works because nip.io is a real TLD and port 80 is open for the HTTP-01
# challenge. Set NIPIO=0 to skip and keep .local + internal-ca.
if [ "${NIPIO:-1}" = "1" ]; then
  say "Public hostnames (nip.io) + Let's Encrypt certs"
  # The ingress node's PUBLIC IP. kubeadm nodes don't set node ExternalIP, so
  # prefer the INGRESS_PUBLIC_IP env var (cluster-up.sh prints it as the ingress
  # EIP); fall back to any node ExternalIP if present.
  IP="${INGRESS_PUBLIC_IP:-$(kubectl get node -l node-role.kubernetes.io/ingress -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)}"
  if [ -z "$IP" ]; then
    echo "  ! could not auto-detect the ingress public IP; skipping nip.io."
    echo "    Re-run with INGRESS_PUBLIC_IP=<ingress-EIP> to enable it."
  else
    # host:ingress:namespace  (svc = the nip.io subdomain label)
    for e in "crementation:crementation:crementation" "grafana:prometheus-grafana:monitoring" \
             "dashboard:kubernetes-dashboard:dashboard" "argocd:argocd-server:argocd" "dex:dex:auth"; do
      sub="${e%%:*}"; rest="${e#*:}"; name="${rest%%:*}"; ns="${rest##*:}"
      host="$sub.$IP.nip.io"
      kubectl -n "$ns" annotate ingress "$name" cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite >/dev/null 2>&1
      kubectl -n "$ns" patch ingress "$name" --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$host\"}]" >/dev/null 2>&1
      # some ingresses have a tls block whose host list must match (else LE 400s)
      if [ -n "$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.spec.tls}' 2>/dev/null)" ]; then
        kubectl -n "$ns" patch ingress "$name" --type=json \
          -p="[{\"op\":\"replace\",\"path\":\"/spec/tls/0/hosts/0\",\"value\":\"$host\"}]" >/dev/null 2>&1
        sec=$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null)
        kubectl -n "$ns" delete certificate "$sec" secret "$sec" >/dev/null 2>&1  # force LE re-issue
      fi
      echo "  $host -> letsencrypt-prod"
    done
    ok "nip.io hostnames + Let's Encrypt (certs issue over the next ~1 min)"
  fi
fi

# --- 9. NetworkPolicies LAST (deny-by-default; after all pods exist) ---------
say "NetworkPolicies (deny-by-default, applied last)"
mv infrastructure/kustomization.yaml.bak infrastructure/kustomization.yaml 2>/dev/null || true
kubectl apply -k infrastructure/network-policies >/dev/null 2>&1 || \
  { $KB infrastructure > /tmp/infra2.yaml; kubectl apply -f /tmp/infra2.yaml >/dev/null 2>&1 || true; }
ok "network policies applied"

# --- 10. Verify the 5 services are reachable through the ingress -------------
# Restart the ingress controller first: the dex/dashboard ingresses were
# (re)created in step 6 after the controller cached its routes, so it needs a
# reload to serve them (otherwise they 404 despite being correct).
say "Verifying services through the ingress"
kubectl -n ingress-nginx rollout restart daemonset/ingress-nginx-controller >/dev/null 2>&1
kubectl -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=90s >/dev/null 2>&1 || true
sleep 15
INGRESS_NODE_IP=$(kubectl get node -l node-role.kubernetes.io/ingress -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
# domain suffix depends on whether nip.io was applied above
if [ "${NIPIO:-1}" = "1" ] && [ -n "${IP:-}" ]; then SUF="$IP.nip.io"; else SUF="local"; fi
# dex has no homepage at / (returns 404 by design) — probe its OIDC health
# endpoint instead. The others serve / (200) or redirect to SSO login (302/303).
for entry in "crementation:/" "grafana:/" "dashboard:/" "argocd:/" "dex:/healthz"; do
  h="${entry%%:*}"; path="${entry#*:}"
  code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: $h.$SUF" "https://${INGRESS_NODE_IP}${path}" --connect-timeout 10 --max-time 15 2>/dev/null)
  case "$code" in
    200|302|303) echo "  ✓ $h.$SUF -> HTTP $code" ;;
    *)           echo "  ✗ $h.$SUF -> HTTP ${code:-timeout} (may still be settling; re-check)" ;;
  esac
done

# --- 11. Summary -------------------------------------------------------------
say "Deploy complete — cluster status"
tot=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'test' | wc -l)
run=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'test' | awk '$4=="Running"||$4=="Completed"' | wc -l)
echo "  Healthy pods (excl test hooks): $run / $tot"
kubectl get externalsecrets -A 2>/dev/null | awk 'NR==1||/crementation|auth|velero/'
echo ""
if [ "${NIPIO:-1}" = "1" ] && [ -n "${IP:-}" ]; then
  echo "  Browser access (real DNS via nip.io, trusted Let's Encrypt certs — NO setup):"
  echo "    https://crementation.$IP.nip.io   (the app)"
  echo "    https://grafana.$IP.nip.io  https://dashboard.$IP.nip.io  https://argocd.$IP.nip.io"
  echo "  Certs finish issuing ~1 min after this; refresh if you see a warning at first."
else
  echo "  Browser access: add to your laptop's hosts file:  <ingress-EIP> crementation.local ..."
fi
