# Grafana dashboards

## Crementation - Logs (`infrastructure/monitoring/dashboards/crementation-logs.json`)

Pre-built dashboard for the "filtre log monitoring" bonus — rather than
clicking through Grafana's Explore view live during the demo, this is a
rehearsed, saved view with:

- **Log volume by level** — a time series broken down by `level_name`
  (ERROR/WARNING/INFO/DEBUG/CRITICAL), so a spike in errors is visible at a
  glance without reading raw lines.
- **Filtered log stream** — the actual `logs` panel, with a `$level`
  dropdown (defaults to "all") and a `$pod` multi-select, both backed by
  Grafana template variables. Changing either re-runs the LogQL query live.
- **Error rate** — a raw substring match (`error|exception|fatal|500`,
  case-insensitive) independent of JSON parsing, as a fallback signal that
  still works even for log lines that never got JSON-formatted.

### Why this needed an app-config change, not just a dashboard

Two things had to be true before any of this could work, and neither was
true before this pass:

1. **Logs have to reach Loki at all.** Alloy (the log shipper — see
   `infrastructure/monitoring/loki/values-alloy.yaml`) tails container
   stdout/stderr. Laravel's default log channel (`sample-app-master/config/logging.php`,
   `'default' => env('LOG_CHANNEL', 'stack')` → `single` driver) writes
   plain-text lines to a file *inside the container*
   (`storage/logs/laravel.log`), which Alloy never sees. Fixed by setting
   `LOG_CHANNEL=stderr` in `crementation/values.yaml`.
2. **Logs have to be structured for `level_name` filtering to work.**
   Plain-text log lines have no `level_name` field for LogQL's `| json`
   parser to extract — the "Log volume by level" and "$level" filter panels
   would show everything as `unparsed`. Fixed by also setting
   `LOG_STDERR_FORMATTER=Monolog\Formatter\JsonFormatter`, Monolog's built-in
   JSON formatter (no custom code needed) — Laravel already depends on
   Monolog, this only changes which formatter it hands the stderr handler.

Both are plain environment variables, not app code changes — see the
`LOG_CHANNEL`/`LOG_STDERR_FORMATTER` entries in `crementation/values.yaml`'s
`env` block.

### How it gets into Grafana

`infrastructure/monitoring/dashboards/kustomization.yaml` wraps the dashboard
JSON in a ConfigMap labeled `grafana_dashboard: "1"`. kube-prometheus-stack's
Grafana subchart runs a sidecar (chart default: `sidecar.dashboards.enabled:
true`, watching for that exact label) that auto-imports any matching
ConfigMap in any namespace — no manual "import dashboard" click required
after `kustomize build --enable-helm infrastructure | kubectl apply -f -`
picks up `monitoring/dashboards/`.

### Demoing it

1. Log into Grafana (`https://grafana.local`, behind oauth2-proxy/Dex).
2. Open **Crementation - Logs**.
3. Trigger some real errors — e.g. `./scripts/failure-demo.sh <ip> crash` a
   few times (see `docs/deployment/defense.md`) — and watch the error-rate
   panel spike and new lines appear in the filtered stream within ~10s
   (dashboard `refresh: 10s`).
4. Switch the `$level` dropdown to `ERROR` live, to show the filter actually
   narrowing the stream rather than just being decorative.
