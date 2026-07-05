# Policy Controls

The repository uses admission policy and CI checks to prevent common drift and
deployment mistakes. The controls are intentionally scoped to the parts of the
stack this project owns.

## Gatekeeper Image Tag Policy

Gatekeeper is installed from the official Helm chart in
`infrastructure/kustomization.yaml`.

The local policy resources live in `components/gatekeeper/`:

- `constrainttemplate-k8sdisallowlatest.yaml`
- `constraint-k8sdisallowlatest.yaml`

The constraint rejects images tagged as `:latest` for Pods and common workload
controllers in the `crementation` namespace:

- Pods
- Deployments
- StatefulSets
- DaemonSets
- ReplicaSets
- Jobs
- CronJobs

The policy is namespace-scoped because the project controls the app namespace.
It does not try to enforce third-party chart internals across the whole
cluster.

## Image Tag Contract

The app image tag has two source locations that must stay aligned:

- `crementation/values.yaml`
- `.github/workflows/ci.yml`

The CI workflow pushes the app image on `main` using the configured tag and
also pushes `latest`. The cluster should consume the immutable version tag from
`crementation/values.yaml`, not rely on `latest`.

## Kubernetes Manifest Rendering

The CI workflow renders the deployable Kustomize trees:

```sh
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone infrastructure
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone applications/crementation/base
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone applications/mysql
```

This catches many chart, values, and Kustomize integration errors before a
cluster deployment.

## kube-linter

CI runs kube-linter in two modes:

- Infrastructure and MySQL are report-only because they are mostly third-party
  charts.
- The `crementation` chart is blocking because it is authored by the project.

Accepted exclusions live in `.kube-linter.yaml` and are documented as lab
trade-offs:

- `host-network`
- `host-port`
- `run-as-non-root`
- `no-read-only-root-fs`
- `non-existent-service-account`

Do not add exclusions casually. If a new exclusion is needed, document the
reason near the config and in the security documentation.

## Helm Lint

CI runs:

```sh
helm lint crementation/
```

This validates the app chart itself. It complements the Kustomize render,
because Helm lint can catch chart-level issues before the rendered YAML is
applied.

## Trivy Image Scan

CI builds the app image from `sample-app-master/Dockerfile` and scans it with
the official Trivy Docker image.

The scan reports critical and high vulnerabilities. It is report-only because
the app is based on the provided sample and some fixes would require a larger
Laravel upgrade outside the project scope. The visibility is still useful for
review and defense discussion.

## NetworkPolicy Coverage Check

The `network-policy-check` job verifies that:

- each expected namespace has a policy file in
  `infrastructure/network-policies/`;
- `infrastructure/kustomization.yaml` still references `network-policies`.

This protects against accidentally committing the temporary bootstrap state
where NetworkPolicies are commented out.

## Deploy Workflow Guardrails

`.github/workflows/deploy.yml` is manual by design. It requires a kubeconfig
secret and deployment secrets in GitHub Actions, then:

1. configures cluster access;
2. creates namespaces;
3. installs and unseals Vault;
4. configures Vault auth and policies;
5. seeds Vault;
6. installs ArgoCD;
7. applies the ArgoCD Application manifests.

The workflow does not store generated app secrets in the repository. Generated
values are masked in logs and pushed into Vault.

## Review Checklist

Before merging a change that affects deployment behavior, check:

- Does the relevant Kustomize tree still render?
- Does `helm lint crementation/` still pass?
- Is the app image tag consistent between CI and Helm values?
- Did any new namespace get a NetworkPolicy file?
- Did any new runtime secret get an ExternalSecret mapping?
- Does the change need a note in the runbook or defense docs?
