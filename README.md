# T-CLO-902-PAR_4 — KubeQuest

Kubernetes GitOps deployment for the KubeQuest project: a full cluster
platform (ingress, dashboard, monitoring, logging, secrets, auth, policy)
plus a Laravel + MySQL application converted from docker-compose to
Helm/Kustomize.

## Documentation

The detailed documentation is split by topic under [`docs/`](docs/index.md):
architecture, repository layout, deployment runbooks, security, observability,
resilience, backups, defense demos, and CI/CD.

## Repository layout

- `crementation/` — Helm chart for the app (source of truth for its manifests)
- `applications/crementation/` — Kustomize base/overlay that renders the chart above via `kustomize build --enable-helm`
- `applications/mysql/` — Kustomize wrapper around the official Bitnami MySQL chart
- `infrastructure/` — cluster-wide platform components (metrics-server, ingress, dashboard, monitoring, logging, secrets, auth, policy), one `values.yaml` per component plus a top-level `kustomization.yaml`
- `infrastructure/network-policies/` — deny-by-default NetworkPolicy per namespace
- `infrastructure/argocd/` — ArgoCD Helm values + the Application manifests it uses to watch this repo
- `infrastructure/charts/kubernetes-dashboard/` — the dashboard chart is **vendored** here (its upstream Helm repo no longer serves a pullable index); every other chart is pulled by version at build time and the pull cache is gitignored
- `backups/mysql/` — CronJob + PVC for nightly `mysqldump` backups
- `components/gatekeeper/` — the OPA policy (ConstraintTemplate + Constraint) that rejects `:latest` image tags on `crementation`-namespace workloads
- `.github/workflows/ci.yml` + `.kube-linter.yaml` — image build + CVE scan, manifest lint, NetworkPolicy coverage check
- `scripts/` — load-test and failure-injection scripts for the defense demo
- `sample-app-master/` — original Laravel + MySQL application source, previously deployed via `docker-compose.yaml`; this is what the Helm chart in `crementation/` packages for Kubernetes

## Architecture

Four AWS EC2 (Amazon Linux) VMs, per the KubeQuest lab environment:

| Node         | Role                                              |
|--------------|----------------------------------------------------|
| `kube-1`     | Kubernetes control plane + worker                  |
| `kube-2`     | Kubernetes worker                                   |
| `ingress`    | Runs the ingress-nginx controller (DaemonSet, hostNetwork on 80/443) |
| `monitoring` | Runs Prometheus, Grafana, Loki, Alloy, Vault        |

Nodes are labelled to pin workloads:
- `node-role.kubernetes.io/ingress: ingress` on the `ingress` node
- `node-role.kubernetes.io/monitoring: monitoring` on the `monitoring` node

Application and platform pods (crementation app, MySQL, Dex, Gatekeeper,
External Secrets) are scheduled across `kube-1`/`kube-2` by the default
scheduler, using pod anti-affinity to spread replicas across the two.

### Namespaces

| Namespace                | Contents                                              |
|---------------------------|--------------------------------------------------------|
| `crementation`             | The app (Deployment, Service, Ingress, HPA), MySQL (primary + 2 secondaries), MySQL backup CronJob |
| `ingress-nginx`             | ingress-nginx controller                               |
| `dashboard`                 | kubernetes-dashboard                                    |
| `monitoring`                | kube-prometheus-stack (Prometheus, Grafana, Alertmanager, kube-rbac-proxy sidecars), Loki, Alloy |
| `vault`                     | HashiCorp Vault (single-node, Raft storage)             |
| `external-secrets-system`   | External Secrets Operator                               |
| `auth`                      | Dex (OIDC provider, GitHub org connector), oauth2-proxy (enforces login on dashboard/Grafana/ArgoCD ingresses) |
| `gatekeeper-system`         | OPA Gatekeeper (policy: reject `:latest` image tags on `crementation`) |
| `cert-manager`              | cert-manager (internal-ca + letsencrypt-prod ClusterIssuers) |
| `argocd`                    | ArgoCD (optional GitOps auto-sync, see below)            |
| `kube-system`               | metrics-server (provides `metrics.k8s.io` for the HPA / `kubectl top`) |

### Data flow

```
Internet
  |
  v
ingress node (nginx-ingress, hostNetwork:80/443)
  |
  +--> crementation.<ip>.nip.io  -> crementation app Service -> crementation Deployment (2+ pods, kube-1/kube-2)
  |                                                                    |
  |                                                                    v
  |                                                     mysql-primary (writes) / mysql-read (reads)
  |
  +--> dashboard.<ip>.nip.io -> [auth-url/auth-signin check] -> oauth2-proxy -> kubernetes-dashboard
  |
  +--> grafana.<ip>.nip.io   -> [auth-url/auth-signin check] -> oauth2-proxy -> Grafana (monitoring node)
  |
  +--> argocd.<ip>.nip.io    -> [auth-url/auth-signin check] -> oauth2-proxy -> ArgoCD server

`<ip>` is the ingress node's Elastic IP. nip.io is free public wildcard DNS
that resolves `<anything>.<ip>.nip.io` to `<ip>` — so every hostname above
works from any machine with zero setup (no /etc/hosts entry). The committed
chart defaults are `.local` names; `scripts/deploy.sh` (step 8.5) rewrites them
to nip.io at deploy time, and a self-healing CronJob (`nip-io-reconciler`, in
`kube-system`, every 3 minutes) keeps them that way even if a later manifest
re-apply reverts one — see docs/project-overview.md.

All ingress hostnames terminate TLS at ingress-nginx via cert-manager, issued
by `letsencrypt-prod` (real, browser-trusted — possible specifically because
nip.io is a real public domain cert-manager can complete an HTTP-01 challenge
against; `.local` names can't get a real cert, only the self-signed
`internal-ca` fallback — see infrastructure/cert-manager/cluster-issuers.yaml).

oauth2-proxy delegates login to Dex; a request that fails the ingress-nginx
auth-url check is redirected to oauth2-proxy's /oauth2/start, which redirects
to Dex (at its own external ingress, `dex.<ip>.nip.io` — the OIDC issuer URL
must be browser-reachable, so Dex is exposed like the other tools), which
redirects to GitHub. ingress-nginx re-checks auth-url on every request.
oauth2-proxy itself talks to Dex over the in-cluster service for token/JWKS
(see infrastructure/oauth2-proxy/values.yaml's skip-oidc-discovery config).

Direct PromQL/Alertmanager API access (bypassing Grafana) goes through a
second, narrower gate: kube-rbac-proxy sidecars in front of Prometheus and
Alertmanager, authorizing via Kubernetes RBAC (SubjectAccessReview) instead
of Dex.

Every namespace above also has a deny-by-default NetworkPolicy
(infrastructure/network-policies/) restricting pod-to-pod traffic to only the
paths drawn in this diagram.

Secrets flow: Vault (monitoring node) --> External Secrets Operator --> Kubernetes Secrets
  (laravel-db, mysql-secret, dex-secrets) --> consumed via envFrom by the relevant pods
  (dex-secrets is also read directly by oauth2-proxy for its client + cookie secrets)

GitOps flow (optional): git push to main --> ArgoCD detects the change -->
  auto-syncs infrastructure/, applications/mysql/, applications/crementation/,
  backups/mysql/ --> cluster converges without a manual kubectl/kustomize/helm apply.
```

### Why these choices

- **kustomize `helmCharts` inflator** instead of committing rendered/`helm get manifest` YAML: every component has exactly one editable source (its `values.yaml`), so `kubectl diff`/`kustomize build` never drifts from what's actually deployed.
- **DaemonSet + hostNetwork for ingress-nginx**: this lab cluster has no cloud LoadBalancer in front of it, so the ingress controller binds host ports directly on the dedicated `ingress` node.
- **Vault single-node with Raft storage, no auto-unseal**: full HA + auto-unseal needs a cloud KMS this lab account doesn't have. Traded off for a documented manual unseal step (see Deployment below) instead of a dev-mode Pod with a hardcoded root token.
- **MySQL via the official Bitnami chart in `replication` mode** (1 primary + 2 secondaries) satisfies both the brief's "use the official chart for the database" requirement and its redundancy requirement.
- **cert-manager with both an internal-ca and a letsencrypt-prod ClusterIssuer**: the committed chart defaults (`.local` hostnames) use the self-signed `internal-ca` — Let's Encrypt's HTTP-01 challenge needs a real public DNS record, which `.local` can never satisfy. At deploy time, `scripts/deploy.sh` switches every ingress to a `<name>.<ingress-ip>.nip.io` hostname (real public DNS, zero client setup) and its issuer to `letsencrypt-prod`, so the deployed cluster actually serves real, browser-trusted certificates — not just internal-ca. A CronJob (`nip-io-reconciler`) keeps this in place even if a later manifest re-apply reverts an ingress to its `.local`/internal-ca default.
- **kube-rbac-proxy in front of Prometheus/Alertmanager, on top of (not instead of) oauth2-proxy/Dex on Grafana**: two independent gates for two independent audiences — Grafana users go through Dex/GitHub org membership, while anyone querying PromQL directly needs a Kubernetes RBAC grant.
- **ArgoCD as an optional layer over the manual `kubectl`/`kustomize`/`helm` flow, not a replacement for it**: every Application it manages points at the exact same paths documented manually below, so the underlying manifests never depend on ArgoCD being present.

## Deployment

Assumes a fresh cluster with `kube-1` as control plane, `kube-2` joined as a
worker, and `ingress`/`monitoring` labelled per the Architecture section above:

```sh
kubectl label node <ingress-node-name> node-role.kubernetes.io/ingress=ingress
kubectl label node <monitoring-node-name> node-role.kubernetes.io/monitoring=monitoring
```

Tools required on the machine you run these commands from: `kubectl`, `helm`
(>= 3.8 for OCI chart pulls — the MySQL chart is OCI), `kustomize` >= v5.
Every build command below uses `--enable-helm --load-restrictor
LoadRestrictionsNone`: `--enable-helm` runs the chart inflator, and the
load-restrictor is required because a couple of charts/values live just
outside their kustomization root (the crementation chart, the repo-root
gatekeeper policy).

### 1. Namespaces

```sh
for ns in crementation ingress-nginx dashboard monitoring vault external-secrets-system auth gatekeeper-system cert-manager argocd velero vpa; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

> **Secret model:** every secret lives in **Vault** — app/DB creds, Dex/OAuth,
> the Docker Hub pull token, and the Velero AWS keys. External Secrets Operator
> reads Vault and generates all the Kubernetes Secrets at runtime
> (`dockerhub-secret`, `laravel-db`, `mysql-secret`, `dex-secrets`,
> `velero-aws-creds`). ESO authenticates to Vault with **Kubernetes auth** (its
> own ServiceAccount), so there is **no stored bootstrap token** anywhere —
> nothing in git, nothing in GitHub, no local secrets file. The rule holds: if
> it isn't in git, it's in Vault.

### 2. Vault (must come before anything that reads secrets)

Vault is installed standalone here — before the rest of the infra layer —
because it has to be up, initialized, unsealed and seeded before External
Secrets can read from it. It uses the same version and values file that
`infrastructure/kustomization.yaml` pins, so the later infra apply is a no-op
for Vault.

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update hashicorp
helm install vault hashicorp/vault --version 0.28.1 -n vault -f infrastructure/vault/values.yaml

kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=1 -key-threshold=1 \
  > vault-init.txt   # DO NOT COMMIT — holds the unseal key + root token
kubectl -n vault exec -it vault-0 -- vault operator unseal <unseal-key-from-vault-init.txt>
kubectl -n vault exec -it vault-0 -- vault login <root-token>
```

Enable the KV engine, the ESO read policy, and **Kubernetes auth** (this
replaces the old static-token approach — ESO now proves its identity with its
ServiceAccount, so nothing is stored):

```sh
kubectl -n vault exec -it vault-0 -- vault secrets enable -path=secret kv-v2
kubectl -n vault exec -it vault-0 -- vault policy write external-secrets-read - <<'EOF'
path "secret/data/*" { capabilities = ["read"] }
EOF

kubectl -n vault exec -it vault-0 -- vault auth enable kubernetes
kubectl -n vault exec -it vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443
kubectl -n vault exec -it vault-0 -- vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets-system \
  policy=external-secrets-read ttl=1h
```

Seed **all** secrets into Vault (the single source of truth — nothing is
created by hand; ESO turns each of these into a K8s Secret):

```sh
kubectl -n vault exec -it vault-0 -- vault kv put secret/secret \
  DB_HOST=mysql-primary.crementation.svc.cluster.local \
  DB_DATABASE=app_database DB_USERNAME=app_user \
  DB_PASSWORD=<real-password> DB_ROOT_PASSWORD=<real-password> \
  DB_REPLICATION_PASSWORD=<real-password> \
  APP_KEY=<php artisan key:generate --show output>

kubectl -n vault exec -it vault-0 -- vault kv put secret/dex \
  OAUTH2_PROXY_CLIENT_ID=oauth2-proxy \
  OAUTH2_PROXY_CLIENT_SECRET=<real-secret> \
  OAUTH2_PROXY_COOKIE_SECRET=<openssl rand -base64 32 | head -c 32> \
  GITHUB_CLIENT_ID=<from GitHub OAuth app> GITHUB_CLIENT_SECRET=<from GitHub OAuth app>

# Docker Hub pull token (ESO builds the dockerconfigjson pull secret from this):
kubectl -n vault exec -it vault-0 -- vault kv put secret/dockerhub \
  username=maxi2 token=<dckr_pat_...>

# AWS keys for Velero -> S3 (ESO builds the velero-aws-creds secret from this):
kubectl -n vault exec -it vault-0 -- vault kv put secret/aws \
  AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret>

rm vault-init.txt   # keep out of the repo and out of shell history
```

> **All of the above is automated by `personal/bootstrap.sh`** (gitignored) —
> it installs+unseals Vault, configures k8s auth, generates the random secrets,
> and seeds Vault from env vars you export for the one run. See its header.

> In the GitHub OAuth app settings, the **Authorization callback URL** must
> exactly match Dex's issuer + `/callback`. The chart default (before
> `scripts/deploy.sh` patches it to nip.io) is `https://dex.local/callback`
> (see `infrastructure/dex/values.yaml`); once deployed, it's
> `https://dex.<ingress-ip>.nip.io/callback` — update the GitHub OAuth app
> setting to match whichever is actually live, since the ingress IP changes on
> every fresh `terraform apply`. `OAUTH2_PROXY_CLIENT_SECRET` /
> `OAUTH2_PROXY_COOKIE_SECRET` are the oauth2-proxy static-client + cookie
> secrets (Dex-internal, unrelated to GitHub).

### 3. Rest of the infrastructure layer

`infrastructure/kustomization.yaml`'s last resource is `network-policies`,
which is deny-by-default per namespace — applying it now, before any pod
exists, would strand every subsequent install. Comment that one line out for
this step, then restore it for step 7 once everything is actually running:

```sh
sed -i.bak '/- network-policies/s/^/# /' infrastructure/kustomization.yaml

kustomize build --enable-helm --load-restrictor LoadRestrictionsNone infrastructure | kubectl apply -f -
```

This installs metrics-server, cert-manager, ingress-nginx,
kubernetes-dashboard, kube-prometheus-stack, Loki + Alloy, External Secrets
Operator, Dex, oauth2-proxy, ArgoCD, and Gatekeeper (policy + controller).
Re-run if some resources fail on the first pass — CRDs from one chart
(cert-manager, Gatekeeper, Prometheus Operator, External Secrets) need to
exist before dependent resources in the same apply can be created, and
oauth2-proxy's ingress annotations on dashboard/grafana will 503 until
oauth2-proxy itself is up.

> **Namespace note for dex / alloy / kubernetes-dashboard.** These three
> charts don't stamp `metadata.namespace` on their resources (they rely on
> `helm install -n`), and the kustomize helm inflator can't add it. The
> namespaces are pre-created in step 1, so pipe those three through an
> explicit `-n` if you apply them separately, e.g.
> `... | kubectl apply -n auth -f -` for dex,
> `-n monitoring` for alloy, `-n dashboard` for the dashboard. Every other
> chart stamps its own namespace correctly. (ArgoCD users: set
> `destination.namespace` on those Applications, or split them out.)

Confirm auth is actually enforced before moving on:

```sh
curl -skI -H "Host: dashboard.local" https://<ingress-node-public-ip>/ | head -1
# expect: HTTP/1.1 302 Found  (redirected to oauth2-proxy's /oauth2/start, not 200)
# -k because these manifests are still on their committed .local/internal-ca
# defaults at this point in the walkthrough — internal-ca is self-signed, so
# -k (and a browser warning) is expected here. Once step 8's nip.io patch
# runs, this becomes a real Let's Encrypt cert and -k is no longer needed.
```

### 4. Database

```sh
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone applications/mysql | kubectl apply -f -
```

Wait for `mysql-primary-0` and both `mysql-secondary-*` pods to be `Running`
before continuing — the app's readiness probe does not wait for the DB.

### 5. Application

```sh
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone applications/crementation/base | kubectl apply -f -
```

Verify:

```sh
kubectl -n crementation get pods,svc,ingress,hpa
kubectl -n crementation logs deploy/crementation --tail=50
curl -k -H "Host: crementation.local" https://<ingress-node-public-ip>/  # -k: still on internal-ca at this point (see step 8)
```

### 6. Backups

```sh
kubectl apply -k backups/mysql
kubectl -n crementation get cronjob mysql-backup
```

Trigger one manually to confirm it works before relying on the schedule:

```sh
kubectl -n crementation create job --from=cronjob/mysql-backup mysql-backup-manual-test
```

### 7. Network policies

Now that every pod from steps 3-6 is up, restore the line commented out in
step 3 and apply the deny-by-default NetworkPolicies:

```sh
mv infrastructure/kustomization.yaml.bak infrastructure/kustomization.yaml

kustomize build --enable-helm --load-restrictor LoadRestrictionsNone infrastructure | kubectl apply -f -
```

Re-verify auth and app connectivity still work after this — a NetworkPolicy
typo here silently breaks traffic instead of erroring loudly:

```sh
curl -skI -H "Host: crementation.local" https://<ingress-node-public-ip>/ | head -1
curl -skI -H "Host: dashboard.local" https://<ingress-node-public-ip>/ | head -1
kubectl -n crementation logs deploy/crementation --tail=20  # confirm no new DB connection errors
```

If External Secrets Operator stops reconciling after this step: several pods
(external-secrets, Dex, cert-manager, Gatekeeper) need to reach the
Kubernetes API server directly, not just DNS/other pods. The API server's
ClusterIP is cluster-specific and not hardcoded in these policies — most
CNIs (Flannel, used here) implicitly permit apiserver traffic regardless of
NetworkPolicy, but verify this on your cluster; the fix is a per-namespace
`ipBlock` egress rule using `kubectl get svc kubernetes -n default -o
jsonpath='{.spec.clusterIP}'`.

### 8. Public hostnames + trusted certificates (nip.io + Let's Encrypt)

Everything above is still on the chart's committed `.local` hostnames and the
self-signed `internal-ca` issuer. Switch every ingress to a real, publicly
resolvable hostname and a browser-trusted certificate:

```sh
for e in "crementation:crementation:crementation" "grafana:prometheus-grafana:monitoring" \
         "dashboard:kubernetes-dashboard:dashboard" "argocd:argocd-server:argocd" "dex:dex:auth"; do
  sub="${e%%:*}"; rest="${e#*:}"; name="${rest%%:*}"; ns="${rest##*:}"
  host="$sub.<ingress-node-public-ip>.nip.io"
  kubectl -n "$ns" annotate ingress "$name" cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite
  kubectl -n "$ns" patch ingress "$name" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$host\"}]"
  sec=$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.spec.tls[0].secretName}')
  kubectl -n "$ns" patch ingress "$name" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/tls/0/hosts/0\",\"value\":\"$host\"}]"
  kubectl -n "$ns" delete certificate "$sec" secret "$sec" --ignore-not-found  # force LE re-issue
done
```

This is exactly what `scripts/deploy.sh` automates (step 8.5), plus it writes
the `kube-system/nip-io-ingress-ip` ConfigMap so the `nip-io-reconciler`
CronJob keeps re-applying this automatically every 3 minutes — so a manual
`kubectl apply` of any of the manifests above later on doesn't silently revert
you back to `.local`/internal-ca. See docs/project-overview.md.

### Redeploying after a change

Edit the relevant `values.yaml` (chart-level config) or
`crementation/values.yaml` / `crementation/templates/*` (app-level config),
then re-run the matching `kustomize build --enable-helm <path> | kubectl
apply -f -` command above. Do not hand-edit live cluster objects — if you do,
port the change back into the source file immediately.

## ArgoCD (optional GitOps auto-sync)

Per the brief's bonus list ("argoCD to manage your components and GitOps
repositories"). Turns the manual `kustomize build --enable-helm <path> |
kubectl apply -f -` workflow above into: push to `main`, cluster updates
itself within ~3 minutes (default sync interval).

Four `Application` resources (`infrastructure/argocd/argocd-apps.yaml`), each
watching one path in this repo and auto-syncing (`prune: true`, `selfHeal:
true` — drift and manual `kubectl edit` both get reverted automatically):

| Application | Watches | Deploys |
|---|---|---|
| `infrastructure` | `infrastructure/` | metrics-server, cert-manager, ingress-nginx, dashboard, kube-prometheus-stack, Loki+Alloy, Vault, ESO, Dex, oauth2-proxy, Gatekeeper, NetworkPolicies |
| `mysql` | `applications/mysql/` | the official Bitnami MySQL chart |
| `crementation` | `applications/crementation/overlays/prod/` | the app |
| `mysql-backups` | `backups/mysql/` | the backup CronJob + PVC |

ArgoCD can't GitOps-manage its own installation before it exists — it's
installed the same way as everything else in step 3 above (just another
`helmChart` entry in `infrastructure/kustomization.yaml`). Bootstrap the
Application manifests once, manually, right after step 3:

```sh
kubectl apply -f infrastructure/argocd/argocd-apps.yaml
```

From this point on, further changes to `infrastructure/`,
`applications/mysql/`, `applications/crementation/`, or `backups/mysql/` in
git are picked up automatically.

**NetworkPolicy ordering hazard under ArgoCD:** the manual step-3 workaround
(commenting out `network-policies`) does not apply once ArgoCD owns the sync
— the `infrastructure` Application syncs everything, NetworkPolicies
included, as one unit, in the same initial sync that creates the pods those
policies gate. This is usually fine (Kubernetes NetworkPolicy enforcement is
asynchronous relative to object creation, so the target pods are typically up
by the time the CNI programs the policy), but it's a genuine race. If the
first ArgoCD sync of `infrastructure` leaves anything stuck:

1. `kubectl -n argocd patch application infrastructure --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'` (pause auto-sync)
2. Manually delete the `network-policies` resources that landed too early
3. Let the rest settle, confirm everything's `Running`
4. Re-apply NetworkPolicies (`kubectl apply -k infrastructure/network-policies`)
5. Re-enable auto-sync (re-apply `infrastructure/argocd/argocd-apps.yaml`)

To fall back to manual `kubectl`/`kustomize`/`helm` (defense day fallback):
pause auto-sync on every Application (`kubectl -n argocd get applications -o
name | xargs -I{} kubectl -n argocd patch {} --type merge -p
'{"spec":{"syncPolicy":{"automated":null}}}'`) — nothing about the manifests
depends on ArgoCD being present.

## CI/CD

`.github/workflows/ci.yml` runs on every push to `main`, `develop`, and any
`kubequest-*` branch, plus every PR into `main`/`develop`. Four jobs (the
first three are validation and run everywhere; the fourth publishes and runs
on `main` only):

1. **`build-and-scan-image`** — builds the `crementation` app image from
   `sample-app-master/Dockerfile` (scan-only, not pushed anywhere), scans it
   with [Trivy](https://trivy.dev/) (run from its official Docker image to
   avoid the rate-limited binary download). CRITICAL/HIGH findings upload as
   SARIF to the repo's Security tab and print in the job log. It's **report-only**:
   the app is the brief-provided sample (`sample-app-master/`), so we surface
   its CVEs for visibility but don't gate CI on vulnerabilities in code we
   don't own. (The known criticals in its PHP deps were patched via
   `composer.lock` where the `^8.75` constraint allowed; the rest need a
   Laravel major upgrade, out of scope.)

2. **`lint-manifests`** — renders every Kustomize tree this repo deploys
   (`infrastructure/`, `applications/crementation/base/`,
   `applications/mysql/`) via `kustomize build --enable-helm --load-restrictor
   LoadRestrictionsNone`, then runs **kube-linter** (report-only via config
   `.kube-linter.yaml`, which excludes four documented accepted checks —
   `host-network`, `host-port`, `run-as-non-root`, `non-existent-service-account`).
   report-only on the infra render because it's almost entirely third-party
   charts whose securityContext/resource defaults we can't change without
   forking them; the **crementation** chart (ours) is linted blocking. Also
   runs **`helm lint`** on the `crementation/` chart. Because the three renders
   actually pull and template every chart, this job doubles as a "does the
   whole thing still build" gate.

3. **`network-policy-check`** — a repo-structure check confirming every
   namespace that's supposed to have a deny-by-default NetworkPolicy still
   has its file and targets the right namespace, and that
   `infrastructure/kustomization.yaml` hasn't dropped the `network-policies`
   line (the safety net for the step-3 comment-out workaround above never
   accidentally landing in a commit).

4. **`push-app-image`** (main only) — after the validation jobs pass, on a
   push to `main`, builds the app image and pushes it to Docker Hub as
   `maxi2/crementation-app:v1.1.2` + `:latest`. This is what makes app code
   changes (e.g. the `/metrics` endpoint) actually reach the cluster. The tag
   must stay in sync with `crementation/values.yaml`'s `image.tag`. Requires
   two repo secrets — `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (Settings →
   Secrets and variables → Actions). On branches/PRs the image is still built
   (job 1, `push:false`) so every change is validated; only `main` publishes.

**First-deploy note (image + ArgoCD):** because `values.yaml` pins
`v1.1.2`, the app pods can only start once the `push-app-image` job has
published that tag. On the very first `main` deploy, if ArgoCD (or a manual
apply) runs before the image is pushed, the crementation pods `ImagePullBackOff`
until the tag exists — then ArgoCD's `selfHeal`/retry (or `kubectl rollout`)
picks it up automatically. Likewise the crementation app depends on MySQL +
the `laravel-db` secret (Vault → ESO); ArgoCD syncs all four Applications in
parallel with no ordering, so the app pod may restart a few times until its
dependencies are up. Both converge without intervention.

**What's not automated yet:** no cluster-side CD trigger beyond ArgoCD's poll
(no push-based webhook), and no runtime NetworkPolicy enforcement testing
against a live cluster (only that the repo declares the right policies, not
that a running cluster enforces them correctly).

## Security review

Manual review of every chart's `values.yaml` in this repo (a dedicated
security *scan* with kubesec/checkov/trivy runs in CI, see above; this section
is the human review). Findings graded Critical / High / Medium / Low / Info.
Note: all four Kustomize trees have since been render-verified to build with
real `kustomize` + `helm` — the manifests are valid and templatable; the
remaining unverified items are runtime/cluster-behavior (the SSO login loop,
NetworkPolicy vs hostNetwork, per-namespace `-n` for dex/alloy/dashboard),
each flagged inline in the relevant file.

> **ACTION REQUIRED — leaked credential in git history.** A GitHub OAuth
> `clientSecret` and `clientID` were committed in plaintext early in this
> repo's history (commits `887f218` and `73ae92a`, reachable from `main`,
> `develop`, and `kubequest-infra`). They were later redacted from the current
> files and moved to Vault, but **redaction does not remove them from git
> history** — anyone with repo access can still recover them via `git log -p`.
> To neutralize this you must: (1) **rotate the credential** in the GitHub
> OAuth app settings (this is the only step that actually invalidates the
> leaked secret), and (2) optionally scrub history with `git filter-repo` or
> BFG and force-push (coordinate with the team first, since it rewrites shared
> branches). Until the credential is rotated, treat it as compromised.

**Summary:** 2 Critical findings — the previously-unauthenticated Grafana
ingress is fixed (now gated by oauth2-proxy/Dex); the leaked GitHub OAuth
secret is redacted from current files but **still live in git history**
pending credential rotation (see the action-required note above). 3 High
findings, 2
fixed (Prometheus/Alertmanager gained kube-rbac-proxy auth; oauth2-proxy's
`cookie-secure` flag was stale from before TLS existed, now `true`) and 1
still open (Vault's internal listener runs with `tls_disable = true` —
traffic is internal-cluster-only and NetworkPolicy-restricted to
`external-secrets-system` → `vault:8200`, which limits blast radius, but the
channel itself is unencrypted; fixing it means issuing Vault a cert via the
new `internal-ca` issuer, not done yet). Everything else is either passing or
an explicitly accepted trade-off appropriate for a 4-VM course lab cluster:

- **crementation app runs as root** — `php:8.2-apache` binds port 80 as root
  and chmods `storage/` at startup; fixing this needs reworking the base
  image, out of scope for now. `allowPrivilegeEscalation: false` and all
  capabilities dropped are set regardless.
- **No `readOnlyRootFilesystem` on the app** — it writes to
  `storage/`/`bootstrap/cache` at runtime (Laravel convention); would need an
  explicit writable `emptyDir` mount first.
- **MySQL has no explicit securityContext override** — Bitnami's chart ships
  hardened defaults out of the box (non-root UID, dropped capabilities), not
  independently re-verified against this exact chart version.
- **Dex uses in-memory storage** — session/refresh-token state is lost on pod
  restart, forcing re-login; acceptable for a lab cluster.
- **ingress-nginx uses `hostNetwork: true`** — architectural necessity (no
  cloud LoadBalancer on this lab cluster); blast radius is scoped to the
  dedicated `ingress` node and NetworkPolicy restricts its egress to only the
  namespaces it actually proxies to.
- **letsencrypt-prod ClusterIssuer has a placeholder email** — must be
  replaced with a real, monitored address before actually issuing certs
  through it.

## Grafana dashboards

**Crementation - Logs** (`infrastructure/monitoring/dashboards/crementation-logs.json`)
is a pre-built dashboard for the "filtre log monitoring" bonus, with a log
volume by level panel, a filtered log stream (with `$level`/`$pod`
dropdowns), and a raw-text error rate panel.

Getting logs from the app into this dashboard at all required an app-config
fix, not just the dashboard: Laravel's default log channel writes plain-text
lines to a file *inside the container*, which Alloy (the log shipper, tails
stdout/stderr only) never sees. Fixed via two plain environment variables in
`crementation/values.yaml` — `LOG_CHANNEL=stderr` (so logs reach stdout) and
`LOG_STDERR_FORMATTER=Monolog\Formatter\JsonFormatter` (so LogQL's `| json`
filter can parse a `level_name` field out of them). No app code changes.

The dashboard JSON is wrapped in a ConfigMap
(`infrastructure/monitoring/dashboards/kustomization.yaml`) labeled
`grafana_dashboard: "1"`, which kube-prometheus-stack's Grafana sidecar
auto-imports — no manual "import dashboard" click needed.

To demo: log into Grafana (`https://grafana.<ingress-ip>.nip.io`), open
**Crementation - Logs**, trigger some errors
(`./scripts/failure-demo.sh crementation.<ingress-ip>.nip.io crash` a few
times), and watch the error-rate panel spike and the filtered stream update
live (10s refresh).

## Defense day runbook

Per the project brief, the defense has four parts:

**1. Fresh cluster, before presenting** — spin up a new cluster (more nodes
than the 4-VM dev environment) ahead of time, not live. Label the
ingress/monitoring nodes as in the Architecture section, confirm `kubectl get
nodes` shows all `Ready`.

**2. Live deploy, using only kubectl / kustomize / helm** — follow the
Deployment steps 1–6 above live, narrating each command. Nothing should
require editing YAML on the fly.

**3. Autoscaling demo** — the app's HPA (`crementation/values.yaml` →
`autoscaling`) scales 2→5 replicas at 70% CPU:

```sh
kubectl -n crementation get hpa crementation --watch &
./scripts/load-test.sh crementation.<ingress-ip>.nip.io 180 50
```

(No external load-test tool needed — plain bash + curl, drives
`/api/debug/burn-cpu` directly; requires `DEBUG_ENDPOINTS_ENABLED=true`, see
Debug endpoints below. Proven live: 15 concurrent workers for 60s took the HPA
from 2→5 replicas, 2%→367% CPU vs the 70% target.)

Narrate: CPU climbing in Grafana, HPA events firing (`kubectl -n crementation
describe hpa crementation`), new pods scheduling onto whichever node has room
(pod anti-affinity spreads them), Prometheus/Loki picking up new pods
automatically. For a sharper, more deterministic version, use the CPU-burn
debug endpoint directly instead:
`./scripts/failure-demo.sh crementation.<ingress-ip>.nip.io cpu 60`.

**4. Broken deployment + automatic rollback:**

```sh
helm upgrade crementation ./crementation -n crementation --reuse-values \
  --set image.tag=<known-broken-tag>

kubectl -n crementation rollout status deploy/crementation  # hangs/fails — that's the point
kubectl -n crementation describe pod <failing-pod>           # show the failed probe/crash reason

kubectl -n crementation rollout undo deploy/crementation
kubectl -n crementation rollout status deploy/crementation   # back to the last good revision
```

For a sharper version showing a real OOMKill instead of just a failed probe,
use the memory-leak debug endpoint (see below):
`./scripts/failure-demo.sh crementation.<ingress-ip>.nip.io memory 80`, then
watch `kubectl -n crementation get pods --watch` for `RESTARTS` incrementing
and `Last State: Terminated, Reason: OOMKilled`.

**Known fragile points to check the morning of:**
- Vault starts **sealed** after the nightly VM shutdown script — unseal it
  first (step 2 above) or every ExternalSecret is stuck on stale/no data.
- MySQL secondaries take longer to become `Ready` than the primary — don't
  deploy the app before both show `Running`.
- Nothing to configure for hostnames — every service is reachable at
  `https://<name>.<ingress-ip>.nip.io` with zero setup on the presentation
  machine (nip.io is public DNS, no `/etc/hosts` edit needed). Just confirm
  you have the current `<ingress-ip>` (`terraform output ingress_public_ip`);
  it only changes on a full `terraform destroy` + re-apply, not on stop/start.
  If a cert warning ever appears, give it ~3 minutes — the `nip-io-reconciler`
  CronJob self-heals it (see docs/runbooks/troubleshooting.md).

### Debug endpoints

Per the brief's suggestion to "enrich the application code with some memory
leaks, loops consuming CPU, or anything that could lead to errors":
`sample-app-master/app/Http/Controllers/DebugController.php` adds
`/api/debug/burn-cpu`, `/api/debug/leak-memory`, and `/api/debug/crash`,
gated behind `DEBUG_ENDPOINTS_ENABLED` (`false` in
`crementation/values.yaml` — never on in a normal deploy). `scripts/load-test.sh`
and `scripts/failure-demo.sh` drive them for the demos above.

Enable/disable it live for a demo without touching git or re-deploying the
chart:

```sh
kubectl -n crementation set env deploy/crementation DEBUG_ENDPOINTS_ENABLED=true
# ... run the demo ...
kubectl -n crementation set env deploy/crementation DEBUG_ENDPOINTS_ENABLED=false
```
