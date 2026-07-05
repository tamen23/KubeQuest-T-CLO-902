# Documentation Index

This directory collects the operational documentation for the KubeQuest
platform. The root `README.md` keeps the complete deployment reference; these
pages split the same information into focused documents that are easier to use
during review, handover, and defense preparation.

## Start here

- [Project overview](project-overview.md) explains the platform goal, the main
  components, and how traffic, secrets, observability, and GitOps fit together.
- [Repository map](repository-map.md) explains what each top-level directory is
  responsible for and which files are the source of truth.

## Runbooks

- [Fresh cluster runbook](runbooks/fresh-cluster.md) covers the Terraform and
  kubeadm bootstrap path driven by `scripts/cluster-up.sh`.
- [Full deployment runbook](runbooks/full-deploy.md) covers the cluster stack
  deployment driven by `scripts/deploy.sh`.
- [Troubleshooting runbook](runbooks/troubleshooting.md) lists the common
  failure points and the quickest checks.

## Security and operations

- [Security model](security-model.md) documents secrets, identity, policy, and
  the remaining accepted risks.
- [Network policies](network-policies.md) explains the deny-by-default model and
  the intended traffic paths.
- [Policy controls](policy-controls.md) documents Gatekeeper and CI safety
  checks.
- [Observability](observability.md) documents metrics, logs, dashboards, and
  alerting.
- [Resilience](resilience.md) documents scaling, rolling updates, disruption
  handling, and recovery behavior.
- [Backups](backups.md) documents MySQL dumps and Velero cluster backups.

## Defense material

- [Defense day guide](defense-day.md) gives a presentation-oriented sequence
  for the live demo.
- [Demo scenarios](demo-scenarios.md) gives command-level demos for autoscaling,
  failures, rollback, drains, and backup restore.
- [CI/CD](ci-cd.md) explains the GitHub Actions validation and deployment
  workflows.
