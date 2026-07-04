<?php

use App\Http\Controllers\MetricsController;
use App\Models\Counter;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Web Routes
|--------------------------------------------------------------------------
|
| Here is where you can register web routes for your application. These
| routes are loaded by the RouteServiceProvider within a group which
| contains the "web" middleware group. Now create something great!
|
*/

Route::get('/', function () {
    $value = Counter::sum('count');
    return view('welcome', ['value' => $value]);
});

// Prometheus scrape endpoint for the app's own business metrics (scraped by
// crementation/templates/servicemonitor.yaml). Root-level, unauthenticated —
// standard for a /metrics endpoint on an internal ClusterIP service.
Route::get('/metrics', [MetricsController::class, 'metrics']);
