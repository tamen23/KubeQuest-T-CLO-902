# Network Policies

The repository implements a deny-by-default NetworkPolicy model for the main
application and platform namespaces. The policies live in
`infrastructure/network-policies/` and are included from
`infrastructure/kustomization.yaml`.

## Covered Namespaces

CI checks that policy files exist for:

- `crementation`
- `monitoring`
- `auth`
- `vault`
- `external-secrets-system`
- `ingress-nginx`
- `dashboard`
- `argocd`

Each file starts with a namespace-wide default deny, then adds allow rules for
the traffic the namespace needs.

## Bootstrap Ordering

NetworkPolicies are intentionally applied at the end of the deployment.

A fresh install needs several components to come up and talk to one another
before the full allow-list is useful:

- cert-manager CRDs and webhooks.
- External Secrets Operator.
- Vault.
- Dex and oauth2-proxy.
- Prometheus Operator.
- ArgoCD.
- MySQL and the application.

Applying policies too early can create a working-looking cluster where pods are
running but unable to initialize or reconcile.

## Shared DNS Rule

Namespaces need DNS egress to `kube-system` so pods can resolve Kubernetes
Services. The policy files include explicit UDP and TCP port 53 egress where
needed.

If service names stop resolving after policies are applied, confirm the DNS
egress rule exists in the namespace of the failing pod.

## Crementation Namespace

`infrastructure/network-policies/crementation.yaml` allows:

- ingress-nginx traffic to the app on port 80.
- app pods to reach MySQL on port 3306.
- the MySQL backup CronJob to reach MySQL on port 3306.
- Prometheus scraping from the `monitoring` namespace.
- DNS egress to `kube-system`.

The ingress rule has a special `ipBlock` for the Terraform public subnet. This
is necessary because ingress-nginx runs with `hostNetwork: true`; traffic to
the app can arrive with the node IP rather than a pod IP from the
`ingress-nginx` namespace.

## Auth Namespace

`infrastructure/network-policies/auth.yaml` allows:

- ingress-nginx to reach oauth2-proxy on port 4180.
- oauth2-proxy to reach Dex on port 5556.
- Dex to reach GitHub over HTTPS for OAuth.
- Prometheus scraping from the `monitoring` namespace.
- DNS egress to `kube-system`.

Dex egress to GitHub is represented as external HTTPS egress with in-cluster
ranges excluded. NetworkPolicy cannot target public services by hostname.

## Vault And External Secrets

The Vault and External Secrets policies are paired:

- External Secrets Operator must reach Vault on port 8200.
- ESO also needs DNS and Kubernetes API access for reconciliation.
- Vault should not be broadly reachable by other namespaces.

When ExternalSecrets stop syncing after policies land, inspect both sides:

```sh
kubectl -n external-secrets-system logs deploy/external-secrets --tail=100
kubectl -n vault exec vault-0 -- vault status
kubectl get networkpolicy -n vault
kubectl get networkpolicy -n external-secrets-system
```

## Monitoring Namespace

The monitoring namespace needs to:

- Receive ingress traffic for Grafana.
- Scrape metrics from app and platform targets.
- Receive log traffic shipped by Alloy.
- Access the Kubernetes API where operators or kube-rbac-proxy need it.

Prometheus scrape access is usually expressed as ingress allow rules in the
target namespaces, not only as monitoring egress.

## Dashboard And ArgoCD

Dashboard and ArgoCD are not intended to be public unauthenticated services.
Their ingresses are protected by oauth2-proxy through ingress-nginx auth
annotations. NetworkPolicies limit the in-cluster paths to the service traffic
they need.

If the browser is redirected to SSO correctly but the final service is not
reachable, check both the service namespace policy and the `auth` namespace
policy.

## CI Coverage Check

The `network-policy-check` job in `.github/workflows/ci.yml` verifies two
things:

1. A policy file exists for each expected namespace.
2. `infrastructure/kustomization.yaml` still references `network-policies`.

This prevents the bootstrap workaround of temporarily commenting out
`network-policies` from being committed accidentally.

## Debug Commands

Useful inspection commands:

```sh
kubectl get networkpolicy -A
kubectl describe networkpolicy -n crementation allow-ingress-to-app
kubectl describe networkpolicy -n auth allow-oauth2-proxy-to-dex
kubectl get pods -A -o wide
```

For policy-related failures, use application logs, ESO logs, ingress-nginx logs,
and events together. NetworkPolicy failures often appear as timeouts rather
than clear Kubernetes errors.
