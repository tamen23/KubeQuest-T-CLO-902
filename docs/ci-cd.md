# CI/CD

The repository has two GitHub Actions workflows:

- `.github/workflows/ci.yml`
- `.github/workflows/deploy.yml`

The CI workflow validates source changes and publishes the app image on `main`.
The deploy workflow is manual and bootstraps the cluster-side GitOps handoff.

## CI Triggers

`ci.yml` runs on:

- pushes to `main`;
- pushes to `develop`;
- pull requests targeting `main`;
- pull requests targeting `develop`.

Feature branches are expected to be validated through pull requests rather than
duplicating direct-push runs.

## Job: Build App Image And Scan

Job name:

```text
build-and-scan-image
```

What it does:

1. Checks out the repository.
2. Builds the app image from `sample-app-master/Dockerfile`.
3. Loads the image locally as `crementation-app:ci`.
4. Pulls the official Trivy image.
5. Runs a SARIF scan for critical and high vulnerabilities.
6. Uploads SARIF results when GitHub code scanning is available.
7. Prints a human-readable Trivy summary.

The scan is report-only. This keeps visibility on vulnerabilities without
blocking the course-provided sample app on issues that need a larger framework
upgrade.

## Job: Lint Kubernetes Manifests And Helm Charts

Job name:

```text
lint-manifests
```

What it does:

1. Installs Kustomize.
2. Installs Helm.
3. Renders `infrastructure/`.
4. Renders `applications/crementation/base/`.
5. Renders `applications/mysql/`.
6. Installs kube-linter.
7. Runs kube-linter report-only on infrastructure and MySQL renders.
8. Runs kube-linter blocking on the app render.
9. Runs `helm lint crementation/`.

This job is important because the repository relies heavily on Helm chart
inflation through Kustomize. Rendering the trees in CI catches chart or values
breakage before a live cluster sees it.

## Job: NetworkPolicy Coverage

Job name:

```text
network-policy-check
```

What it does:

1. Confirms expected namespaces have a file in
   `infrastructure/network-policies/`.
2. Confirms each file targets the expected namespace.
3. Confirms `infrastructure/kustomization.yaml` still references
   `network-policies`.

This prevents the bootstrap workaround of temporarily disabling policies from
being committed.

## Job: Push App Image

Job name:

```text
push-app-image
```

This job runs only on push events to `main`, after validation jobs succeed.

It builds and pushes:

```text
maxi2/crementation-app:v1.1.1
maxi2/crementation-app:latest
```

The version tag must stay in sync with `crementation/values.yaml`.

Required GitHub secrets:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

## Manual Deploy Workflow

Workflow:

```text
Deploy (seed Vault + hand off to ArgoCD)
```

Trigger:

```text
workflow_dispatch
```

Inputs:

- optional ingress node name;
- optional monitoring node name.

Required GitHub secrets:

- `KUBECONFIG_B64`
- `GH_CLIENT_ID`
- `GH_CLIENT_SECRET`
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

If reusing an already initialized Vault, the workflow also expects:

- `VAULT_UNSEAL_KEY`
- `VAULT_ROOT_TOKEN`

## Deploy Workflow Sequence

The deploy workflow:

1. Installs kubectl, Helm, and Kustomize.
2. Writes kubeconfig from `KUBECONFIG_B64`.
3. Creates required namespaces.
4. Optionally labels ingress and monitoring nodes.
5. Installs, initializes, and unseals Vault.
6. Configures Vault KV, policy, and Kubernetes auth.
7. Seeds all runtime secrets into Vault.
8. Installs ArgoCD.
9. Applies `infrastructure/argocd/argocd-apps.yaml`.

After this, ArgoCD owns reconciliation from `main`.

## ArgoCD Applications

The deploy workflow applies Applications for:

| Application | Path |
| --- | --- |
| `infrastructure` | `infrastructure/` |
| `mysql` | `applications/mysql/` |
| `crementation` | `applications/crementation/overlays/prod/` |
| `mysql-backups` | `backups/mysql/` |

All target `main`, use automated sync, prune removed resources, and self-heal
drift.

## Operational Notes

- The deploy workflow is manual because a fresh kubeadm cluster must exist
  first.
- CI publishes the app image only after the validation jobs pass on `main`.
- ArgoCD can briefly show failed syncs on a fresh cluster while CRDs and
  webhooks settle.
- The app can briefly restart while waiting for MySQL and Vault-backed secrets.
- The first app deployment can hit `ImagePullBackOff` until the versioned image
  tag has been pushed.

## Review Checklist

Before relying on CI/CD for a demo:

```sh
git status --short --branch
kubectl -n argocd get applications
kubectl get externalsecrets -A
kubectl -n crementation get deploy crementation -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Check that the image tag shown by Kubernetes matches the tag pushed by the CI
workflow and the tag declared in `crementation/values.yaml`.
