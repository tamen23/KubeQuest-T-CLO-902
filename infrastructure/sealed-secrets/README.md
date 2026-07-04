# Sealed Secrets — a second secrets pattern

This stack's primary secrets flow is **Vault + External Secrets Operator**
(secrets live in Vault, ESO syncs them into Kubernetes Secrets at runtime).
Sealed Secrets is added here as a *complementary, git-native* pattern to show
a different, equally valid approach:

- **Vault/ESO:** secret values never touch git; they live in Vault and are
  pulled in-cluster. Good when you already run a secrets manager.
- **Sealed Secrets:** the *encrypted* secret is committed to git as a
  `SealedSecret` CRD. The `sealed-secrets-controller` holds a private key that
  never leaves the cluster and decrypts it into a normal `Secret`. Good for
  pure-GitOps setups with no external secret store.

## Generating a SealedSecret

The controller must be running first (it's installed with the rest of
`infrastructure/`). Then, with the `kubeseal` CLI:

```sh
# 1. make a normal Secret locally (do NOT commit this one)
kubectl create secret generic demo-app-secret \
  --namespace crementation \
  --from-literal=API_TOKEN='super-secret-value' \
  --dry-run=client -o yaml > /tmp/demo-secret.yaml

# 2. seal it against the cluster's public cert (safe to commit the output)
kubeseal --controller-name sealed-secrets --controller-namespace kube-system \
  --format yaml < /tmp/demo-secret.yaml > infrastructure/sealed-secrets/example-sealedsecret.yaml

rm /tmp/demo-secret.yaml   # the plaintext Secret never goes to git
```

The resulting `example-sealedsecret.yaml` (a `SealedSecret`) is committed and
applied like any other manifest; the controller turns it back into the
`demo-app-secret` Secret inside `crementation`. Only this cluster's controller
can decrypt it — the ciphertext is useless to anyone else, so it's safe in a
public repo.

`example-sealedsecret.yaml` in this directory is a **template placeholder**
with a non-decryptable `encryptedData` value — replace it with real output
from the command above once the controller is up (its `encryptedData` is
cluster-specific).
