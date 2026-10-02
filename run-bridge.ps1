# run-bridge.ps1 — start the Muse bridge (v5.1) with the right env, forever.
#
# Bind order is handled inside bridge.py: it always listens on 127.0.0.1 and
# ALSO on the Tailscale IPv4 of this machine (from `tailscale ip -4`), so the
# same process serves local clients and the rest of the tailnet.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File run-bridge.ps1

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bridge  = Join-Path $Root 'bridge.py'
$Queue   = Join-Path $Root 'queue'
$Keys    = Join-Path $Root 'keys.json'
$Port    = if ($env:BRIDGE_PORT) { [int]$env:BRIDGE_PORT } else { 8765 }

if (-not (Test-Path $Bridge)) { throw "bridge.py tidak ditemukan di $Root" }

$env:BRIDGE_QUEUE      = $Queue
$env:BRIDGE_KEYS       = $Keys
$env:BRIDGE_LEASE_SECS = if ($env:BRIDGE_LEASE_SECS) { $env:BRIDGE_LEASE_SECS } else { '300' }

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw "python tidak ada di PATH (butuh Python 3.8+)" }

New-Item -ItemType Directory -Force -Path $Queue | Out-Null

# Keep the process alive across crashes even when launched by hand.
while ($true) {
    Write-Host "[run-bridge] starting muse-bridge on port $Port (queue=$Queue)" -ForegroundColor Cyan
    & $python $Bridge serve
    $code = $LASTEXITCODE
    Write-Host "[run-bridge] bridge exited (code=$code); restart in 5s" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
