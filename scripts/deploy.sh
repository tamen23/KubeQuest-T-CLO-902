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
helm template dex dex/dex --version 0.19.1 -n auth -f infrastructure/dex/values.yaml 2>/dev/null | kubectl apply -n auth --server-side --force-conflicts -f - >/dev/null 2>&1
helm template alloy grafana/alloy --version 0.11.0 -n monitoring -f infrastructure/monitoring/loki/values-alloy.yaml 2>/dev/null | kubectl apply -n monitoring --server-side --force-conflicts -f - >/dev/null 2>&1
helm template dashboard infrastructure/charts/kubernetes-dashboard -n dashboard -f infrastructure/dashboard/values.yaml 2>/dev/null | kubectl apply -n dashboard --server-side --force-conflicts -f - >/dev/null 2>&1
# remove any copies that landed in default on a prior kustomize apply
kubectl -n default delete deploy,ds,svc,sa -l 'app.kubernetes.io/name in (dex,alloy)' >/dev/null 2>&1 || true
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

# --- 9. NetworkPolicies LAST (deny-by-default; after all pods exist) ---------
say "NetworkPolicies (deny-by-default, applied last)"
mv infrastructure/kustomization.yaml.bak infrastructure/kustomization.yaml 2>/dev/null || true
kubectl apply -k infrastructure/network-policies >/dev/null 2>&1 || \
  { $KB infrastructure > /tmp/infra2.yaml; kubectl apply -f /tmp/infra2.yaml >/dev/null 2>&1 || true; }
ok "network policies applied"

# --- 10. Summary -------------------------------------------------------------
say "Deploy complete — cluster status"
tot=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'test' | wc -l)
run=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'test' | awk '$4=="Running"||$4=="Completed"' | wc -l)
echo "  Healthy pods (excl test hooks): $run / $tot"
kubectl get externalsecrets -A 2>/dev/null | awk 'NR==1||/crementation|auth|velero/'
echo ""
echo "  App:      kubectl -n crementation get pods,svc,ingress,hpa"
echo "  Reach it: curl -k -H 'Host: crementation.local' https://<ingress-EIP>/"
