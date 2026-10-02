# run-worker.ps1 — start the Muse bridge worker (loop + instant wake-up).
#
# Reads worker.env (same folder) so secrets stay out of the command line,
# then polls the bridge and answers jobs. WATCH_DIR points at <queue>\pending
# so a new job wakes the worker immediately instead of waiting for the poll.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File run-worker.ps1

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Worker   = Join-Path $Root 'bridge-worker.py'
$EnvFile  = Join-Path $Root 'worker.env'
$WatchDir = Join-Path $Root 'queue\pending'

if (-not (Test-Path $Worker))  { throw "bridge-worker.py tidak ditemukan di $Root" }
if (-not (Test-Path $EnvFile)) {
    throw "worker.env tidak ditemukan. Jalankan setup-bridge.ps1 dulu."
}

# load worker.env -> process environment
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $k, $v = $line.Split('=', 2)
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}

if (-not $env:BRIDGE_WORKER_KEY) { throw "BRIDGE_WORKER_KEY kosong di worker.env" }
if (-not $env:WATCH_DIR -and (Test-Path $WatchDir)) { $env:WATCH_DIR = $WatchDir }

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw "python tidak ada di PATH (butuh Python 3.8+)" }

while ($true) {
    Write-Host "[run-worker] worker start (upstream=$env:UPSTREAM)" -ForegroundColor Cyan
    & $python $Worker --loop
    Write-Host "[run-worker] worker exited; restart in 5s" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
