# ArgoCD (GitOps auto-sync)

Per the brief's bonus list ("argoCD to manage your components and GitOps
repositories"). Turns the manual `kustomize build --enable-helm <path> |
kubectl apply -f -` workflow in `docs/deployment/deployment.md` into: push to
`main`, cluster updates itself within ~3 minutes (default sync interval).

## What ArgoCD manages

Four `Application` resources (`infrastructure/argocd/argocd-apps.yaml`), each
watching one path in this repo and auto-syncing (`prune: true`, `selfHeal:
true` — drift and manual `kubectl edit` both get reverted automatically):

| Application | Watches | Deploys |
|---|---|---|
| `infrastructure` | `infrastructure/` | cert-manager, ingress-nginx, dashboard, kube-prometheus-stack, Loki+Alloy, Vault, ESO, Dex, oauth2-proxy, Gatekeeper, NetworkPolicies |
| `mysql` | `applications/mysql/` | the official Bitnami MySQL chart |
| `crementation` | `applications/crementation/overlays/prod/` | the app |
| `mysql-backups` | `backups/mysql/` | the backup CronJob + PVC |

## Bootstrap (chicken-and-egg problem)

ArgoCD can't GitOps-manage its own installation before it exists. Install it
once, manually, the same way as everything else:

```sh
kustomize build --enable-helm infrastructure | kubectl apply -f -
# ^ this is the SAME command as deployment.md step 3 — ArgoCD is just
# another helmChart entry in infrastructure/kustomization.yaml, installed
# alongside everything else on that first manual pass.

kubectl apply -f infrastructure/argocd/argocd-apps.yaml
```

From this point on, further changes to `infrastructure/`,
`applications/mysql/`, `applications/crementation/`, or `backups/mysql/` in
git are picked up automatically. You should NOT need to run `kubectl
apply`/`kustomize build` by hand for those paths again — if you find yourself
doing so, something's wrong with a sync, check `kubectl -n argocd get
applications` first.

## The NetworkPolicy ordering hazard, under ArgoCD

`docs/deployment/deployment.md` step 3 has you comment out the
`network-policies` line during first bootstrap because applying deny-by-
default policies before any pod exists strands the bootstrap itself. That
manual workaround **does not apply once ArgoCD owns the sync** — the
`infrastructure` Application syncs everything in `infrastructure/
kustomization.yaml` (NetworkPolicies included) as one unit, in the same
initial sync that creates the pods those policies gate.

In practice this has worked fine in testing patterns like this because
Kubernetes NetworkPolicy enforcement is asynchronous relative to object
creation — the CNI (Calico, on this cluster) needs a moment to program the
policy after the object is created, by which point the target pods usually
already exist too. But this is exactly the kind of race that's fine 95% of
the time and flaky on defense day. If the very first ArgoCD sync of
`infrastructure` leaves anything stuck (check `kubectl -n argocd get
application infrastructure -o jsonpath='{.status.health}'`), the fix is:

1. `kubectl -n argocd patch application infrastructure --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'` (pause auto-sync)
2. Manually delete the `network-policies` resources that landed too early
3. Let the rest settle, confirm everything's `Running`
4. Re-apply NetworkPolicies (`kubectl apply -k infrastructure/network-policies`)
5. Re-enable auto-sync (re-apply `infrastructure/argocd/argocd-apps.yaml`)

This is a one-time bootstrap concern — after the first successful sync,
`selfHeal` keeps NetworkPolicies present continuously without re-triggering
the race (they're not being created fresh anymore, just reconciled).

## Reverting to manual kubectl/kustomize (defense day fallback)

Everything ArgoCD does is expressible as the plain `kubectl`/`kustomize`/
`helm` commands in `docs/deployment/deployment.md` — that doc was written
first and still works standalone. If ArgoCD itself is broken or you want to
demonstrate the underlying mechanism without the extra layer, pause
auto-sync (`kubectl -n argocd get applications -o name | xargs -I{} kubectl
-n argocd patch {} --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`)
and fall back to deployment.md's manual steps — nothing about the manifests
themselves depends on ArgoCD being present.
