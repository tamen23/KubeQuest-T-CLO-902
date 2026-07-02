# Helm artefact security evaluation

Manual review of every chart's `values.yaml` in this repo, since no
`helm`/`kubesec`/`checkov`/`trivy` binaries were available in the environment
this was written in. An automated version of this check (Trivy for image
CVEs, kube-linter/Checkov for manifest misconfig) runs in CI on every push —
see `.github/workflows/ci.yml` and `docs/CI-CD.md`. Treat this document as
the baseline; the CI job is what actually enforces it going forward.

Findings are graded Critical / High / Medium / Low / Info, same convention as
kubesec/Checkov output, so this doc reads the same way a scanner's report
would.

## crementation (`crementation/`, the app chart)

| Finding | Severity | Status |
|---|---|---|
| Container runs as root (no `runAsNonRoot`) | Medium | **Accepted, documented.** `php:8.2-apache` binds port 80 as root and the entrypoint chmods `storage/` at startup — see the comment directly above `podSecurityContext: {}` in `crementation/values.yaml`. Fixing this needs reworking the base image to use a non-privileged port + pre-baked permissions, out of scope for this pass. |
| `allowPrivilegeEscalation: false`, all capabilities dropped | — | **Pass.** Set in `crementation/values.yaml` → `securityContext`. |
| Resource requests/limits set | — | **Pass.** |
| `imagePullPolicy: Always` on a mutable tag-based image | Low | **Accepted.** `tag: v1.0.1` is a fixed version, not `:latest` (Gatekeeper blocks `:latest` cluster-wide — see `components/gatekeeper/`), so `Always` just means "verify against the registry every restart," not "run whatever's newest." |
| No `readOnlyRootFilesystem` | Low | **Open.** The image writes to `storage/`/`bootstrap/cache` at runtime (Laravel convention), so this needs an explicit writable `emptyDir` mount for those paths before `readOnlyRootFilesystem: true` is safe. Not done in this pass — flagged for follow-up. |
| Secrets via `envFrom` referencing a Kubernetes Secret, not inline | — | **Pass.** `laravel-db` Secret is populated by External Secrets Operator from Vault, never committed. |
| Pod anti-affinity (hard) + 2+ replicas | — | **Pass**, also satisfies the brief's redundancy requirement. |

## mysql (`applications/mysql/`, official Bitnami chart)

| Finding | Severity | Status |
|---|---|---|
| `auth.existingSecret` used, no inline passwords | — | **Pass.** |
| Root password + app password both externalized via Vault/ESO | — | **Pass.** |
| Replication mode (1 primary + 2 secondaries) | — | **Pass**, matches brief's redundancy + official-chart requirements. |
| Persistence enabled with real storage class | — | **Pass.** |
| No explicit `podSecurityContext`/`securityContext` override | Info | **Accepted.** Bitnami's MySQL chart ships hardened defaults (non-root UID, dropped capabilities) out of the box — not re-specified here since the chart default already covers it. Not independently re-verified against this exact chart version (no `helm template` access); worth a spot check before defense day.
| No NetworkPolicy scoping who can reach 3306 | — | **Fixed in this pass.** `infrastructure/network-policies/crementation.yaml` now restricts MySQL ingress to only the app and backup CronJob pods. |

## vault (`infrastructure/vault/values.yaml`)

| Finding | Severity | Status |
|---|---|---|
| `tls_disable = true` on Vault's own listener | **High** | **Open, documented risk.** Traffic is internal-cluster-only and now restricted by `infrastructure/network-policies/vault.yaml` to only `external-secrets-system` → `vault:8200`, which limits blast radius, but the Vault↔ESO channel itself is unencrypted. Fix: generate a cert via the new `internal-ca` cert-manager issuer (Tier 1.1) and set `listener "tcp" { tls_cert_file / tls_key_file }` — not done in this pass, tracked as a follow-up since it touches Vault's own bootstrapping flow documented in `docs/deployment/deployment.md`. |
| Single replica, no HA/auto-unseal | Medium | **Accepted, documented.** See the comment block at the top of `infrastructure/vault/values.yaml` — deliberate trade-off for a course lab cluster with no cloud KMS. |
| No hardcoded root token (fixed earlier this project) | — | **Pass.** |
| Resource limits set | — | **Pass.** |

## dex (`infrastructure/dex/values.yaml`)

| Finding | Severity | Status |
|---|---|---|
| GitHub OAuth secret previously committed in plaintext | Critical | **Fixed earlier this project** — redacted, moved to Vault, documented as needing rotation. |
| `storage.type: memory` | Medium | **Accepted.** Means Dex's session/refresh-token state is lost on pod restart, forcing re-login — acceptable for a lab cluster; a real deployment would use `storage.type: kubernetes` (CRDs) or a real DB backend. |
| `issuer` served over plain HTTP internally | Low | **Accepted.** Cluster-internal only (`dex.auth.svc.cluster.local`), same reasoning as Vault above but lower severity since Dex doesn't hold long-lived secrets itself, only issues short-lived tokens. |

## oauth2-proxy (`infrastructure/oauth2-proxy/values.yaml`)

| Finding | Severity | Status |
|---|---|---|
| `cookie-secure: "false"` | High | **Fixed in this pass** — flipped to `"true"` now that dashboard.local/grafana.local serve TLS via cert-manager (Tier 1.1). Was stale from before TLS existed. |
| Client secret / cookie secret sourced from Kubernetes Secret, not inline | — | **Pass.** |
| 2 replicas | — | **Pass**, no single point of failure on the auth gate. |

## ingress-nginx (`infrastructure/ingress-nginx/values.yaml`)

| Finding | Severity | Status |
|---|---|---|
| `hostNetwork: true` | Medium | **Accepted, architectural necessity.** This lab cluster has no cloud LoadBalancer; the ingress controller must bind host ports 80/443 directly. Blast radius is scoped to the dedicated `ingress` node via `nodeSelector`/`tolerations`, and `infrastructure/network-policies/ingress-nginx.yaml` restricts its egress to only the 4 backend namespaces it actually proxies to. |
| Resource limits set | — | **Pass.** |

## kube-prometheus-stack / loki / alloy (`infrastructure/monitoring/`)

| Finding | Severity | Status |
|---|---|---|
| Prometheus/Alertmanager UIs previously reachable cluster-internally with zero auth | High | **Fixed in this pass** — kube-rbac-proxy sidecars added (Tier 1.3), only reachable via a Kubernetes RBAC-authorized identity. |
| Grafana ingress previously had no auth at all (didn't exist) | Critical | **Fixed earlier this project** — oauth2-proxy/Dex gate added, TLS added this pass. |
| Alloy DaemonSet tolerates all taints, no nodeSelector | Info | **Accepted, by design.** A log shipper needs to run on every node including tainted ones to collect logs cluster-wide; this is the correct configuration, not an oversight. |
| Persistent storage + resource limits on Prometheus/Alertmanager/Grafana | — | **Pass.** |

## cert-manager, external-secrets (`infrastructure/cert-manager/`, `infrastructure/external-secrets/`)

| Finding | Severity | Status |
|---|---|---|
| `letsencrypt-prod` issuer has a placeholder email (`admin@example.com`) | Low | **Open, flagged.** Must be replaced with a real, monitored address before actually issuing certs through it — Let's Encrypt sends expiry/policy notices there. See `infrastructure/cert-manager/cluster-issuers.yaml`. |
| ClusterSecretStore token sourced from Kubernetes Secret, not inline | — | **Pass.** |
| Resource limits on cert-manager/webhook/cainjector | — | **Pass.** |

## Summary

- **2 Critical findings** — both already fixed earlier in this project (leaked GitHub secret, unauthenticated Grafana ingress).
- **3 High findings** — 2 fixed in this pass (Prometheus/Alertmanager auth, oauth2-proxy cookie security); **1 still open** (Vault's unencrypted internal listener — tracked, not blocking given the NetworkPolicy containment, but should be closed before a real production use case).
- **Everything else** is either passing or an explicitly accepted, documented trade-off appropriate for a 4-VM course lab cluster (Vault HA, Dex in-memory storage, ingress-nginx hostNetwork).

No Critical or High finding was left silently unaddressed — each either has a
fix applied in this pass or an explicit written justification for why it's
accepted as-is.
