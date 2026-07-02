<?php

use App\Http\Controllers\CounterController;
use App\Http\Controllers\DebugController;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| API Routes
|--------------------------------------------------------------------------
|
| Here is where you can register API routes for your application. These
| routes are loaded by the RouteServiceProvider within a group which
| is assigned the "api" middleware group. Enjoy building your API!
|
*/


$router->get('counter/add', [CounterController::class, 'add']);
$router->get('counter/count', [CounterController::class, 'get']);

// Deliberate failure-injection endpoints for the defense demo (see the
// README's "Debug endpoints" section and app/Http/Controllers/DebugController.php).
// Off by default — only registered when DEBUG_ENDPOINTS_ENABLED=true is set,
// which crementation/values.yaml does NOT set for normal deployments.
if (env('DEBUG_ENDPOINTS_ENABLED', false)) {
    $router->get('debug/burn-cpu', [DebugController::class, 'burnCpu']);
    $router->get('debug/leak-memory', [DebugController::class, 'leakMemory']);
    $router->get('debug/crash', [DebugController::class, 'crash']);
}
