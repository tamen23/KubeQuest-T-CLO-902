# Demo Scenarios

This page collects short, presentation-ready demos. Pick only the scenarios
that fit the available time.

## Hostname Note

Some scripts use `Host: crementation.local` internally because the checked-in
Ingress starts with `.local` hosts. If the deployment has been patched to
nip.io hosts, prefer direct commands against:

```text
https://crementation.<ingress-ip>.nip.io
```

or adjust the Host header manually for the demo command you run.

## Autoscaling Demo

Goal: show HPA scaling app replicas under load.

Watch:

```sh
kubectl -n crementation get hpa crementation --watch
kubectl -n crementation get pods --watch
```

If using `.local` host routing, run:

```sh
./scripts/load-test.sh <ingress-ip-or-hostname> 180s 50
```

If using nip.io directly:

```sh
hey -z 180s -c 50 https://crementation.<ingress-ip>.nip.io/
```

Explain:

- metrics-server feeds the HPA;
- the app scales from 2 replicas toward 5;
- pod anti-affinity spreads replicas when nodes allow it;
- Grafana and Prometheus pick up the new pods automatically.

## CPU Pressure Demo

Goal: create deterministic CPU pressure through the debug endpoint.

Prerequisite: set `DEBUG_ENDPOINTS_ENABLED=true` in `crementation/values.yaml`
and re-apply the app.

For `.local` script path:

```sh
./scripts/failure-demo.sh <ingress-ip-or-hostname> cpu 60
```

For nip.io direct path:

```sh
curl -sk https://crementation.<ingress-ip>.nip.io/api/debug/burn-cpu?seconds=60
```

Watch:

```sh
kubectl -n crementation top pods
kubectl -n crementation describe hpa crementation
```

Reset the debug flag to `false` after the demo.

## Memory/OOM Demo

Goal: show resource limits and OOMKilled behavior.

Prerequisite: debug endpoints enabled.

For `.local` script path:

```sh
./scripts/failure-demo.sh <ingress-ip-or-hostname> memory 80
```

For nip.io direct path:

```sh
for i in $(seq 1 80); do
  curl -sk "https://crementation.<ingress-ip>.nip.io/api/debug/leak-memory?mb=10"
  sleep 1
done
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

For `.local` script path:

```sh
./scripts/failure-demo.sh <ingress-ip-or-hostname> crash
```

For nip.io direct path:

```sh
curl -sk -o /dev/null -w '%{http_code}\n' \
  https://crementation.<ingress-ip>.nip.io/api/debug/crash
```

Open Grafana and show:

- log stream filtered by app pod;
- error-level logs;
- dashboard refresh after the request.

## Zero-Downtime Rollout Demo

Goal: show that rolling updates do not drop requests.

Terminal 1:

```sh
./scripts/zero-downtime-test.sh <ingress-ip-or-hostname> 60
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

If using nip.io and the script Host header no longer matches the live ingress,
use a simple loop instead:

```sh
for i in $(seq 1 120); do
  curl -sk -o /dev/null -w "%{http_code}\n" https://crementation.<ingress-ip>.nip.io/
  sleep 0.5
done
```

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
./scripts/zero-downtime-test.sh <ingress-ip-or-hostname> 90
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
