# Project Overview

KubeQuest is a Kubernetes platform project built around a Laravel application
and a MySQL database. The original application lives in `sample-app-master/`;
the production deployment wraps it with Helm, Kustomize, GitOps, security
controls, monitoring, backups, and demonstration scripts.

The current repository is not only an app deployment. It is a complete lab
platform:

- AWS infrastructure provisioned with Terraform.
- A kubeadm Kubernetes cluster across four EC2 nodes.
- Helm and Kustomize manifests for platform and application workloads.
- ArgoCD Applications for GitOps reconciliation from `main`.
- Vault and External Secrets Operator for runtime secret delivery.
- Dex and oauth2-proxy for protected dashboards.
- Prometheus, Grafana, Loki, and Alloy for metrics and logs.
- NetworkPolicies and Gatekeeper for baseline cluster controls.
- MySQL dumps and Velero for data and cluster backup stories.
- Scripts for fresh-cluster bootstrap, full deployment, load, failure, drain,
  and zero-downtime demos.

## Cluster Shape

The Terraform layer provisions four AWS EC2 nodes:

| Node | Role | Notes |
| --- | --- | --- |
| `kube-1` | control plane and worker | Runs `kubeadm init` and remains schedulable. |
| `kube-2` | worker | General workload capacity. |
| `ingress` | ingress node | Runs ingress-nginx with `hostNetwork` on ports 80 and 443. |
| `monitoring` | observability node | Hosts the heavier monitoring and secrets workloads. |

The dedicated node labels are part of the scheduling contract:

- `node-role.kubernetes.io/ingress=ingress`
- `node-role.kubernetes.io/monitoring=monitoring`
- `node-role.kubernetes.io/worker=worker`

The cluster is bootstrapped with kubeadm and Flannel. Terraform disables source
destination checks so cross-node pod networking works on EC2.

## Application Path

The Laravel app is packaged by the Helm chart in `crementation/`. The chart is
rendered through the Kustomize tree in `applications/crementation/`. The app
uses:

- Two replicas by default.
- A rolling update strategy with `maxUnavailable: 0`.
- An HPA from 2 to 5 replicas at 70 percent CPU.
- A PDB with `minAvailable: 1`.
- A ServiceMonitor scraping `/metrics`.
- Runtime environment generated from Vault-backed Kubernetes Secrets.

MySQL is deployed from the official Bitnami chart through
`applications/mysql/`, with a primary and read replicas. The app connects to
the primary service for writes.

## Platform Path

The platform layer is under `infrastructure/`. Its `kustomization.yaml` renders
third-party charts and local resources for:

- `metrics-server`
- `cert-manager`
- `ingress-nginx`
- `kubernetes-dashboard`
- `kube-prometheus-stack`
- `loki` and `alloy`
- `vault`
- `external-secrets`
- `dex`
- `oauth2-proxy`
- `gatekeeper`
- `velero`
- `vpa`
- `argo-cd`

Some components have runtime ordering requirements. Vault must be installed,
initialized, unsealed, configured, and seeded before External Secrets can
materialize application secrets. CRD-backed components can also need a second
apply on a fresh cluster.

## Traffic Flow

External traffic enters through ingress-nginx on the `ingress` node. The
committed chart defaults are local names such as `crementation.local`,
`grafana.local`, `dashboard.local`, `argocd.local`, and `dex.local` — but the
deploy flow always rewrites these at deploy time.

`scripts/deploy.sh` (step 8.5) patches every ingress to
`<service>.<ingress-ip>.nip.io` and switches its cert-manager issuer to
`letsencrypt-prod`, giving public DNS and trusted browser certificates with
zero client setup (no hosts file, works from any machine). A self-healing
CronJob (`nip-io-reconciler`, `infrastructure/nip-io-reconciler/`, in
`kube-system`) re-checks every 3 minutes and corrects any ingress that drifts
back to the `.local`/self-signed defaults — e.g. after a later manifest
re-apply — so this stays correct with no manual intervention.

The application ingress forwards to the `crementation` Service, which balances
traffic across app pods. Dashboard, Grafana, and ArgoCD are protected by
ingress-nginx auth annotations that delegate login checks to oauth2-proxy.
oauth2-proxy delegates identity to Dex, and Dex uses GitHub OAuth.

## Secrets Flow

Secrets are not committed as Kubernetes Secret manifests. The intended flow is:

1. GitHub Actions secrets or local environment variables provide one-time input
   values.
2. The deploy flow seeds Vault.
3. External Secrets Operator authenticates to Vault through Kubernetes auth.
4. ExternalSecret resources create Kubernetes Secrets at runtime.
5. Workloads consume those Kubernetes Secrets.

The important generated secrets are:

- `laravel-db`
- `mysql-secret`
- `dockerhub-secret`
- `dex-secrets`
- `velero-aws-creds`

## GitOps Flow

ArgoCD is installed as part of the platform layer, then the Application
manifests in `infrastructure/argocd/argocd-apps.yaml` are applied once.

The configured Applications reconcile:

- `infrastructure/`
- `applications/mysql/`
- `applications/crementation/overlays/prod/`
- `backups/mysql/`

Each Application targets `main`, uses automated sync, prunes removed resources,
and self-heals cluster drift.

## Observability Flow

Prometheus scrapes cluster metrics and the app ServiceMonitor. Grafana is
deployed by kube-prometheus-stack and auto-loads the committed dashboards.

Loki stores logs. Alloy ships pod logs. The application chart configures Laravel
to log to stderr with a JSON formatter so the logs are visible to Alloy and
queryable in Grafana with LogQL JSON filters.

## Recovery Story

The project has two backup layers:

- `backups/mysql/` runs a nightly `mysqldump` CronJob into a PVC and prunes
  old dumps after seven days.
- Velero backs up Kubernetes resources and volumes into the configured S3
  bucket, allowing namespace or cluster restore demos.

Together these cover both the application data story and the broader platform
restore story expected for the defense.
