# Velero — cluster backup & restore

Complements the app-level MySQL dump (`backups/mysql/`) with **whole-cluster**
backups: all Kubernetes resources (and EBS volumes via the AWS plugin) into an
S3 bucket, restorable onto a fresh cluster.

See `values.yaml` for the S3 bucket / AWS-credential prerequisites — those are
environment-specific and must be set up before Velero installs.

## Common operations (Velero CLI)

```sh
# on-demand backup of everything
velero backup create full-$(date +%F) --wait

# backup just the app + its data
velero backup create app-$(date +%F) --include-namespaces crementation --wait

# list backups / schedules
velero backup get
velero schedule get   # the daily-full schedule from values.yaml shows here

# restore onto THIS cluster (e.g. after an accidental delete)
velero restore create --from-backup full-2026-07-03 --wait

# restore onto a FRESH cluster (the defense "restore to new cluster" story):
#   1. install Velero on the new cluster pointing at the SAME S3 bucket
#   2. velero backup get          # it sees the existing backups in the bucket
#   3. velero restore create --from-backup full-2026-07-03 --wait
```

## Demo idea

`velero backup create demo --include-namespaces crementation --wait`, then
`kubectl delete ns crementation`, then
`velero restore create --from-backup demo --wait` — the whole app namespace
comes back. Pairs well with the drain/rollback demos.
