# Full Deployment Runbook

This runbook documents the full deployment path implemented by
`scripts/deploy.sh`. It is meant to run on `kube-1` after the fresh cluster has
been created.

Run from a checkout copied to `~/kubequest` on the control-plane node:

```sh
export GH_ID=...
export GH_SECRET=...
export DH_USER=maxi2
export DH_TOKEN=...
export AWS_KEY=...
export AWS_SECRET=...
export INGRESS_PUBLIC_IP=<ingress-eip>

bash ~/kubequest/scripts/deploy.sh
```

The script is idempotent enough for lab use and is designed to avoid manual
YAML editing during the defense.

## Required Inputs

The script requires these values:

| Variable | Purpose |
| --- | --- |
| `GH_ID` | GitHub OAuth client ID used by Dex. |
| `GH_SECRET` | GitHub OAuth client secret used by Dex. |
| `DH_USER` | Docker Hub username used for image pull secrets. |
| `DH_TOKEN` | Docker Hub token used for image pull secrets. |
| `AWS_KEY` | AWS access key used by Velero. |
| `AWS_SECRET` | AWS secret key used by Velero. |
| `INGRESS_PUBLIC_IP` | Public IP used for nip.io hostnames and certificates. |

The script generates database passwords, oauth2-proxy secrets, and the Laravel
`APP_KEY` itself, then stores them in Vault.

## Deployment Sequence

The script executes the stack in an order that matches the platform
dependencies:

1. Install missing local tooling on `kube-1`: Helm and Kustomize.
2. Create all required namespaces.
3. Install the Rancher local-path provisioner and mark it as the default
   StorageClass.
4. Install Vault, initialize it if needed, and unseal it.
5. Configure Vault KV, policy, Kubernetes auth, and seed secrets.
6. Render and apply `infrastructure/` without NetworkPolicies first.
7. Re-apply after CRDs and webhooks have had time to settle.
8. Correct namespace stamping for Dex, Alloy, and Kubernetes Dashboard.
9. Apply MySQL, the app, and MySQL backup resources.
10. Wait for the app rollout.
11. Patch public nip.io hostnames and switch ingresses to Let's Encrypt when
    `NIPIO=1`.
12. Apply deny-by-default NetworkPolicies last.
13. Restart ingress-nginx and probe public service routes.
14. Print cluster health, ExternalSecret status, and browser URLs.

## Why NetworkPolicies Are Last

The NetworkPolicy layer is deny-by-default by namespace. Applying it too early
can block pods while they are still being installed, especially when CRDs,
webhooks, Vault, External Secrets, Dex, and ingress components are all starting
at the same time.

The script temporarily comments out `network-policies` from
`infrastructure/kustomization.yaml`, applies the platform, restores the file,
then applies policies after the main workloads exist.

This is an operational bootstrap step only. The committed source keeps
`network-policies` referenced, and CI checks that the reference remains present.

## Namespace Fix Phase

Dex, Alloy, and Kubernetes Dashboard charts do not stamp
`metadata.namespace` in every rendered object when they are inflated by
Kustomize. The script handles this by rendering those charts with
`helm template -n <namespace>` and applying them explicitly into:

- `auth` for Dex.
- `monitoring` for Alloy.
- `dashboard` for Kubernetes Dashboard.

It also deletes incorrectly placed default-namespace leftovers that could hold
ingress hosts or service names.

## Public Hostnames

When `NIPIO=1` and `INGRESS_PUBLIC_IP` is available, the script patches these
ingresses:

| Service | Host |
| --- | --- |
| App | `crementation.<ip>.nip.io` |
| Grafana | `grafana.<ip>.nip.io` |
| Dashboard | `dashboard.<ip>.nip.io` |
| ArgoCD | `argocd.<ip>.nip.io` |
| Dex | `dex.<ip>.nip.io` |

It also creates `kube-system/nip-io-ingress-ip` so the
`nip-io-reconciler` CronJob can re-apply the same public host convention if a
later GitOps or manual apply drifts back to the checked-in `.local` hosts.

## Expected Checks

After the script finishes, run:

```sh
kubectl get pods -A
kubectl get externalsecrets -A
kubectl -n argocd get applications
kubectl -n crementation get pods,svc,ingress,hpa
```

For browser checks, use the URLs printed by the script. Certificates can need a
short delay while cert-manager completes HTTP-01 challenges.

## Re-Running The Script

The script is designed for repeated lab use:

- Existing Vault initialization is reused through `~/vault-init.txt`.
- Helm installs are done with `helm upgrade --install`.
- Namespaces are created with `--dry-run=client -o yaml | kubectl apply`.
- CRD-heavy infrastructure applies are retried.
- Hostname patches are safe to repeat.

Before a re-run, confirm that `~/vault-init.txt` exists if Vault already
contains data. Without the unseal key and root token, Vault cannot be reopened.
