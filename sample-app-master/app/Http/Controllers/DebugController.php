<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

/**
 * Deliberate failure-injection endpoints for the KubeQuest defense demo (see
 * the README's "Defense day runbook" section and the brief's own suggestion
 * to "enrich the applications code with some memory leaks, loops consuming
 * CPU, or anything that could lead to errors and container failure").
 *
 * These routes only exist when DEBUG_ENDPOINTS_ENABLED=true (see routes/api.php)
 * — never enabled by default, and crementation/values.yaml does not set it.
 */
class DebugController extends Controller
{
    /**
     * Busy-loops one PHP-FPM/Apache worker at 100% CPU for the given number
     * of seconds (default 30, capped at 120). With enough concurrent requests
     * this drives the pod's CPU usage past the HPA's targetCPUUtilizationPercentage
     * (crementation/values.yaml, currently 70%), triggering a live scale-up —
     * see the README's autoscaling demo script.
     */
    public function burnCpu(Request $request)
    {
        $seconds = min((int) $request->query('seconds', 30), 120);
        $end = microtime(true) + $seconds;
        $iterations = 0;
        while (microtime(true) < $end) {
            $iterations++;
            sqrt($iterations); // cheap, deliberately pointless work to keep the CPU busy
        }
        return response()->json([
            'burned_seconds' => $seconds,
            'iterations' => $iterations,
        ], 200);
    }

    /**
     * Allocates roughly 10MB per call and never releases it for the lifetime
     * of the PHP worker process, simulating a real memory leak. Repeated
     * calls eventually push the container past resources.limits.memory
     * (crementation/values.yaml, currently 512Mi) and get OOMKilled by the
     * kubelet — demonstrates Kubernetes' resource enforcement live.
     */
    protected static array $leakedMemory = [];

    public function leakMemory(Request $request)
    {
        $chunkSizeMb = min((int) $request->query('mb', 10), 50);
        self::$leakedMemory[] = str_repeat('x', $chunkSizeMb * 1024 * 1024);

        return response()->json([
            'leaked_chunks' => count(self::$leakedMemory),
            'approx_total_mb' => count(self::$leakedMemory) * $chunkSizeMb,
            'php_memory_usage_mb' => round(memory_get_usage(true) / 1024 / 1024, 1),
        ], 200);
    }

    /**
     * Immediately fatals the request — for demonstrating a liveness-probe
     * failure / crash loop distinct from the CPU/memory exhaustion above.
     * Does NOT crash the whole container/process, just this one request;
     * combine with a bad image tag or `kubectl exec ... kill 1` for a true
     * container-level crash during the defense's rollback demo.
     */
    public function crash(Request $request)
    {
        abort(500, 'Deliberate crash via /debug/crash for defense demo purposes');
    }
}
