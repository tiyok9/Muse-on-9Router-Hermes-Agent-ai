# setup-bridge.ps1 — one-shot Tailscale-aware setup for the Muse bridge.
#
# What it does
#   1. checks python + tailscale, reports the Tailscale IPv4 / MagicDNS name
#   2. creates the queue dir and generates the user + worker keys (once)
#   3. writes worker.env (chmod-equivalent: hidden + ACL-locked where possible)
#   4. runs a real end-to-end round-trip test through the bridge
#   5. prints the exact values to paste into 9Router + Hermes
#
# It never prints full keys to the console. They live in keys.json only.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File setup-bridge.ps1

$ErrorActionPreference = 'Stop'

$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bridge = Join-Path $Root 'bridge.py'
$Queue  = Join-Path $Root 'queue'
$Keys   = Join-Path $Root 'keys.json'
$EnvOut = Join-Path $Root 'worker.env'

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($t)      { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Warn($t)    { Write-Host "  [warn] $t" -ForegroundColor Yellow }
function Die($t)     { Write-Host "  [fail] $t" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- checks ---
Section 'Pemeriksaan prasyarat'

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { Die 'python tidak ada di PATH (butuh Python 3.8+, stdlib saja)' }
# NB: PowerShell 5.1 mangles embedded double quotes in native args, so all
# python snippets below are piped in via stdin (`python -`) instead of -c.
$pyver = (@'
import sys
print("%d.%d.%d" % sys.version_info[:3])
'@ | & $python -).Trim()
Ok "python $pyver -> $python"

if (-not (Test-Path $Bridge)) { Die "bridge.py tidak ditemukan di $Root" }
Ok "bridge.py ditemukan"

$ts = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
if (-not $ts) {
    foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe",
                     "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
        if (Test-Path $p) { $ts = $p; break }
    }
}
if (-not $ts) {
    Warn 'tailscale CLI tidak ditemukan — bridge tetap jalan di 127.0.0.1 saja'
    $tsIp = $null; $tsName = $null
} else {
    Ok "tailscale -> $ts"
    $tsIp = (& $ts ip -4 2>$null | Select-Object -First 1)
    $tsIp = if ($tsIp) { $tsIp.Trim() } else { $null }
    $tsStatus = & $ts status --json 2>$null
    if ($tsStatus) {
        try { $tsName = ($tsStatus | ConvertFrom-Json).Self.DNSName -replace '\.$','' } catch {}
    }
    if ($tsIp) { Ok "tailnet IPv4: $tsIp" } else { Warn 'tailscale belum login / tidak ada IPv4' }
    if ($tsName) { Ok "MagicDNS: $tsName" }
}

# ------------------------------------------------------------ queue+keys ---
Section 'Queue + API key'

New-Item -ItemType Directory -Force -Path $Queue | Out-Null
Ok "queue -> $Queue"

$env:BRIDGE_QUEUE = $Queue
$env:BRIDGE_KEYS  = $Keys

function KeyExists($label) {
    if (-not (Test-Path $Keys)) { return $false }
    try { return (Get-Content $Keys -Raw | ConvertFrom-Json).keys.label -contains $label }
    catch { return $false }
}

if (-not (KeyExists '9router')) {
    & $python $Bridge keygen --role user --label 9router 2>&1 | Out-Null
    Ok 'user key dibuat (label=9router)'
} else { Ok 'user key sudah ada (label=9router)' }

if (-not (KeyExists 'muse-worker')) {
    & $python $Bridge keygen --role worker --label muse-worker 2>&1 | Out-Null
    Ok 'worker key dibuat (label=muse-worker)'
} else { Ok 'worker key sudah ada (label=muse-worker)' }

# lock the key file down to the current user only
try {
    $acl = Get-Acl $Keys
    $acl.SetAccessRuleProtection($true, $false)
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $me, 'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -Path $Keys -AclObject $acl
    Ok "keys.json ACL dikunci ke $me"
} catch { Warn "tidak bisa mengunci ACL keys.json: $_" }

# ambil key untuk dipakai script (tidak pernah dicetak ke layar)
$userKey   = (& $python -c "import json;print([k['key'] for k in json.load(open(r'$Keys'))['keys'] if k['label']=='9router'][0])").Trim()
$workerKey = (& $python -c "import json;print([k['key'] for k in json.load(open(r'$Keys'))['keys'] if k['label']=='muse-worker'][0])").Trim()

# ------------------------------------------------------------ worker.env ---
Section 'worker.env'

$bridgeHost = if ($tsIp) { $tsIp } else { '127.0.0.1' }
$envText = @"
# worker.env — dibaca oleh run-worker.ps1. JANGAN commit file ini.
# Bridge di mesin ini sendiri, dijangkau lewat IP tailnet supaya klien
# lain di tailnet juga bisa memakai URL yang sama.
BRIDGE_URL=http://${bridgeHost}:8765
BRIDGE_WORKER_KEY=$workerKey
WORKER_LABEL=muse-worker

# Upstream: siapa yang menyusun jawaban.
#   none            -> echo placeholder (uji konektivitas saja)
#   hermes          -> jalankan Hermes CLI lokal
#   http://host/v1  -> endpoint OpenAI-compatible lain (JANGAN bridge ini sendiri)
UPSTREAM=none
# UPSTREAM_KEY=
# UPSTREAM_MODEL=muse

POLL_INTERVAL=3
REQUEST_TIMEOUT=120
"@
Set-Content -Path $EnvOut -Value $envText -Encoding UTF8
Ok "worker.env ditulis -> $EnvOut"

# ------------------------------------------------------------ round-trip ---
Section 'Uji end-to-end (user -> queue -> worker -> answer -> user)'

$srv = Start-Process -FilePath $python -ArgumentList @($Bridge, 'serve') `
       -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

try {
    $health = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 `
               "http://127.0.0.1:8765/health").Content
    if ($health -match '"ok"') { Ok "GET /health -> $health" } else { Die "health aneh: $health" }

    $hdrU = @{ Authorization = "Bearer $userKey" }
    $hdrW = @{ Authorization = "Bearer $workerKey" }

    $models = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 `
               -Headers $hdrU "http://127.0.0.1:8765/v1/models").Content
    Ok "GET /v1/models -> $models"

    # user request in the background (long-polls up to 240s)
    $body = @{ model = 'muse'; messages = @(@{ role = 'user'; content = 'ping setup' }) } |
            ConvertTo-Json -Depth 6 -Compress
    $client = Start-Job -ScriptBlock {
        param($u, $b)
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Method POST `
          -Uri 'http://127.0.0.1:8765/v1/chat/completions' `
          -Headers @{ Authorization = "Bearer $u" } `
          -ContentType 'application/json' -Body $b | Select-Object -Expand Content
    } -ArgumentList $userKey, $body

    Start-Sleep -Seconds 2
    $claimed = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Headers $hdrW `
                'http://127.0.0.1:8765/muse/pending?limit=1').Content | ConvertFrom-Json
    if (-not $claimed.jobs.Count) { Die 'worker tidak menerima job (queue kosong?)' }
    $jid = $claimed.jobs[0].id
    Ok "worker claim job $jid"

    $ans = @{ id = $jid; content = 'pong dari setup-bridge' } |
           ConvertTo-Json -Compress
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Headers $hdrW -Method POST `
      -Uri 'http://127.0.0.1:8765/muse/answer' `
      -ContentType 'application/json' -Body $ans | Out-Null
    Ok 'worker kirim jawaban'

    $reply = Receive-Job $client -Wait -AutoRemoveJob
    if ($reply -match 'pong dari setup-bridge') { Ok "jawaban kembali ke klien: OK" }
    else { Die "jawaban tidak kembali: $reply" }
}
finally {
    if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force }
    Remove-Job -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- next step ---
Section 'Nilai untuk disalin (key TIDAK ditampilkan di sini)'

$base = "http://${bridgeHost}:8765"
Write-Host "  Bridge base URL   : $base"
Write-Host "  OpenAI path       : $base/v1"
Write-Host "  Health            : $base/health"
Write-Host "  User key (9Router): ada di $Keys  (label=9router)"
Write-Host "  Worker key        : sudah ditanam di worker.env"
Write-Host ''
Write-Host '  Langkah berikutnya:' -ForegroundColor Cyan
Write-Host "    1) jalankan bridge :  .\run-bridge.ps1"
Write-Host "    2) jalankan worker :  .\run-worker.ps1"
Write-Host "    3) 9Router  -> provider openai-compatible, base $base/v1, key = user key"
Write-Host "    4) Hermes   -> base_url $base/v1, model default = muse"
if ($tsName) {
    Write-Host "    5) dari mesin lain di tailnet: $base (atau http://${tsName}:8765)"
}
