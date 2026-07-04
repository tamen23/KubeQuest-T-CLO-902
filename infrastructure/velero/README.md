# Velero — cluster backup & restore

Complements the app-level MySQL dump (`backups/mysql/`) with **whole-cluster**
backups: all Kubernetes resources (and EBS volumes via the AWS plugin) into an
S3 bucket, restorable onto a fresh cluster.

The S3 bucket (`kubequest-velero-092040680793`, eu-west-3) already exists —
created for this project with public access blocked. The only remaining
prerequisite is the AWS credentials Secret; create it before Velero installs:

```sh
cat > credentials-velero <<EOF
[default]
aws_access_key_id=<YOUR_KEY>
aws_secret_access_key=<YOUR_SECRET>
EOF
kubectl create secret generic velero-aws-creds -n velero --from-file=cloud=./credentials-velero
rm credentials-velero   # never commit this file
```

(This project reuses the `terraform-admin` keys for simplicity. Best practice
would be a dedicated least-privilege IAM user scoped to just this bucket +
EBS snapshots — swap those keys in if you tighten it later.)

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
