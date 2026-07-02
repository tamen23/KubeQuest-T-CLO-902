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
2→5 replicas at 70% CPU. Generate load against the ingress endpoint:

```sh
kubectl -n crementation get hpa crementation --watch &

# from a separate machine or pod, sustained load:
kubectl run load-generator --rm -it --image=williamyeh/hey --restart=Never -- \
  hey -z 3m -c 50 http://<ingress-node-public-ip>/ -host crementation.local
```

Narrate what's on screen: CPU climbing in Grafana (crementation namespace
dashboard), `HorizontalPodAutoscaler` events firing (`kubectl -n crementation
describe hpa crementation`), new pods scheduling onto whichever node has
room (pod anti-affinity spreads them — point this out), and Prometheus/Loki
picking up the new pods automatically via ServiceMonitor/Alloy discovery with
no manual config.

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

Optional stretch, per the brief's suggestion to "enrich the application code
with some memory leaks, loops consuming CPU, or anything that could lead to
errors": if `sample-app-master` gets a `/debug/leak` or `/debug/burn` route
added for this purpose, trigger it here instead of a bad image tag, and show
the resource limits (`crementation/values.yaml` → `resources.limits`) killing
the container via OOMKill/CPU throttling rather than taking the node down.

## Known fragile points to check the morning of

- Vault starts **sealed** after the nightly VM shutdown script runs — unseal
  it first (see `docs/deployment/deployment.md` step 2) or every ExternalSecret
  in the cluster will be stuck on stale/no data.
- The MySQL replication secondaries take longer to become `Ready` than the
  primary; don't deploy the app before `kubectl -n crementation get pods -l
  app.kubernetes.io/component=secondary` shows both `Running`.
- Confirm `crementation.local` / `dashboard.local` resolve on the presentation
  machine (via `/etc/hosts` pointed at the ingress node's IP) before going live.
