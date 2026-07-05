# Defense Day Guide

This guide turns the repository into a presentation sequence. It does not
replace the deployment runbooks; it gives a clean order for explaining and
demonstrating the project.

## Goal

Show that the project delivers a full Kubernetes platform around the Laravel
and MySQL application:

- fresh cloud cluster;
- Kubernetes deployment through Helm and Kustomize;
- GitOps with ArgoCD;
- secrets through Vault and External Secrets Operator;
- SSO-protected dashboards;
- monitoring, logs, and alerts;
- NetworkPolicies and admission policy;
- autoscaling, rollback, disruption handling, and backups.

## Before The Presentation

Prepare the cluster ahead of time:

```sh
bash scripts/cluster-up.sh
```

Then copy the repository to `kube-1`, export deployment inputs, and run:

```sh
bash ~/kubequest/scripts/deploy.sh
```

Check the platform:

```sh
kubectl get nodes
kubectl get pods -A
kubectl get externalsecrets -A
kubectl -n argocd get applications
kubectl -n crementation get pods,svc,ingress,hpa
```

Open the app, Grafana, Dashboard, and ArgoCD URLs printed by the deploy script.
Certificates can take a short time to settle after Let's Encrypt issuance.

## Presentation Sequence

1. Start with the architecture.
   Explain the four-node AWS layout, the role split, and why ingress and
   monitoring have dedicated nodes.

2. Show repository structure.
   Point at `terraform/`, `infrastructure/`, `applications/`, `crementation/`,
   `backups/`, `components/gatekeeper/`, `.github/workflows/`, and `scripts/`.

3. Show fresh cluster path.
   Explain `scripts/cluster-up.sh`: Terraform, kubeadm, Flannel, node labels,
   ingress IP.

4. Show deployment path.
   Explain `scripts/deploy.sh`: namespaces, local-path storage, Vault, ESO,
   infrastructure, namespace fixes, MySQL, app, backups, nip.io, cert-manager,
   NetworkPolicies.

5. Show GitOps.
   Open ArgoCD and show the Applications watching `main`:
   infrastructure, MySQL, crementation, and MySQL backups.

6. Show secrets.
   Explain that secrets are seeded into Vault and materialized by ESO. Show
   ExternalSecrets, not secret values.

7. Show app availability.
   Open the app URL and show app pods, HPA, Service, Ingress, and MySQL pods.

8. Show observability.
   Open Grafana dashboards, show metrics, logs, and alert rules.

9. Run one resilience demo.
   Use autoscaling, drain, zero-downtime rollout, or rollback depending on the
   time available.

10. Show backups.
    Show MySQL CronJob and Velero schedule. If time allows, run an on-demand
    namespace backup.

## Strong Talking Points

- The app is not manually converted YAML; it is a Helm chart rendered by
  Kustomize.
- The database uses the official Bitnami MySQL chart.
- Runtime secrets do not live in Git.
- ArgoCD watches the same paths that can be deployed manually.
- NetworkPolicies are deny-by-default but applied after bootstrap to avoid
  blocking first install.
- The app has both HPA and VPA coverage, but VPA is recommendation-only to
  avoid fighting the HPA.
- Ingress uses `hostNetwork` because the lab has no cloud LoadBalancer.
- nip.io and Let's Encrypt make the final URLs public and browser-friendly.
- CI validates image build, vulnerability visibility, manifest rendering, chart
  linting, and NetworkPolicy coverage.

## Things Not To Show

Do not print:

- Vault root token.
- Vault unseal key.
- GitHub OAuth secret.
- Docker Hub token.
- AWS keys.
- Kubernetes Secret values.
- `vault kv get` output with real data.

Prefer showing:

```sh
kubectl get externalsecrets -A
kubectl get secret -n crementation
kubectl -n vault exec vault-0 -- vault status
```

## Fallbacks

If SSO is slow, show the protected ingress redirect and explain the
Dex/oauth2-proxy path.

If certificates are still issuing, use `curl -k` or explain the short
cert-manager delay.

If ArgoCD is still syncing, show the manual Kustomize/Helm source paths and the
Application status.

If HPA does not scale in time, show `kubectl describe hpa`, metrics-server, and
the configured thresholds in `crementation/values.yaml`.

If a demo endpoint is disabled, do not enable it live unless you have time to
re-apply and roll back the flag afterward.

## Closing Summary

End with the platform story:

```text
Terraform creates the machines.
kubeadm creates the cluster.
Kustomize and Helm define the stack.
Vault and ESO provide secrets.
ArgoCD keeps the cluster aligned with main.
Prometheus, Grafana, Loki, and Alloy make it observable.
Policies, backups, and demos prove operational maturity.
```
