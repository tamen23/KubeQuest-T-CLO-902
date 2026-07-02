# Brief compliance audit

Status as of the last audit pass, before deployment. 18 requirements extracted
from `project.pdf`. Re-run this audit after any significant change to
`infrastructure/` or `applications/` — it is not automatically kept in sync.

| # | Requirement | Status | Evidence / gap |
|---|-------------|--------|-----------------|
| 1 | Internal load balancer / ingress (nginx-ingress) | PASS | `infrastructure/kustomization.yaml` wires `ingress-nginx` chart to `infrastructure/ingress-nginx/values.yaml` |
| 2 | User-friendly dashboard (kubernetes-dashboard) | PASS | `infrastructure/kustomization.yaml` wires `kubernetes-dashboard` chart to `infrastructure/dashboard/values.yaml` |
| 3 | Monitoring stack (kube-prometheus) | PASS | `infrastructure/kustomization.yaml` wires `kube-prometheus-stack` to `infrastructure/monitoring/prometheus/values-prometheus.yaml` |
| 4 | GitOps repo with reusable component manifests (kustomize) | PASS | `infrastructure/kustomization.yaml` uses kustomize `helmCharts` inflator for all 9 platform components |
| 5 | Logging stack (loki) | PASS | `loki` + `alloy` charts wired in `infrastructure/kustomization.yaml`; Loki added as Grafana datasource in `values-prometheus.yaml` |
| 6 | Convert docker-compose app to Helm chart; official chart for DB | PASS | `crementation/` is a full Helm chart; `applications/mysql/kustomization.yaml` uses the official `bitnami/mysql` chart |
| 7 | GitOps repo (kustomize) to deploy the app | PASS | `applications/crementation/base/kustomization.yaml`, `applications/mysql/kustomization.yaml` |
| 8 | Automate deployment and verify application status | PASS | `docs/deployment/deployment.md` gives exact apply + verify commands per component |
| 9 | Resource limits and requests (CPU/RAM) | PASS | Verified on crementation, MySQL primary/secondary, Vault, Dex, Prometheus/Grafana/Alertmanager, dashboard, backup CronJob |
| 10 | Secrets used to host sensitive data | PASS | Vault + External Secrets Operator pattern throughout; no plaintext credentials in tracked manifests |
| 11 | Label all resources per Kubernetes recommendations | PARTIAL | Crementation chart + backup resources set explicit `app.kubernetes.io/*` labels. Vault/Dex/dashboard/Prometheus-stack/Loki/Alloy/MySQL values files set no custom labels and rely on upstream chart defaults (likely compliant, never verified) |
| 12 | Redundancy: multiple replicas + affinity rules | PASS | `crementation/values.yaml` sets `replicaCount: 2` + HPA + real `podAntiAffinity`, actually rendered in `templates/deployment.yaml`. MySQL secondary replicaCount: 2 |
| 13 | Persistent storage for DB + backup system | PASS | MySQL primary/secondary persistence enabled (`local-path`); `backups/mysql/cronjob.yaml` (daily mysqldump, 7-day retention) + `pvc.yaml` |
| 14 | Validating webhook (OPA) | PASS | `gatekeeper` chart installed; `components/gatekeeper/` has a real ConstraintTemplate + Constraint rejecting `:latest` tags |
| 15 | Authentication to K8s API and tools (dex + oauth-proxy) | **FIXED** (was FAIL) | Dex was deployed but nothing consumed it — dashboard/Grafana had zero auth enforcement. Fixed by deploying oauth2-proxy + wiring ingress auth annotations. See below. |
| 16 | Push configuration into a repo | PASS | Real git remote, existing commit history |
| 17 | Documentation (setup steps and commands) | PASS | `docs/ARCHITECTURE.md`, `docs/deployment/deployment.md`, `docs/deployment/defense.md` |
| 18 | Defense readiness (fresh cluster, kubectl/kustomize/helm-only deploy, autoscaling demo, broken deploy + rollback demo) | PASS (as docs) | `docs/deployment/defense.md` scripts all four |

## Fix applied for #15

Root cause: `infrastructure/dex/values.yaml` had a Dex `staticClients` entry
*named* `oauth2-proxy`, but no oauth2-proxy component was ever deployed to
use it, and no ingress had `auth-url`/`auth-signin` annotations — so
`dashboard.local` and Grafana were reachable with no login at all.

Fix:
1. Added `infrastructure/oauth2-proxy/values.yaml` — a real oauth2-proxy Helm
   chart install, configured against the Dex OIDC issuer, using the
   `OAUTH2_PROXY_CLIENT_SECRET` already provisioned (but previously unused)
   in `infrastructure/dex/external-secret.yaml`.
2. Added the `oauth2-proxy` chart entry to `infrastructure/kustomization.yaml`.
3. Added `nginx.ingress.kubernetes.io/auth-url` / `auth-signin` annotations to
   `infrastructure/dashboard/values.yaml` and to the Grafana ingress in
   `infrastructure/monitoring/prometheus/values-prometheus.yaml`, so
   ingress-nginx actually forces every request through oauth2-proxy before it
   reaches the dashboard or Grafana backends.
4. Updated `docs/deployment/deployment.md` and `docs/ARCHITECTURE.md` to
   reflect the new component and apply order.

## Remaining minor item (#11)

Not fixed in this pass — low severity, does not block deployment. Chart
defaults for Vault/Dex/dashboard/kube-prometheus-stack/Loki/Alloy/MySQL are
widely believed to follow the `app.kubernetes.io/*` convention (they're all
mainstream, well-maintained charts), but this was not independently verified
by rendering each chart's templates. If you want this closed out fully,
run `helm template <chart> -f <values> | grep app.kubernetes.io` per
component and confirm, or add explicit `commonLabels`/`podLabels` overrides.
