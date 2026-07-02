# T-CLO-902-PAR_4 — KubeQuest

Kubernetes GitOps deployment for the KubeQuest project: a full cluster
platform (ingress, dashboard, monitoring, logging, secrets, auth, policy)
plus a Laravel + MySQL application converted from docker-compose to Helm/Kustomize.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — infrastructure layout, namespaces, data flow
- [Deployment](docs/deployment/deployment.md) — step-by-step apply order (kubectl/kustomize/helm)
- [Defense runbook](docs/deployment/defense.md) — live demo script (autoscaling, broken deploy + rollback)
- [ArgoCD](docs/ARGOCD.md) — optional GitOps auto-sync layer
- [CI/CD](docs/CI-CD.md) — image scanning, manifest linting
- [Grafana dashboards](docs/GRAFANA-DASHBOARDS.md) — log filtering setup
- [Security review](docs/SECURITY-REVIEW.md) — Helm chart security evaluation

## Repository layout

- `crementation/` — Helm chart for the app
- `applications/` — Kustomize trees deploying the app + MySQL
- `infrastructure/` — cluster-wide platform components
- `backups/` — database backup CronJobs
- `sample-app-master/` — the original Laravel application source
- `scripts/` — load-test and failure-injection scripts for the defense demo
