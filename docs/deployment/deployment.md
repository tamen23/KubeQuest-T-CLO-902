# Deployment

Assumes a fresh cluster with `kube-1` as control plane, `kube-2` joined as a
worker, and `ingress`/`monitoring` labelled per `docs/ARCHITECTURE.md`:

```sh
kubectl label node <ingress-node-name> node-role.kubernetes.io/ingress=ingress
kubectl label node <monitoring-node-name> node-role.kubernetes.io/monitoring=monitoring
```

Tools required on the machine you run these commands from: `kubectl`, `helm`,
`kustomize` >= v5 (for `--enable-helm`).

## 1. Namespaces

```sh
for ns in crementation ingress-nginx dashboard monitoring vault external-secrets-system auth gatekeeper-system; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

Docker Hub pull secret for `maxi2/crementation-app` (private repo — this is a
real credential, create it imperatively, never commit it):

```sh
kubectl create secret docker-registry dockerhub-secret -n crementation \
  --docker-username=<user> --docker-password=<token> --docker-server=https://index.docker.io/v1/
```

## 2. Vault (must come before anything that reads secrets)

```sh
kustomize build --enable-helm infrastructure | \
  kubectl apply -f - --selector='!kustomize.toolkit.fluxcd.io' \
  --prune -l app.kubernetes.io/name=vault  # or: helm install vault hashicorp/vault -n vault -f infrastructure/vault/values.yaml

kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=1 -key-threshold=1 \
  > vault-init.txt   # DO NOT COMMIT vault-init.txt — it holds the unseal key + root token

kubectl -n vault exec -it vault-0 -- vault operator unseal <unseal-key-from-vault-init.txt>
```

Then, using the root token from `vault-init.txt` (one-time, to bootstrap a
least-privilege token for External Secrets Operator — do not use the root
token anywhere else):

```sh
kubectl -n vault exec -it vault-0 -- vault login <root-token>
kubectl -n vault exec -it vault-0 -- vault secrets enable -path=secret kv-v2
kubectl -n vault exec -it vault-0 -- vault policy write external-secrets-read - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
EOF
kubectl -n vault exec -it vault-0 -- vault token create -policy=external-secrets-read -format=json \
  | jq -r '.auth.client_token' > vault-token.txt

kubectl create secret generic vault-token -n external-secrets-system \
  --from-file=token=vault-token.txt
rm vault-init.txt vault-token.txt   # keep these out of the repo and out of shell history
```

Seed the app/Dex secrets (adjust values for your environment):

```sh
kubectl -n vault exec -it vault-0 -- vault kv put secret/secret \
  DB_HOST=mysql-primary.crementation.svc.cluster.local \
  DB_DATABASE=app_database \
  DB_USERNAME=app_user \
  DB_PASSWORD=<generate-a-real-password> \
  DB_ROOT_PASSWORD=<generate-a-real-password> \
  APP_KEY=<php artisan key:generate --show output>

kubectl -n vault exec -it vault-0 -- vault kv put secret/dex \
  OAUTH2_PROXY_CLIENT_SECRET=<generate-a-real-secret> \
  OAUTH2_PROXY_COOKIE_SECRET=<openssl rand -base64 32 | head -c 32> \
  GITHUB_CLIENT_ID=<from GitHub OAuth app settings> \
  GITHUB_CLIENT_SECRET=<from GitHub OAuth app settings, rotate the leaked one first>
```

## 3. Rest of the infrastructure layer

```sh
kustomize build --enable-helm infrastructure | kubectl apply -f -
```

This installs ingress-nginx, kubernetes-dashboard, kube-prometheus-stack, Loki
+ Alloy, External Secrets Operator, Dex, oauth2-proxy, and Gatekeeper (policy
+ controller). Re-run if some resources fail on the first pass — CRDs from one
chart (Gatekeeper, Prometheus Operator) need to exist before dependent
resources in the same apply can be created, and oauth2-proxy's ingress
annotations on dashboard/grafana will 503 until oauth2-proxy itself is up.

Confirm auth is actually enforced before moving on — this is the fix for a
gap the earlier audit caught (Dex alone, with nothing consuming it):

```sh
curl -sI -H "Host: dashboard.local" http://<ingress-node-public-ip>/ | head -1
# expect: HTTP/1.1 302 Found  (redirected to oauth2-proxy's /oauth2/start, not 200)
```

## 4. Database

```sh
kustomize build --enable-helm applications/mysql | kubectl apply -f -
```

Wait for `mysql-primary-0` and both `mysql-secondary-*` pods to be `Running`
before continuing — the app's readiness probe does not wait for the DB.

## 5. Application

```sh
kustomize build --enable-helm applications/crementation/base | kubectl apply -f -
```

Verify:

```sh
kubectl -n crementation get pods,svc,ingress,hpa
kubectl -n crementation logs deploy/crementation --tail=50
curl -H "Host: crementation.local" http://<ingress-node-public-ip>/
```

## 6. Backups

```sh
kubectl apply -k backups/mysql
kubectl -n crementation get cronjob mysql-backup
```

Trigger one manually to confirm it works before relying on the schedule:

```sh
kubectl -n crementation create job --from=cronjob/mysql-backup mysql-backup-manual-test
```

## Redeploying after a change

Edit the relevant `values.yaml` (chart-level config) or `crementation/values.yaml`
/ `crementation/templates/*` (app-level config), then re-run the matching
`kustomize build --enable-helm <path> | kubectl apply -f -` command above. Do
not hand-edit live cluster objects — if you do, port the change back into the
source file immediately (see the git history of this repo for what happens
when that discipline slips: `applications/crementation/base/deployment.yaml`
used to be a raw `kubectl get -o yaml` dump that silently diverged from the
Helm chart).
