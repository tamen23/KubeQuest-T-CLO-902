# Security Model

This page documents the security controls already present in the repository.
It focuses on the intended operating model, not on a theoretical production
hardening plan.

## Security Objectives

The project aims to show that the Kubernetes platform has:

- No committed runtime secrets.
- A central secret source of truth.
- Protected admin dashboards.
- Baseline namespace isolation.
- Policy checks for authored workloads.
- CI visibility for image vulnerabilities and manifest hygiene.
- Explicit documentation of accepted lab trade-offs.

## Secret Ownership

Vault is the source of truth for runtime secrets. Kubernetes Secrets are
generated from Vault by External Secrets Operator and are not committed by hand.

The main flow is:

1. One-time inputs come from GitHub Actions secrets or local environment
   variables.
2. The deploy path seeds those values into Vault.
3. External Secrets Operator authenticates to Vault through Kubernetes auth.
4. ExternalSecret resources create Kubernetes Secrets.
5. Pods consume those Kubernetes Secrets through `envFrom`, chart values, or
   image pull secret references.

Important generated Kubernetes Secrets:

| Secret | Namespace | Purpose |
| --- | --- | --- |
| `laravel-db` | `crementation` | Laravel DB env vars and `APP_KEY`. |
| `mysql-secret` | `crementation` | Bitnami MySQL chart credentials. |
| `dockerhub-secret` | `crementation` | Private image pull secret. |
| `dex-secrets` | `auth` | Dex and oauth2-proxy OAuth values. |
| `velero-aws-creds` | `velero` | AWS credentials used by Velero. |

## Vault Authentication

External Secrets Operator uses Vault Kubernetes auth, configured by
`infrastructure/external-secrets/clustersecretstore.yaml`.

ESO proves its identity with its ServiceAccount token. Vault validates that
token against the Kubernetes API and issues a short-lived Vault token tied to
the `external-secrets-read` policy.

This avoids storing a long-lived Vault token in GitHub, in the repository, or
in a local bootstrap file.

## Identity And Access

The user-facing admin tools are protected through:

- ingress-nginx auth annotations.
- oauth2-proxy as the authentication gate.
- Dex as the OIDC provider.
- GitHub OAuth as the external identity source.

Dashboard, Grafana, and ArgoCD route through oauth2-proxy. Dex has its own
external ingress because the browser must be able to reach the OIDC issuer and
callback path.

Prometheus and Alertmanager direct API access is protected separately through
kube-rbac-proxy and Kubernetes RBAC.

## Network Isolation

`infrastructure/network-policies/` defines a deny-by-default model for the
main namespaces, then grants only the traffic paths the stack needs:

- ingress to public services.
- app to MySQL.
- MySQL backup job to MySQL.
- Prometheus scraping.
- ESO to Vault.
- oauth2-proxy to Dex.
- Dex to GitHub over HTTPS.
- DNS egress to kube-system.

NetworkPolicies are applied after bootstrap because applying them too early can
block CRDs, webhooks, auth services, or secrets reconciliation before the allow
rules and backing pods exist.

## Admission Policy

Gatekeeper enforces the project-owned image tag policy. The committed
constraint rejects `:latest` image tags for Pods and common workload
controllers in the `crementation` namespace.

The scope is intentionally limited to workloads this repository authors.
Applying the same policy cluster-wide could block vendored third-party charts
that the project does not directly control.

## CI Safety Nets

`.github/workflows/ci.yml` provides these security checks:

- Docker image build from `sample-app-master/Dockerfile`.
- Trivy scan for critical and high vulnerabilities, report-only.
- Kustomize renders for infrastructure, app, and MySQL.
- kube-linter for rendered manifests.
- Blocking kube-linter check for the app chart.
- Helm lint for the app chart.
- NetworkPolicy coverage check.

The app image vulnerability scan is report-only because the app is based on the
provided sample. The scan still exposes the findings in the job logs and, when
available, GitHub code scanning.

## Accepted Lab Trade-Offs

The repository documents several accepted trade-offs:

- Vault internal listener uses HTTP inside the cluster.
- ingress-nginx uses `hostNetwork` because there is no cloud LoadBalancer.
- The Laravel image starts as root because `php:8.2-apache` binds port 80 and
  needs startup-time file permission fixes.
- The app root filesystem is writable because Laravel writes runtime state.
- Dex uses in-memory storage, so users may need to log in again after a Dex
  restart.
- Some chart-driven kube-linter findings are report-only because fixing them
  would require forking third-party charts.

These are acceptable for the course lab scope, but they should be revisited for
a long-lived production cluster.

## Known Credential History Risk

The root README documents a historical GitHub OAuth credential leak in Git
history. Redacting current files does not invalidate a secret that was already
committed.

The required remediation is to rotate the credential in the GitHub OAuth app.
History rewriting with BFG or `git filter-repo` is optional and must be
coordinated because it rewrites shared branches.
