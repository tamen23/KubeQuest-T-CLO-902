# Resilience

The platform includes several resilience mechanisms for the app and supporting
services. Most of the app-level behavior is configured in `crementation/values.yaml`.

## Rolling Updates

The app Deployment uses a rolling update strategy designed for zero-downtime
updates:

```yaml
maxUnavailable: 0
maxSurge: 1
minReadySeconds: 5
```

This means Kubernetes should not remove an old ready pod until a new pod is
ready and has remained available for a short period.

The app also has readiness and liveness probes on `/`, so traffic is only sent
to pods that can answer HTTP.

## Zero-Downtime Validation

The repository includes `scripts/zero-downtime-test.sh`. It sends repeated
requests to the app while a rollout runs in another terminal.

Example:

```sh
./scripts/zero-downtime-test.sh <ingress-ip-or-hostname> 60
kubectl -n crementation rollout restart deploy/crementation
```

Expected result: successful HTTP 200 responses and zero failed requests.

## Horizontal Scaling

The app chart enables an HPA:

- minimum replicas: 2
- maximum replicas: 5
- target CPU utilization: 70 percent

The HPA depends on metrics-server. If scaling does not work, check
`kubectl top pods` before debugging Prometheus.

Useful commands:

```sh
kubectl -n crementation get hpa crementation
kubectl -n crementation describe hpa crementation
kubectl top pods -n crementation
```

Load test:

```sh
./scripts/load-test.sh <ingress-ip-or-hostname> 180s 50
```

## Vertical Sizing Recommendations

The repository also installs Vertical Pod Autoscaler and creates a VPA resource
for the app in `infrastructure/vpa/crementation-vpa.yaml`.

The VPA is intentionally recommendation-only:

```yaml
updateMode: "Off"
```

It observes CPU and memory usage and publishes recommendations, but it does not
evict or resize pods automatically. This avoids conflict with the HPA, which
already owns replica scaling based on CPU.

Check recommendations:

```sh
kubectl -n crementation describe vpa crementation
```

## Pod Disruption Budget

The app chart renders a PDB with `minAvailable: 1`. During voluntary
disruptions such as node drains, Kubernetes should keep at least one app pod
available.

The PDB sets `unhealthyPodEvictionPolicy: AlwaysAllow` so an already-unhealthy
pod does not block maintenance forever.

Check:

```sh
kubectl -n crementation get pdb
```

## Node Drain Demo

`scripts/drain-demo.sh` finds a node running an app pod, drains it, and shows
that the app pods are rescheduled while the PDB protects availability.

Run:

```sh
./scripts/drain-demo.sh
```

After the demo, uncordon the node printed by the script:

```sh
kubectl uncordon <node>
```

For a stronger proof, run `scripts/zero-downtime-test.sh` in another terminal
while the drain is happening.

## Pod Placement

The app has pod anti-affinity configured in `crementation/values.yaml`. With
two replicas, Kubernetes tries to avoid putting both app pods on the same node.

Check placement:

```sh
kubectl -n crementation get pods -l app.kubernetes.io/name=crementation -o wide
```

## Failure Injection

The sample app includes guarded debug endpoints. They are disabled by default:

```text
DEBUG_ENDPOINTS_ENABLED=false
```

For demos only, set the flag to `true`, re-apply the app chart, and use:

```sh
./scripts/failure-demo.sh <ingress-ip-or-hostname> cpu 60
./scripts/failure-demo.sh <ingress-ip-or-hostname> memory 80
./scripts/failure-demo.sh <ingress-ip-or-hostname> crash
```

Use the memory path to demonstrate OOMKilled behavior, and use the CPU path to
create sharper autoscaling pressure.

After the demo, set `DEBUG_ENDPOINTS_ENABLED` back to `false` in the source
values and re-apply.

## Rollback

Kubernetes Deployment history supports rollback after a broken rollout:

```sh
kubectl -n crementation rollout history deploy/crementation
kubectl -n crementation rollout undo deploy/crementation
kubectl -n crementation rollout status deploy/crementation
```

The defense guide uses this to show a failed deployment and recovery to the
last known good ReplicaSet.
