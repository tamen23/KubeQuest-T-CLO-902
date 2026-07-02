# Defense day runbook

Per the project brief, the defense has four parts. This doc is the script for
each — rehearse it end-to-end at least once before the real thing, timings
included.

## 1. Fresh cluster, before presenting

Spin up a new cluster (more nodes than the 4-VM dev environment, to show this
isn't hardcoded to 2 workers) ahead of time, not live:

```sh
# on each new node
kubeadm init / kubeadm join ...   # or your chosen bootstrap method
kubectl label node <ingress-node> node-role.kubernetes.io/ingress=ingress
kubectl label node <monitoring-node> node-role.kubernetes.io/monitoring=monitoring
```

Confirm `kubectl get nodes` shows all nodes `Ready` before moving on.

## 2. Live deploy, using only kubectl / kustomize / helm

Follow `docs/deployment/deployment.md` steps 1–6 live, narrating each command
as you run it. Nothing here should require editing YAML on the fly — if it
does, that's a sign a manifest was left machine-specific and needs fixing
before defense day, not during it.

## 3. Autoscaling demo

The crementation app's HPA (`crementation/values.yaml` → `autoscaling`) scales
2→5 replicas at 70% CPU. Generate load against the ingress endpoint with the
reusable script (`scripts/load-test.sh`, requires
[`hey`](https://github.com/rakyll/hey) on the machine you run it from):

```sh
kubectl -n crementation get hpa crementation --watch &

./scripts/load-test.sh <ingress-node-public-ip> 3m 50
```

Narrate what's on screen: CPU climbing in Grafana (crementation namespace
dashboard — also demonstrates the "filtre log monitoring" bonus if you flip
to the Loki panel mid-load, see `docs/GRAFANA-DASHBOARDS.md`),
`HorizontalPodAutoscaler` events firing (`kubectl -n crementation describe
hpa crementation`), new pods scheduling onto whichever node has room (pod
anti-affinity spreads them — point this out), and Prometheus/Loki picking up
the new pods automatically via ServiceMonitor/Alloy discovery with no manual
config.

For a sharper, more deterministic version of this same demo, use the
CPU-burn debug endpoint instead of generic HTTP load (see
`sample-app-master/app/Http/Controllers/DebugController.php` — requires
flipping `DEBUG_ENDPOINTS_ENABLED` to `true` in `crementation/values.yaml`
first, see `scripts/failure-demo.sh`'s header comment):

```sh
./scripts/failure-demo.sh <ingress-node-public-ip> cpu 60
```

## 4. Broken deployment + automatic rollback

Ship a deliberately broken image tag and show Kubernetes catching it:

```sh
# crementation/values.yaml already has a comment marking where to bump this;
# for the demo, point the tag at a build that fails its liveness probe
# (e.g. a version with a startup crash-loop or an endpoint returning 500 on /)
helm upgrade crementation ./crementation -n crementation --reuse-values \
  --set image.tag=<known-broken-tag>

kubectl -n crementation rollout status deploy/crementation
# ^ this will hang/fail once the new pods fail readiness — that's the point

kubectl -n crementation get pods
kubectl -n crementation describe pod <failing-pod>   # show the failed probe / crash reason

kubectl -n crementation rollout undo deploy/crementation
kubectl -n crementation rollout status deploy/crementation
# back to the last good revision
```

Per the brief's suggestion to "enrich the application code with some memory
leaks, loops consuming CPU, or anything that could lead to errors": the
memory-leak endpoint (`sample-app-master/app/Http/Controllers/DebugController.php`)
is the sharper version of this demo, since it shows a real OOMKill instead of
just a failed readiness probe. Flip `DEBUG_ENDPOINTS_ENABLED` to `true` in
`crementation/values.yaml` first (see `scripts/failure-demo.sh`'s header),
apply, then:

```sh
./scripts/failure-demo.sh <ingress-node-public-ip> memory 80

kubectl -n crementation get pods --watch
# watch for RESTARTS incrementing and a pod transitioning through
# OOMKilled -> CrashLoopBackOff as it repeatedly hits
# resources.limits.memory (crementation/values.yaml, default 512Mi)

kubectl -n crementation describe pod <the-oomkilled-pod>
# Last State: Terminated, Reason: OOMKilled — this is Kubernetes enforcing
# the resource limit, not the app crashing on its own
```

Remember to flip `DEBUG_ENDPOINTS_ENABLED` back to `false` and re-apply once
the demo is done — these routes should never stay live.

## Known fragile points to check the morning of

- Vault starts **sealed** after the nightly VM shutdown script runs — unseal
  it first (see `docs/deployment/deployment.md` step 2) or every ExternalSecret
  in the cluster will be stuck on stale/no data.
- The MySQL replication secondaries take longer to become `Ready` than the
  primary; don't deploy the app before `kubectl -n crementation get pods -l
  app.kubernetes.io/component=secondary` shows both `Running`.
- Confirm `crementation.local` / `dashboard.local` resolve on the presentation
  machine (via `/etc/hosts` pointed at the ingress node's IP) before going live.
