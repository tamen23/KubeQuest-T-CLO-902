# Demo Scenarios

This page collects short, presentation-ready demos. Pick only the scenarios
that fit the available time.

## Hostname Note

Every service is reachable at `https://<name>.<ingress-ip>.nip.io` — nip.io is
free public wildcard DNS, so this resolves with **zero client setup** (no
`/etc/hosts` entry needed) from any machine, including the examiners'. Certs
are real, browser-trusted Let's Encrypt (not self-signed) since nip.io is a
real public domain. A CronJob (`nip-io-reconciler`, in `kube-system`, checks
every 3 minutes) keeps this wired up automatically even if a manifest re-apply
ever reverts an ingress back to its committed `.local` default — nothing to
patch by hand.

All the demo scripts below (`load-test.sh`, `failure-demo.sh`,
`zero-downtime-test.sh`) take the hostname as a plain argument, e.g.:

```text
crementation.<ingress-ip>.nip.io
```

Get `<ingress-ip>` from `terraform output ingress_public_ip` or
`scripts/cluster-up.sh`'s final output.

## Autoscaling Demo

Goal: show HPA scaling app replicas under load.

Watch:

```sh
kubectl -n crementation get hpa crementation --watch
kubectl -n crementation get pods --watch
```

```sh
./scripts/load-test.sh crementation.<ingress-ip>.nip.io 180 50
```

(No `hey`/`ab`/`wrk` to install — the script is plain bash + curl, and drives
`/api/debug/burn-cpu` directly rather than hammering `/`, since the counter
page is too cheap to reliably push real CPU past the HPA's 70% threshold.
Requires `DEBUG_ENDPOINTS_ENABLED=true` — see the CPU Pressure Demo below.)

Explain:

- metrics-server feeds the HPA;
- the app scales from 2 replicas toward 5;
- pod anti-affinity spreads replicas when nodes allow it;
- Grafana and Prometheus pick up the new pods automatically.

## CPU Pressure Demo

Goal: create deterministic CPU pressure through the debug endpoint.

Prerequisite: enable the debug endpoints on the live deployment (don't commit
this — it's a runtime flip, not a values.yaml change, so a normal deploy never
ships with it on):

```sh
kubectl -n crementation set env deploy/crementation DEBUG_ENDPOINTS_ENABLED=true
```

```sh
./scripts/failure-demo.sh crementation.<ingress-ip>.nip.io cpu 60
```

Watch:

```sh
kubectl -n crementation top pods
kubectl -n crementation describe hpa crementation
```

Reset the flag after the demo:
`kubectl -n crementation set env deploy/crementation DEBUG_ENDPOINTS_ENABLED=false`

## Memory/OOM Demo

Goal: show resource limits and OOMKilled behavior.

Prerequisite: debug endpoints enabled (see above).

```sh
./scripts/failure-demo.sh crementation.<ingress-ip>.nip.io memory 80
```

Watch:

```sh
kubectl -n crementation get pods --watch
kubectl -n crementation describe pod <pod>
```

Explain:

- memory limit is configured in the Helm values;
- Kubernetes restarts the container after OOMKilled;
- Prometheus alert `KubeQuestContainerOOMKilled` covers this event.

## Crash/Error Logs Demo

Goal: show application errors in Grafana logs.

Prerequisite: debug endpoints enabled.

```sh
./scripts/failure-demo.sh crementation.<ingress-ip>.nip.io crash
```

Open Grafana (`https://grafana.<ingress-ip>.nip.io`) and show:

- log stream filtered by app pod;
- error-level logs;
- dashboard refresh after the request.

## Zero-Downtime Rollout Demo

Goal: show that rolling updates do not drop requests.

Terminal 1:

```sh
./scripts/zero-downtime-test.sh crementation.<ingress-ip>.nip.io 60
```

Terminal 2:

```sh
kubectl -n crementation rollout restart deploy/crementation
kubectl -n crementation rollout status deploy/crementation
```

Explain:

- `maxUnavailable: 0`;
- `maxSurge: 1`;
- readiness probe gates traffic;
- `minReadySeconds` avoids instantly accepting a barely-ready pod.

## Rollback Demo

Goal: show recovery from a broken Deployment.

Example:

```sh
helm upgrade crementation ./crementation -n crementation --reuse-values \
  --set image.tag=<known-broken-tag>

kubectl -n crementation rollout status deploy/crementation
kubectl -n crementation describe pod <failing-pod>

kubectl -n crementation rollout undo deploy/crementation
kubectl -n crementation rollout status deploy/crementation
```

Use this only if you have a known bad tag and enough time to recover cleanly.

## Node Drain Demo

Goal: show PDB protection during voluntary disruption.

Terminal 1:

```sh
./scripts/zero-downtime-test.sh crementation.<ingress-ip>.nip.io 90
```

Terminal 2:

```sh
./scripts/drain-demo.sh
```

After the demo:

```sh
kubectl uncordon <node>
```

Explain:

- the PDB keeps at least one app pod available;
- Kubernetes reschedules the evicted pod;
- the test loop proves the user path stays reachable.

## MySQL Backup Demo

Goal: show app-level backup.

```sh
kubectl -n crementation get cronjob mysql-backup
kubectl -n crementation create job --from=cronjob/mysql-backup mysql-backup-manual-test
kubectl -n crementation logs job/mysql-backup-manual-test
```

Explain:

- credentials come from Vault through ESO;
- dump files are written to `mysql-backup-pvc`;
- old dump files are pruned after seven days.

## Velero Backup/Restore Demo

Goal: show cluster-level backup.

```sh
velero backup create demo --include-namespaces crementation --wait
velero backup get
```

Optional restore demo:

```sh
kubectl delete ns crementation
velero restore create --from-backup demo --wait
kubectl -n crementation get pods,svc,ingress,pvc
```

Only run the destructive delete/restore if the demo environment is ready for it
and you have enough time.
