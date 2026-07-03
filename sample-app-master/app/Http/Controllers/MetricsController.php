<?php

namespace App\Http\Controllers;

use App\Models\Counter;

/**
 * Prometheus-format application (business) metrics, exposed at GET /metrics.
 * Hand-rolled text output so the app needs no extra composer dependency and
 * the Docker image is unchanged.
 *
 * Scraped by a ServiceMonitor (crementation/templates/servicemonitor.yaml)
 * and graphed by the "Crementation - App metrics" Grafana dashboard
 * (infrastructure/monitoring/dashboards/crementation-app.json). These are the
 * app's OWN business metrics, distinct from the infra/pod metrics
 * kube-prometheus-stack already collects.
 */
class MetricsController extends Controller
{
    public function metrics()
    {
        $total = (int) Counter::sum('count');
        $rows = (int) Counter::count();

        $lines = [];
        $lines[] = '# HELP crementation_counter_total Sum of all counter increments.';
        $lines[] = '# TYPE crementation_counter_total counter';
        $lines[] = "crementation_counter_total {$total}";

        $lines[] = '# HELP crementation_counter_rows Number of counter rows stored.';
        $lines[] = '# TYPE crementation_counter_rows gauge';
        $lines[] = "crementation_counter_rows {$rows}";

        $lines[] = '# HELP crementation_up Always 1 when the app is serving /metrics.';
        $lines[] = '# TYPE crementation_up gauge';
        $lines[] = 'crementation_up 1';

        return response(implode("\n", $lines) . "\n", 200)
            ->header('Content-Type', 'text/plain; version=0.0.4');
    }
}
