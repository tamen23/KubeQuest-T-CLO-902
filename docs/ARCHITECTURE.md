# Architecture

## Infrastructure

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

Application and platform pods (crementation app, MySQL, Dex, Gatekeeper, External
Secrets) are scheduled across `kube-1`/`kube-2` by the default scheduler, using
pod anti-affinity to spread replicas across the two.

## Namespaces

| Namespace                | Contents                                              |
|---------------------------|--------------------------------------------------------|
| `crementation`             | The app (Deployment, Service, Ingress, HPA), MySQL (primary + 2 secondaries), MySQL backup CronJob |
| `ingress-nginx`             | ingress-nginx controller                               |
| `dashboard`                 | kubernetes-dashboard                                    |
| `monitoring`                | kube-prometheus-stack (Prometheus, Grafana, Alertmanager, kube-rbac-proxy sidecars), Loki, Alloy |
| `vault`                     | HashiCorp Vault (single-node, Raft storage)             |
| `external-secrets-system`   | External Secrets Operator                               |
| `auth`                      | Dex (OIDC provider, GitHub org connector), oauth2-proxy (enforces login on dashboard/Grafana/ArgoCD ingresses) |
| `gatekeeper-system`         | OPA Gatekeeper (policy: reject `:latest` image tags)     |
| `cert-manager`              | cert-manager (internal-ca + letsencrypt-prod ClusterIssuers) |
| `argocd`                    | ArgoCD (GitOps auto-sync — see `docs/ARGOCD.md`)         |

## Repository layout

- `crementation/` — Helm chart for the app (source of truth for its manifests)
- `applications/crementation/` — Kustomize base/overlay that renders the chart above via `kustomize build --enable-helm`
- `applications/mysql/` — Kustomize wrapper around the official Bitnami MySQL chart
- `infrastructure/` — cluster-wide platform components (ingress, dashboard, monitoring, logging, secrets, auth, policy), one `values.yaml` per component plus a top-level `kustomization.yaml`
- `backups/mysql/` — CronJob + PVC for nightly `mysqldump` backups
- `components/gatekeeper/` — the actual OPA policy (ConstraintTemplate + Constraint)
- `infrastructure/network-policies/` — deny-by-default NetworkPolicy per namespace (see `docs/SECURITY-REVIEW.md`)
- `infrastructure/argocd/` — ArgoCD Helm values + the Application manifests it uses to watch this repo (see `docs/ARGOCD.md`)
- `.github/workflows/ci.yml` — image build + CVE scan, manifest lint, NetworkPolicy coverage check (see `docs/CI-CD.md`)
- `sample-app-master/` — original Laravel + MySQL application source, previously deployed via `docker-compose.yaml`; this is what the Helm chart in `crementation/` packages for Kubernetes

## Data flow

```
Internet
  |
  v
ingress node (nginx-ingress, hostNetwork:80/443)
  |
  +--> crementation.local  -> crementation app Service -> crementation Deployment (2+ pods, kube-1/kube-2)
  |                                                              |
  |                                                              v
  |                                                     mysql-primary (writes) / mysql-read (reads)
  |
  +--> dashboard.local -> [auth-url/auth-signin check] -> oauth2-proxy -> kubernetes-dashboard
  |
  +--> grafana.local   -> [auth-url/auth-signin check] -> oauth2-proxy -> Grafana (monitoring node)
  |
  +--> argocd.local    -> [auth-url/auth-signin check] -> oauth2-proxy -> ArgoCD server

All ingress hostnames terminate TLS at ingress-nginx via cert-manager
(internal-ca ClusterIssuer today; swap to letsencrypt-prod once served from a
real domain — see infrastructure/cert-manager/cluster-issuers.yaml).

oauth2-proxy delegates login to Dex (OIDC issuer, GitHub org connector); a
request that fails the ingress-nginx auth-url check is redirected to
oauth2-proxy's /oauth2/start, which redirects to Dex, which redirects to
GitHub. ingress-nginx re-checks auth-url on every request.

Direct PromQL/Alertmanager API access (bypassing Grafana) goes through a
second, narrower gate: kube-rbac-proxy sidecars in front of Prometheus and
Alertmanager, authorizing via Kubernetes RBAC (SubjectAccessReview) instead
of Dex — see infrastructure/monitoring/prometheus/rbac.yaml and
docs/SECURITY-REVIEW.md.

Every namespace above also has a deny-by-default NetworkPolicy
(infrastructure/network-policies/) restricting pod-to-pod traffic to only the
paths drawn in this diagram — see docs/SECURITY-REVIEW.md for the full
per-namespace breakdown.

Secrets flow: Vault (monitoring node) --> External Secrets Operator --> Kubernetes Secrets
  (laravel-db, mysql-secret, dex-secrets) --> consumed via envFrom by the relevant pods
  (dex-secrets is also read directly by oauth2-proxy for its client + cookie secrets)

GitOps flow (optional, see docs/ARGOCD.md): git push to main --> ArgoCD
  detects the change --> auto-syncs infrastructure/, applications/mysql/,
  applications/crementation/, backups/mysql/ --> cluster converges without
  a manual kubectl/kustomize/helm apply.
```

## Why these choices

- **kustomize `helmCharts` inflator** instead of committing rendered/`helm get manifest` YAML: every component has exactly one editable source (its `values.yaml`), so `kubectl diff`/`kustomize build` never drifts from what's actually deployed.
- **DaemonSet + hostNetwork for ingress-nginx**: this lab cluster has no cloud LoadBalancer in front of it, so the ingress controller binds host ports directly on the dedicated `ingress` node.
- **Vault single-node with Raft storage, no auto-unseal**: full HA + auto-unseal needs a cloud KMS this lab account doesn't have. Traded off for a documented manual unseal step (see `docs/deployment/deployment.md`) instead of the previous dev-mode Pod with a hardcoded root token.
- **MySQL via the official Bitnami chart in `replication` mode** (1 primary + 2 secondaries) satisfies both the brief's "use the official chart for the database" requirement and its redundancy requirement.
- **cert-manager with a self-signed internal-ca ClusterIssuer** (not just Let's Encrypt): Let's Encrypt's HTTP-01 challenge needs a real public DNS record pointing at the ingress node, which a `.local` hostname can never satisfy. The internal CA gets TLS actually running end-to-end today; switching to `letsencrypt-prod` is a one-line annotation change once a real domain exists.
- **kube-rbac-proxy in front of Prometheus/Alertmanager, on top of (not instead of) oauth2-proxy/Dex on Grafana**: two independent gates for two independent audiences — Grafana users go through Dex/GitHub org membership, while anyone querying PromQL directly needs a Kubernetes RBAC grant. Removing either one narrows, not widens, what's protected.
- **ArgoCD as an optional layer over the existing manual `kubectl`/`kustomize`/`helm` flow, not a replacement for it**: every Application it manages points at the exact same paths `docs/deployment/deployment.md` already documents manually, so the underlying manifests never depend on ArgoCD being present — see `docs/ARGOCD.md`'s fallback section.
