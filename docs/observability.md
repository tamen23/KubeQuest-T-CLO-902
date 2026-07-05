# Observability

The observability stack is deployed from `infrastructure/monitoring/` and is
part of the platform layer rendered by `infrastructure/kustomization.yaml`.

## Components

The stack includes:

- kube-prometheus-stack for Prometheus, Grafana, Alertmanager, exporters, and
  CRDs such as ServiceMonitor and PrometheusRule.
- Loki for log storage.
- Alloy as a DaemonSet log shipper.
- Custom Grafana dashboards committed as JSON.
- Custom Prometheus alert rules.

Grafana is exposed through ingress and protected by the Dex/oauth2-proxy SSO
path.

## Metrics Flow

Metrics enter Prometheus through several paths:

- kube-prometheus-stack's default Kubernetes and node exporters.
- The app ServiceMonitor rendered by `crementation/templates/servicemonitor.yaml`.
- PrometheusRule resources in `infrastructure/monitoring/prometheus/`.

The app ServiceMonitor scrapes:

```text
http://crementation.<namespace>.svc:<http-port>/metrics
```

The ServiceMonitor has the `release: prometheus` label so it is selected by the
kube-prometheus-stack Prometheus instance.

## Application Metrics

The Laravel app exposes business or application metrics through the
`MetricsController` in `sample-app-master/app/Http/Controllers/`.

The image tag in `crementation/values.yaml` must point to an image that
contains that endpoint. The CI `push-app-image` job publishes the tag consumed
by the cluster.

Useful checks:

```sh
kubectl -n crementation get servicemonitor
kubectl -n monitoring get prometheusrule
kubectl -n crementation logs deploy/crementation --tail=50
```

## Logs Flow

Alloy is deployed as a DaemonSet from
`infrastructure/monitoring/loki/values-alloy.yaml`. It discovers pods through
the Kubernetes API, relabels namespace, pod, and container metadata, then ships
logs to Loki:

```text
http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
```

The app chart sets:

```text
LOG_CHANNEL=stderr
LOG_STDERR_FORMATTER=Monolog\\Formatter\\JsonFormatter
```

This matters because Alloy tails stdout and stderr. If Laravel writes only to a
file inside the container, Loki will not see those logs. JSON formatting also
allows LogQL filters to parse fields such as log level.

## Dashboards

Dashboard JSON files live in `infrastructure/monitoring/dashboards/` and are
wrapped into a ConfigMap by Kustomize.

The ConfigMap is labeled for Grafana's dashboard sidecar, so the dashboards are
imported automatically. No manual Grafana import is required.

The app log dashboard is useful for demos:

- filter by log level;
- inspect live app logs;
- show error-rate movement after running failure scenarios.

## Alerts

Custom alert rules live in
`infrastructure/monitoring/prometheus/alert-rules.yaml`.

Current project-specific alerts include:

| Alert | Meaning |
| --- | --- |
| `KubeQuestPodCrashLooping` | App namespace pods are restarting repeatedly. |
| `KubeQuestAppDown` | The app deployment has zero available replicas. |
| `KubeQuestHPAMaxedOut` | The HPA has reached max replicas for several minutes. |
| `KubeQuestContainerOOMKilled` | A crementation container hit its memory limit. |
| `KubeQuestPVCAlmostFull` | A persistent volume is over 85 percent used. |

The PrometheusRule uses `release: prometheus` so the operator selects it.

## Useful Commands

```sh
kubectl -n monitoring get pods
kubectl -n monitoring get servicemonitors,prometheusrules
kubectl -n monitoring get configmap -l grafana_dashboard=1
kubectl -n monitoring logs ds/alloy --tail=100
kubectl -n monitoring logs statefulset/loki --tail=100
```

For app-specific checks:

```sh
kubectl -n crementation get pods,svc,ingress,hpa,servicemonitor
kubectl -n crementation logs deploy/crementation --tail=100
```

## Demo Hooks

The observability stack supports the defense demos:

- `scripts/load-test.sh` generates app load for HPA and dashboard visibility.
- `scripts/failure-demo.sh cpu` creates CPU pressure.
- `scripts/failure-demo.sh memory` can trigger OOMKills.
- `scripts/failure-demo.sh crash` creates app errors visible in logs.

Remember that debug endpoints require `DEBUG_ENDPOINTS_ENABLED=true` on the app
Deployment. The default is `false`.
