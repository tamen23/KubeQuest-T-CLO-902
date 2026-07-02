# CI/CD

`.github/workflows/ci.yml` runs on every push to `main`, `develop`, and any
`kubequest-*` branch, plus every PR into `main`/`develop`. Three parallel jobs:

## 1. `build-and-scan-image` — image build + CVE scan

Builds the `crementation` app image from `sample-app-master/Dockerfile`
(without pushing it anywhere — this is a scan-only build, not a release
pipeline), then scans it with [Trivy](https://trivy.dev/) for CRITICAL/HIGH
CVEs.

Findings are uploaded as SARIF to the repo's **Security** tab (Code scanning
alerts) so they're visible without digging through job logs, and also printed
as a human-readable table in the job output.

The scan does **not** currently fail the build (`exit-code: "0"`) — the base
image (`php:8.2-apache`) will always carry some upstream CVEs that aren't
ours to fix on our own schedule, and a hard-failing pipeline on those would
just get bypassed/ignored. The intent is visibility first; tightening this to
fail on new/fixable CVEs is a reasonable next step once there's a baseline to
compare against.

## 2. `lint-manifests` — Kustomize/Helm static analysis

Renders every Kustomize tree this repo actually deploys
(`infrastructure/`, `applications/crementation/base/`, `applications/mysql/`)
using `kustomize build --enable-helm`, then runs:

- **kube-linter** against the rendered output, using `.kube-linter.yaml` at
  the repo root. Three checks are explicitly excluded there
  (`host-network`, `host-port`, `run-as-non-root`) — each is a documented,
  accepted trade-off explained in `docs/SECURITY-REVIEW.md`, not an oversight.
- **`helm lint`** against the `crementation/` chart source directly (catches
  template/schema issues kube-linter wouldn't, since it only sees rendered
  output).

Like the image scan, this currently reports rather than blocks (`|| true`).
See `docs/SECURITY-REVIEW.md` for the full manual findings this pipeline is
meant to keep enforced over time.

## 3. `network-policy-check` — NetworkPolicy coverage guard

A repo-structure check, not a cluster check: confirms every namespace that's
supposed to have a deny-by-default NetworkPolicy
(`infrastructure/network-policies/*.yaml`) still has its file, still targets
the right namespace, and that `infrastructure/kustomization.yaml` hasn't
dropped the `network-policies` line. This exists specifically because
`docs/deployment/deployment.md` step 3 tells operators to *temporarily*
comment that line out on their local working copy during initial bootstrap —
this job is the safety net making sure that comment-out never accidentally
gets committed.

## What's not automated (yet)

- **No CD / auto-deploy step.** This pipeline validates; it doesn't apply
  anything to a live cluster. See the ArgoCD setup
  (`infrastructure/argocd/`, `docs/ARGOCD.md`) for the GitOps auto-sync layer
  that would consume a merge to `main` as a deploy trigger.
- **No image push/registry step.** The Docker Hub image
  (`maxi2/crementation-app`) referenced in `crementation/values.yaml` is
  built and pushed manually today; wiring `docker/build-push-action` to
  actually push on a tag/release would close that gap.
- **Network *runtime* scanning** (e.g. actually testing NetworkPolicy
  enforcement against a live cluster with a tool like `cyclonus` or
  `netassert`) is not done here — `network-policy-check` only validates the
  repo declares the right policies, not that a running cluster enforces them
  correctly. Worth adding if there's time before defense day.
