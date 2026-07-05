# Troubleshooting Runbook

This runbook lists common failure points for the KubeQuest platform and the
fast checks to run before changing manifests.

## First Checks

Start with the cluster shape:

```sh
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -80
```

Then check the GitOps and secret layers:

```sh
kubectl -n argocd get applications
kubectl get externalsecrets -A
kubectl -n vault exec vault-0 -- vault status
```

Most deployment issues are caused by Vault being sealed, a CRD/webhook not
ready yet, MySQL still starting, or NetworkPolicies being applied before the
dependent pods have settled.

## Vault Is Sealed

Symptoms:

- ExternalSecrets stay `SecretSynced=False`.
- App pods are missing `laravel-db`.
- MySQL pods are missing expected credentials.
- Dex or oauth2-proxy cannot start.

Check:

```sh
kubectl -n vault exec vault-0 -- vault status
kubectl get externalsecrets -A
```

Fix:

```sh
kubectl -n vault exec vault-0 -- vault operator unseal <unseal-key>
```

When using `scripts/deploy.sh`, the unseal key and root token are stored in
`~/vault-init.txt` on `kube-1`. Keep that file private and never commit it.

## External Secrets Cannot Read Vault

Symptoms:

- ExternalSecret resources exist but generated Kubernetes Secrets are missing.
- ESO logs show Vault 403 or authentication errors.

Check:

```sh
kubectl -n external-secrets-system logs deploy/external-secrets --tail=100
kubectl get clustersecretstore
kubectl get externalsecrets -A
```

Likely causes:

- Vault is sealed.
- Vault Kubernetes auth role is missing or has the wrong policy field.
- NetworkPolicy blocks traffic from `external-secrets-system` to `vault`.
- The referenced Vault path was not seeded.

## MySQL Is Not Ready

Symptoms:

- App logs show database connection errors.
- Laravel migrations retry repeatedly.
- App readiness is unstable after deployment.

Check:

```sh
kubectl -n crementation get pods -l app.kubernetes.io/name=mysql
kubectl -n crementation logs statefulset/mysql-primary --tail=100
kubectl -n crementation get secret mysql-secret laravel-db
```

Wait for the primary and replicas to become ready before judging the app. The
app starts Apache quickly and runs migrations in the background with retries,
so early database errors can converge without code changes.

## App Image Cannot Be Pulled

Symptoms:

- `ImagePullBackOff` on `deploy/crementation`.
- Events mention Docker Hub authentication or missing tag.

Check:

```sh
kubectl -n crementation describe pod <app-pod>
kubectl -n crementation get secret dockerhub-secret
```

Likely causes:

- The Docker Hub token was not seeded into Vault.
- ESO has not created `dockerhub-secret`.
- `crementation/values.yaml` image tag is newer than the image pushed by CI.

The image tag must stay aligned with `.github/workflows/ci.yml` and
`crementation/values.yaml`.

## Ingress Returns 404 Or Wrong Service

Symptoms:

- Public host reaches ingress-nginx but returns 404.
- Dex or dashboard route lands in the wrong namespace.
- Browser URL does not match the certificate host.

Check:

```sh
kubectl get ingress -A
kubectl -n ingress-nginx logs ds/ingress-nginx-controller --tail=100
kubectl -n ingress-nginx rollout restart ds/ingress-nginx-controller
```

For Dex, Alloy, and Dashboard, remember that `scripts/deploy.sh` has a special
namespace-fix phase. If those were applied manually through Kustomize only,
some objects can land in `default`.

## Certificates Are Pending

Symptoms:

- Browser still shows a certificate warning.
- cert-manager challenges remain pending.
- Ingress has a nip.io host but the old TLS secret.

Check:

```sh
kubectl get certificates -A
kubectl get challenges -A
kubectl -n cert-manager logs deploy/cert-manager --tail=100
```

Likely causes:

- DNS or port 80 cannot reach the ingress node.
- The ingress host and TLS host do not match.
- The old certificate secret needs to be recreated after host patching.

The deploy script deletes the old certificate and secret when it patches the
host so cert-manager can issue a new Let's Encrypt certificate.

## NetworkPolicies Break Traffic

Symptoms:

- Pods are running but cannot reach each other.
- Vault, ESO, auth, or app traffic fails after policies are applied.
- No Kubernetes object shows an obvious error.

Check:

```sh
kubectl get networkpolicy -A
kubectl -n crementation logs deploy/crementation --tail=50
kubectl -n external-secrets-system logs deploy/external-secrets --tail=50
```

The platform expects deny-by-default policies to be applied last. If a fresh
cluster got policies too early, remove the affected policies, let the workloads
settle, then re-apply `infrastructure/network-policies/`.

## ArgoCD Sync Is Stuck

Symptoms:

- ArgoCD Application is `OutOfSync` or `Degraded`.
- Resources fail because a CRD does not exist yet.
- NetworkPolicy landed before the workloads it protects.

Check:

```sh
kubectl -n argocd get applications
kubectl -n argocd describe application infrastructure
```

Fresh installs can need one manual nudge after CRDs and webhooks exist. If
NetworkPolicies are the blocker, pause automated sync, remove the early policy
objects, let pods settle, then re-enable sync by re-applying
`infrastructure/argocd/argocd-apps.yaml`.

## HPA Does Not Scale

Symptoms:

- `kubectl describe hpa` shows unknown metrics.
- Load test does not change replica count.

Check:

```sh
kubectl top nodes
kubectl top pods -n crementation
kubectl -n kube-system get deploy metrics-server
kubectl -n crementation describe hpa crementation
```

The HPA depends on metrics-server, not Prometheus. If `kubectl top` fails,
debug metrics-server first.

## Logs Missing From Grafana

Symptoms:

- Grafana dashboard exists but the app log panels are empty.
- Loki has cluster logs but not app JSON fields.

Check:

```sh
kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy
kubectl -n crementation logs deploy/crementation --tail=20
```

The app chart sets `LOG_CHANNEL=stderr` and
`LOG_STDERR_FORMATTER=Monolog\\Formatter\\JsonFormatter`. If those are changed,
Alloy may not see the logs or LogQL JSON parsing may stop working.

## Safe Rule

When a live object looks wrong, check the source file before editing the
cluster:

- App behavior: `crementation/values.yaml` and `crementation/templates/`.
- Platform behavior: `infrastructure/`.
- GitOps behavior: `infrastructure/argocd/argocd-apps.yaml`.
- Secrets behavior: Vault seed commands and ExternalSecret manifests.

If a live patch is needed for a demo, port it back into the source of truth
afterward.
