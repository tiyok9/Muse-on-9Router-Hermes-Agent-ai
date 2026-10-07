#!/usr/bin/env bash
# muse-bootstrap.sh — idempotent, self-healing setup for the Muse VM.
#
# The Muse VM is ephemeral: it is swapped or restarted at will, and everything
# inside it (9Router, the bridge, keys, the worker) goes with it. This script is
# the recipe that lives OUTSIDE the VM — in the public repo — so a brand-new VM
# can rebuild the whole stack from one command:
#
#     curl -fsSL <repo-raw>/muse-bootstrap.sh | bash
#
# Safe to re-run. Every step first asks "is this already done?" and skips if so.
# It never regenerates existing keys (that would break 9Router + Hermes configs).
#
# Verified vs assumed: syntax checked with `bash -n`; idempotency logic reasoned
# from the recon in MUSE-SSH-RECON.md. Executed end-to-end on a real Ubuntu
# 24.04 host (systemd) to confirm the happy path and idempotency.
#
# Fetch freshness: raw.githubusercontent.com serves branch URLs through a CDN
# with Cache-Control max-age=300, so a branch URL can hand back a stale copy for
# up to 5 minutes after a push. Resolving the branch to a commit SHA once and
# fetching by SHA sidesteps that (SHA URLs are immutable and not cached that way).
# If the API is unreachable we fall back to the branch URL — a few minutes of
# staleness is harmless for self-heal, whereas a stale *script* overwriting a
# newer one on disk is not, which is why the SHA path is preferred.
#
# Env knobs (all optional):
#   MUSE_REPO_RAW   base raw URL        (default: the public repo, main branch)
#   MUSE_BRIDGE_DIR bridge home         (default: $HOME/muse-bridge)
#   MUSE_PORT_9R    9Router port        (default: 20128)
#   MUSE_PORT_BRG   bridge port         (default: 8765)
#   MUSE_UPSTREAM   worker upstream     (default: none = smoke-test echo)
#   MUSE_RELAY      user@host to reverse-tunnel through (enables the tunnel step)
#   MUSE_RELAY_PORT relay port to publish on              (default: 8765)
#   MUSE_SHELL_ACCESS 1 = also publish this VM's sshd on the relay, so you can
#                   `ssh -p <MUSE_SHELL_PORT> root@<relay>`. Requires
#                   openssh-server installed AND listening on :22 first.
#   MUSE_SHELL_PORT relay port for that shell            (default: 2222)
#   MUSE_SSH_AUTHORIZED_KEYS  public key(s) to allow into this VM's
#                   authorized_keys when MUSE_SHELL_ACCESS=1. One per line.
set -euo pipefail

# systemd units do NOT export HOME (unlike an interactive shell). Under `set -u`
# every "$HOME" reference would abort the whole run — which is exactly how the
# self-heal timer failed every tick. Derive it when it is missing.
if [ -z "${HOME:-}" ]; then
  HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
  [ -n "$HOME" ] || HOME="/root"
  export HOME
fi

# Where the recipe lives. REPO_RAW can be forced; otherwise we resolve the
# branch to a commit SHA at run time (see the freshness note above).
REPO_SLUG="${MUSE_REPO_SLUG:-tiyok9/Muse-on-9Router-Hermes-Agent-ai}"
REPO_BRANCH="${MUSE_REPO_BRANCH:-main}"
REPO_RAW="${MUSE_REPO_RAW:-}"
BRANCH_RAW="https://raw.githubusercontent.com/$REPO_SLUG/$REPO_BRANCH"
BRIDGE_DIR="${MUSE_BRIDGE_DIR:-$HOME/muse-bridge}"
QUEUE_DIR="$BRIDGE_DIR/queue"
KEYS_FILE="$BRIDGE_DIR/keys.json"
ENV_FILE="$BRIDGE_DIR/worker.env"

# ---- persist/restore the stack-shaping knobs -------------------------------
# The self-heal timer (step 8) re-runs THIS script with no human in the loop,
# and a reset of /etc wipes the systemd units that carried these knobs as
# Environment=. Keep them under $HOME (which survives the reset) so a *bare*
# re-run — from the timer, or from a Muse scheduled task — rebuilds the SAME
# stack with zero env vars. Precedence: explicit env var > persisted file >
# built-in default.
CFG_FILE="$BRIDGE_DIR/bootstrap.conf"
if [ -f "$CFG_FILE" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      MUSE_RELAY)        [ -n "${MUSE_RELAY:-}" ]        || MUSE_RELAY="$_v" ;;
      MUSE_RELAY_PORT)   [ -n "${MUSE_RELAY_PORT:-}" ]   || MUSE_RELAY_PORT="$_v" ;;
      MUSE_SHELL_ACCESS) [ -n "${MUSE_SHELL_ACCESS:-}" ] || MUSE_SHELL_ACCESS="$_v" ;;
      MUSE_SHELL_PORT)   [ -n "${MUSE_SHELL_PORT:-}" ]   || MUSE_SHELL_PORT="$_v" ;;
      MUSE_PORT_9R)      [ -n "${MUSE_PORT_9R:-}" ]      || MUSE_PORT_9R="$_v" ;;
      MUSE_PORT_BRG)     [ -n "${MUSE_PORT_BRG:-}" ]     || MUSE_PORT_BRG="$_v" ;;
    esac
  done < "$CFG_FILE"
fi

P9R="${MUSE_PORT_9R:-20128}"
PBRG="${MUSE_PORT_BRG:-8765}"
UPSTREAM="${MUSE_UPSTREAM:-none}"
RELAY="${MUSE_RELAY:-}"
RELAY_PORT="${MUSE_RELAY_PORT:-8765}"
SHELL_ACCESS="${MUSE_SHELL_ACCESS:-0}"
SHELL_PORT="${MUSE_SHELL_PORT:-2222}"

# Remember the resolved knobs for the next (possibly bare) run.
mkdir -p "$BRIDGE_DIR" 2>/dev/null || true
{
  [ -n "$RELAY" ] && printf 'MUSE_RELAY=%s\n' "$RELAY"
  printf 'MUSE_RELAY_PORT=%s\n' "$RELAY_PORT"
  printf 'MUSE_SHELL_ACCESS=%s\n' "$SHELL_ACCESS"
  printf 'MUSE_SHELL_PORT=%s\n' "$SHELL_PORT"
  printf 'MUSE_PORT_9R=%s\n' "$P9R"
  printf 'MUSE_PORT_BRG=%s\n' "$PBRG"
} > "$CFG_FILE" 2>/dev/null && chmod 600 "$CFG_FILE" 2>/dev/null || true
# User keys for the published shell, persisted under $HOME so they survive a
# reset of /etc (the self-heal timer then has nothing to remember: it re-reads
# this file). Without it, a reset would bring the shell back up but refusing
# every key, because the one-shot env var is gone.
AK_FILE="$BRIDGE_DIR/authorized_keys.user"
if [ -z "${MUSE_SSH_AUTHORIZED_KEYS:-}" ] && [ -s "$AK_FILE" ]; then
  MUSE_SSH_AUTHORIZED_KEYS="$(cat "$AK_FILE")"
fi
UNIT_DIR="/etc/systemd/system"
HAVE_SYSTEMD=0
CHANGED=0

# ------------------------------------------------------------- helpers ---
log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[90m•\033[0m %s (sudah ada)\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# root, or sudo available? recon says the VM runs as uid=0.
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else SUDO=""; warn "bukan root dan tanpa sudo — langkah sistem akan dilewati"
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then HAVE_SYSTEMD=1; fi

# Resolve the raw base URL once. Prefer a SHA-pinned URL (immune to the CDN's
# 5-minute branch cache); fall back to the branch URL if the API is unavailable.
# Parsed with python3 (a hard dependency already) rather than sed, because the
# API may return minified JSON where a greedy regex would grab the wrong "sha".
resolve_repo_raw() {
  if [ -n "$REPO_RAW" ]; then return 0; fi
  local sha
  sha="$(python3 - "$REPO_SLUG" "$REPO_BRANCH" <<'PY' 2>/dev/null || true
import json, sys, urllib.request
slug, branch = sys.argv[1], sys.argv[2]
url = f"https://api.github.com/repos/{slug}/commits/{branch}"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                           "User-Agent": "muse-bootstrap"})
with urllib.request.urlopen(req, timeout=15) as r:
    print(json.loads(r.read().decode())["sha"])
PY
)"
  if [ -n "$sha" ]; then
    REPO_RAW="https://raw.githubusercontent.com/$REPO_SLUG/$sha"
    printf '  \033[90m•\033[0m sumber: %s@%s\n' "$REPO_SLUG" "${sha:0:8}"
  else
    REPO_RAW="$BRANCH_RAW"
    printf '  \033[33m!\033[0m API tak terjangkau — pakai URL branch (bisa basi ≤5 menit)\n'
  fi
}

# fetch SRC DST — download only when content actually differs (idempotent).
# Sets FETCH_CHANGED=1 when the destination was actually replaced, so callers
# can restart the service that consumes it (a unit file that didn't change does
# not by itself tell systemd the payload changed).
# api_fetch RAWURL OUT — same bytes via the GitHub contents API (base64).
# Some VMs route egress through a proxy that blocks raw.githubusercontent.com
# while api.github.com still works; this keeps the installer (and its self-heal
# timer) functional there. Returns non-zero when the URL can't be derived/fetched.
api_fetch() {
  local url="$1" out="$2"
  case "$url" in https://raw.githubusercontent.com/*) ;; *) return 1 ;; esac
  # raw.githubusercontent.com/<owner>/<repo>/<ref>/<path...>  (>= 4 segments)
  local rest="${url#https://raw.githubusercontent.com/}"
  case "$rest" in */*/*/*) ;; *) return 1 ;; esac
  local owner="${rest%%/*}"; rest="${rest#*/}"
  local repo="${rest%%/*}";  rest="${rest#*/}"
  local ref="${rest%%/*}";   rest="${rest#*/}"
  local path="$rest"
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$ref" ] && [ -n "$path" ] || return 1
  python3 - "$owner" "$repo" "$ref" "$path" "$out" <<'PY' >/dev/null 2>&1
import base64, json, sys, urllib.request
owner, repo, ref, path, out = sys.argv[1:6]
api = "https://api.github.com/repos/%s/%s/contents/%s?ref=%s" % (owner, repo, path, ref)
req = urllib.request.Request(api, headers={"User-Agent": "muse-bootstrap",
                                           "Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.loads(r.read().decode())
open(out, "wb").write(base64.b64decode(data["content"]))
PY
}

fetch() {
  local src="$1" dst="$2" tmp
  FETCH_CHANGED=0
  tmp="$(mktemp)"
  if ! curl -fsSL --max-time 30 "$src" -o "$tmp"; then
    rm -f "$tmp"; tmp="$(mktemp)"
    if api_fetch "$src" "$tmp"; then
      ok "unduh via API (raw diblokir): $(basename "$dst")"
    else
      rm -f "$tmp"
      # Never let a blocked CDN take down an already-installed stack: reuse the
      # payload already on disk (persisted under $HOME) instead of aborting.
      if [ -f "$dst" ]; then
        warn "raw & API tak terjangkau — pakai salinan lokal $(basename "$dst")"
        return 0
      fi
      die "gagal unduh $src"
    fi
  fi
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; skip "$(basename "$dst") (identik)"
  else
    mkdir -p "$(dirname "$dst")"
    mv "$tmp" "$dst"; chmod +x "$dst"
    ok "$(basename "$dst") diperbarui"; CHANGED=1; FETCH_CHANGED=1
  fi
}

# force_restart NAME — restart even though the unit file is unchanged.
force_restart() {
  [ "$HAVE_SYSTEMD" = 1 ] || return 0
  # never restart the unit we are currently running inside
  if [ "$1" = "muse-bootstrap" ]; then return 0; fi
  $SUDO systemctl restart "$1" >/dev/null 2>&1 || warn "gagal restart $1"
  ok "$1 di-restart (payload berubah)"
}

# write_unit NAME CONTENT — rewrite only when different; restart only when the
# content actually changed or the service is not running.
#
# Why not restart unconditionally: muse-bridge holds client connections open for
# up to WAIT_SECS (240s) while it waits for an answer. A blind restart every time
# the self-heal timer fires would sever those in-flight requests. And the
# muse-bootstrap unit runs *this script*, so restarting it from inside itself
# would kill the run mid-flight.
write_unit() {
  local name="$1" body="$2"
  # Separate statements: `local name="$1" path="$UNIT_DIR/$name.service"` would
  # expand $name while it is still unset, and `set -u` aborts on that.
  local path="$UNIT_DIR/$name.service" tmp changed=0
  [ "$HAVE_SYSTEMD" = 1 ] || return 1
  tmp="$(mktemp)"; printf '%s\n' "$body" > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; skip "unit $name"
  else
    $SUDO install -m 644 "$tmp" "$path"; rm -f "$tmp"
    $SUDO systemctl daemon-reload
    ok "unit $name ditulis"; CHANGED=1; changed=1
  fi
  $SUDO systemctl enable "$name" >/dev/null 2>&1 || true
  # never restart the unit we are currently running inside
  if [ "$name" = "muse-bootstrap" ]; then
    return 0
  fi
  if [ "$changed" = 1 ] || ! $SUDO systemctl is-active --quiet "$name"; then
    $SUDO systemctl restart "$name" >/dev/null 2>&1 || warn "gagal start $name"
  else
    skip "$name sudah jalan"
  fi
}

port_up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
http_ok() { curl -fsS --max-time 5 "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ 0. deps ---
log "0. Cek prasyarat"
command -v python3 >/dev/null 2>&1 && ok "python3 $(python3 -V 2>&1 | awk '{print $2}')" || die "python3 tidak ada"
command -v curl    >/dev/null 2>&1 && ok "curl" || die "curl tidak ada"
command -v ssh     >/dev/null 2>&1 && ok "ssh client" || warn "ssh tidak ada (tunnel dilewati)"
if command -v node >/dev/null 2>&1; then ok "node $(node -v)"; NODE_OK=1; else warn "node tidak ada — 9Router dilewati"; NODE_OK=0; fi

# -------------------------------------------------------- 1. bridge.py ---
log "1. Pasang bridge.py"
resolve_repo_raw
fetch "$REPO_RAW/bridge.py" "$BRIDGE_DIR/bridge.py"
BRIDGE_PAYLOAD_CHANGED="$FETCH_CHANGED"
mkdir -p "$QUEUE_DIR"/{pending,processing,done}
ok "antrean siap: $QUEUE_DIR"

# ------------------------------------------------------------- 2. keys ---
# Idempotent by design: an existing keys.json is never regenerated. If it is
# missing we mint both roles and record the worker key in worker.env.
#
# Optional pinning — set these to reuse the SAME keys across VM swaps, so any
# consumer that lives outside the VM (a local 9Router/Hermes reaching the bridge
# through the tunnel) never needs reconfiguring:
#   MUSE_WORKER_KEY / MUSE_USER_KEY   the full key string
#   MUSE_KEYS_FROM=user@host:/path    pull those two lines over SSH instead
# With a pinned key we simply insert it into keys.json; no keygen, no printing.
log "2. Kunci API"

# Pull pinned keys from a host you own (typically the relay) before generating
# anything. This is what makes a fresh VM truly hands-off: the keys live outside
# the VM, so a swap re-attaches to them and no external config changes.
if [ -n "${MUSE_KEYS_FROM:-}" ] && [ ! -f "$KEYS_FILE" ]; then
  _kh="${MUSE_KEYS_FROM%%:*}"; _kp="${MUSE_KEYS_FROM#*:}"
  printf '  · menarik kunci dari %s…\n' "$_kh"
  if _remote="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                     -o ConnectTimeout=10 "$_kh" "cat '$_kp'" 2>/dev/null)"; then
    MUSE_WORKER_KEY="$(printf '%s\n' "$_remote" | sed -n 's/^BRIDGE_WORKER_KEY=//p')"
    MUSE_USER_KEY="$(printf '%s\n' "$_remote"   | sed -n 's/^BRIDGE_USER_KEY=//p')"
    if [ -n "$MUSE_WORKER_KEY" ] && [ -n "$MUSE_USER_KEY" ]; then
      ok "kunci dipin dari $_kh"
    else
      warn "format kunci di $_kh tidak lengkap — bikin kunci baru saja"
      MUSE_WORKER_KEY=""; MUSE_USER_KEY=""
    fi
  else
    warn "tidak bisa ambil kunci dari $_kh — bikin kunci baru saja"
  fi
fi

need_user=1; need_worker=1
if [ -f "$KEYS_FILE" ]; then
  # `if` rather than `grep -q && var=0`: under `set -e` a non-final failing
  # command inside an && list is a trap waiting to happen.
  if grep -q '"role": *"user"' "$KEYS_FILE"; then need_user=0; fi
  if grep -q '"role": *"worker"' "$KEYS_FILE"; then need_worker=0; fi
  ok "keys.json ada ($(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["keys"]))' "$KEYS_FILE" 2>/dev/null || echo '?') kunci)"
fi

# _insert_key ROLE KEY LABEL — append a caller-supplied key, atomically.
_insert_key() {
  python3 - "$KEYS_FILE" "$1" "$2" "$3" <<'PY'
import json, os, sys, datetime
path, role, key, label = sys.argv[1:5]
try:
    data = json.load(open(path))
except Exception:
    data = {"keys": []}
data.setdefault("keys", []).append({
    "key": key, "role": role, "label": label,
    "created": datetime.datetime.now(datetime.timezone.utc).isoformat()})
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
}

# _keygen ROLE LABEL — mint a key into THIS install's keys.json.
# bridge.py derives keys.json from BRIDGE_QUEUE (whose built-in default is
# /home/ubuntu/muse-bridge), so BRIDGE_QUEUE must be passed explicitly. Without
# it the key is written to that default path while the service reads
# $BRIDGE_DIR/keys.json — the worker then holds a key the bridge has never seen
# and every request 401s. Symptom is silent: both units report "active".
_keygen() {
  ( cd "$BRIDGE_DIR" && BRIDGE_QUEUE="$QUEUE_DIR" \
      python3 bridge.py keygen --role "$1" --label "$2" 2>/dev/null )
}

if [ "$need_worker" = 1 ]; then
  if [ -n "${MUSE_WORKER_KEY:-}" ]; then
    _insert_key worker "$MUSE_WORKER_KEY" muse-vm-pinned
    WKEY="$MUSE_WORKER_KEY"; ok "worker key dipatok (${WKEY:0:14}…)"
  else
    WKEY="$(_keygen worker muse-vm)"
    ok "worker key dibuat (${WKEY:0:14}…)"
  fi
else
  skip "worker key"
  # recover it from an existing worker.env so we never need to print it again
  WKEY="$(grep -E '^BRIDGE_WORKER_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
fi
if [ "$need_user" = 1 ]; then
  if [ -n "${MUSE_USER_KEY:-}" ]; then
    _insert_key user "$MUSE_USER_KEY" 9router-pinned
    ok "user key dipatok (${MUSE_USER_KEY:0:14}…)"
  else
    UKEY="$(_keygen user 9router)"
    ok "user key dibuat (${UKEY:0:14}…)"
  fi
else
  skip "user key"
fi

# ----------------------------------------------------------- 3. worker.env ---
log "3. worker.env"
WKEY_FINAL="${WKEY:-$(grep -E '^BRIDGE_WORKER_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)}"
if [ -z "$WKEY_FINAL" ]; then
  # keys.json survived but worker.env did not (or held no key). The full key is
  # only ever printed at creation — bridge.py can't show it again — so mint a
  # fresh worker key instead. Multiple worker keys are valid, so nothing breaks.
  warn "worker key tidak terbaca — terbitkan kunci worker baru"
  WKEY_FINAL="$(_keygen worker "muse-vm-$(date +%Y%m%d%H%M%S)")"
  [ -n "$WKEY_FINAL" ] || die "gagal menerbitkan worker key"
  ok "worker key baru (${WKEY_FINAL:0:14}…)"
fi
# Preserve a hand-edited UPSTREAM: only MUSE_UPSTREAM (explicit) overrides it.
if [ -z "${MUSE_UPSTREAM+set}" ] && [ -f "$ENV_FILE" ]; then
  PREV="$(grep -E '^UPSTREAM=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  if [ -n "$PREV" ]; then UPSTREAM="$PREV"; fi
fi
umask 077
# Write to a temp file first so we can tell whether the content really changed;
# a changed worker key or UPSTREAM must restart the worker (the unit file itself
# is unchanged, so systemd has no idea anything moved).
ENV_TMP="$(mktemp)"
cat > "$ENV_TMP" <<EOF
# generated by muse-bootstrap.sh — jangan di-commit
BRIDGE_URL=http://127.0.0.1:$PBRG
BRIDGE_WORKER_KEY=$WKEY_FINAL
WORKER_LABEL=muse-vm
UPSTREAM=$UPSTREAM
POLL_INTERVAL=3
REQUEST_TIMEOUT=120
WATCH_DIR=$QUEUE_DIR/pending
EOF
ENV_PAYLOAD_CHANGED=0
if [ -f "$ENV_FILE" ] && cmp -s "$ENV_TMP" "$ENV_FILE"; then
  rm -f "$ENV_TMP"; skip "worker.env (identik)"
else
  mv "$ENV_TMP" "$ENV_FILE"; ENV_PAYLOAD_CHANGED=1; CHANGED=1
  ok "$ENV_FILE diperbarui"
fi
chmod 600 "$ENV_FILE"

# keys.pin — the two full keys, so a FUTURE VM can re-attach to this identity
# instead of minting new ones (see MUSE_KEYS_FROM above). Stays local, mode 600,
# never printed and never committed. If you want a swapped VM to keep working
# with an already-configured 9Router/Hermes, copy this file somewhere you own
# (e.g. the relay) and point MUSE_KEYS_FROM at it.
UKEY_FINAL="${UKEY:-}"
if [ -z "$UKEY_FINAL" ] && [ -f "$KEYS_FILE" ]; then
  UKEY_FINAL="$(python3 - "$KEYS_FILE" <<'PY' 2>/dev/null || true
import json, sys
for k in json.load(open(sys.argv[1])).get("keys", []):
    if k.get("role") == "user":
        print(k["key"])
PY
)"
fi
if [ -n "$UKEY_FINAL" ]; then
  umask 077
  printf 'BRIDGE_WORKER_KEY=%s\nBRIDGE_USER_KEY=%s\n' "$WKEY_FINAL" "$UKEY_FINAL" \
    > "$BRIDGE_DIR/keys.pin"
  chmod 600 "$BRIDGE_DIR/keys.pin"; ok "keys.pin (600) — sumber pin untuk VM berikutnya"
else
  warn "user key tidak terbaca — keys.pin dilewati"
fi

# -------------------------------------------------------- 4. bridge service ---
log "4. Layanan bridge"
if [ "$HAVE_SYSTEMD" = 1 ]; then
  write_unit muse-bridge "[Unit]
Description=Muse bridge for 9Router
After=network.target
[Service]
ExecStart=/usr/bin/env python3 $BRIDGE_DIR/bridge.py serve
Environment=BRIDGE_QUEUE=$QUEUE_DIR
Restart=always
RestartSec=3
User=$(id -un)
[Install]
WantedBy=multi-user.target"
  # bridge.py itself changed → the unit file didn't, so restart explicitly
  if [ "$BRIDGE_PAYLOAD_CHANGED" = 1 ]; then force_restart muse-bridge; fi
else
  warn "tanpa systemd — bridge harus dijalankan manual: python3 $BRIDGE_DIR/bridge.py serve"
fi

# --------------------------------------------------------- 5. 9Router ---
log "5. 9Router"
if [ "$NODE_OK" = 0 ]; then
  warn "node tidak ada — lewati 9Router"
elif command -v 9router >/dev/null 2>&1 || [ -x "$HOME/.npm-global/bin/9router" ]; then
  RB="$(command -v 9router || echo "$HOME/.npm-global/bin/9router")"
  # Canonical unit, built once. NOTE: 9router takes FLAGS, not a `serve`
  # subcommand — `9router serve ...` prints "Exiting..." and never listens, so
  # an earlier fallback here produced a dead gateway after every VM reset.
  NINE_UNIT="[Unit]
Description=9Router AI gateway (127.0.0.1:$P9R)
After=network.target

[Service]
Type=simple
User=$(id -un)
Environment=HOME=$HOME
Environment=DATA_DIR=$HOME/.9router
ExecStart=$RB -H 127.0.0.1 -p $P9R -n --skip-update
Restart=always
RestartSec=5
StandardOutput=append:$HOME/.9router/service.log
StandardError=append:$HOME/.9router/service.log

[Install]
WantedBy=multi-user.target"
  # Persist it under $HOME (survives a reset that wipes /etc) so the correct
  # flags are restored, not a regenerated approximation.
  NINE_DURABLE="$BRIDGE_DIR/systemd/9router.service"
  mkdir -p "$(dirname "$NINE_DURABLE")"
  if ! printf '%s\n' "$NINE_UNIT" | cmp -s - "$NINE_DURABLE" 2>/dev/null; then
    printf '%s\n' "$NINE_UNIT" > "$NINE_DURABLE.tmp" && mv "$NINE_DURABLE.tmp" "$NINE_DURABLE"
    chmod 600 "$NINE_DURABLE"; ok "unit 9router disimpan di \$HOME"
  fi
  if [ -f "$UNIT_DIR/9router.service" ]; then
    # Unit already exists — do NOT overwrite it (it may carry flags we didn't
    # write). Just make sure it is enabled and alive, so a dead 9Router heals.
    $SUDO systemctl enable 9router >/dev/null 2>&1 || true
    if $SUDO systemctl is-active --quiet 9router; then
      skip "9router sudah jalan"
    else
      $SUDO systemctl restart 9router >/dev/null 2>&1 || warn "gagal start 9router"
      ok "9router dihidupkan kembali"
    fi
  elif [ "$HAVE_SYSTEMD" = 1 ]; then
    # /etc was wiped (reset) — restore the canonical unit, not a guess.
    write_unit 9router "$NINE_UNIT"
    if ! $SUDO systemctl is-active --quiet 9router; then
      $SUDO systemctl start 9router >/dev/null 2>&1 || warn "gagal start 9router"
    fi
  fi
else
  warn "9router belum terpasang — jalankan: npm i -g 9router (lalu ulangi skrip ini)"
fi

# ---------------------------------------------------------- 6. worker ---
log "6. Worker (penjawab)"
fetch "$REPO_RAW/bridge-worker.py" "$BRIDGE_DIR/bridge-worker.py"
WORKER_PAYLOAD_CHANGED="$FETCH_CHANGED"
if [ "$HAVE_SYSTEMD" = 1 ]; then
  write_unit muse-worker "[Unit]
Description=Muse bridge worker
After=network.target muse-bridge.service
[Service]
ExecStart=/usr/bin/env python3 $BRIDGE_DIR/bridge-worker.py --loop
EnvironmentFile=$ENV_FILE
Restart=always
RestartSec=5
User=$(id -un)
[Install]
WantedBy=multi-user.target"
  # worker.env or bridge-worker.py changed → restart to pick it up
  if [ "$ENV_PAYLOAD_CHANGED" = 1 ] || [ "$WORKER_PAYLOAD_CHANGED" = 1 ]; then
    force_restart muse-worker
  fi
else
  warn "tanpa systemd — worker manual: set -a; . $ENV_FILE; python3 $BRIDGE_DIR/bridge-worker.py --loop"
fi

# ---------------------------------------------------------- 7. tunnel ---
log "7. Reverse tunnel (opsional)"
if [ -z "$RELAY" ]; then
  skip "MUSE_RELAY tidak diisi"
elif ! command -v ssh >/dev/null 2>&1; then
  warn "ssh tidak ada"
else
  # VM tidak punya sshd dan tidak bisa menerima koneksi masuk, tapi egress :22
  # terbuka (recon 2026-10-02). Jadi VM MENDIAL KELUAR ke relay; relay yang
  # mempublikasikan port. Pubkey VM harus terdaftar di relay lebih dulu.
  fetch "$REPO_RAW/muse-ssh-tunnel.sh" "$BRIDGE_DIR/muse-ssh-tunnel.sh"
  TUNNEL_PAYLOAD_CHANGED="$FETCH_CHANGED"
  PUB="$(cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true)"
  if [ -z "$PUB" ]; then
    warn "~/.ssh/id_ed25519.pub tidak ada — jalankan: ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"
  else
    printf '\n  Pubkey VM (daftarkan ke %s:~/.ssh/authorized_keys):\n\n    %s\n\n' "$RELAY" "$PUB"
  fi
  # Publishing a shell is useless if nobody can log in: the user's own public
  # key must be in authorized_keys. Idempotent — the same key twice is a no-op.
  # Accepts one key per line (or one single line); non-key lines are ignored.
  #
  # sshd resolves `~/.ssh` from the ACCOUNT home in /etc/passwd, NOT from $HOME
  # (which on the Muse VM is /home/hatch while root's passwd home is /root).
  # Writing to $HOME therefore produced a shell that refused every key. Write to
  # the passwd home of the login user — that is the directory sshd actually
  # consults. On an ordinary VM the two are identical, so this is a no-op there.
  if [ "$SHELL_ACCESS" = 1 ] && [ -n "${MUSE_SSH_AUTHORIZED_KEYS:-}" ]; then
    # Persist the user keys under $HOME so the self-heal timer can re-add them
    # after a reset without needing the original one-shot env var.
    printf '%s\n' "$MUSE_SSH_AUTHORIZED_KEYS" > "$AK_FILE"
    chmod 600 "$AK_FILE" 2>/dev/null || true
    AK_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
    [ -n "$AK_HOME" ] || AK_HOME="$HOME"
    mkdir -p "$AK_HOME/.ssh"; chmod 700 "$AK_HOME/.ssh"
    AK="$AK_HOME/.ssh/authorized_keys"; touch "$AK"; chmod 600 "$AK"
    added=0
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      case "$k" in ssh-*|ecdsa-*|sk-*) ;; *) continue ;; esac
      if ! grep -qxF -- "$k" "$AK" 2>/dev/null; then
        printf '%s\n' "$k" >> "$AK"; added=$((added + 1))
      fi
    done < <(printf '%s\n' "$MUSE_SSH_AUTHORIZED_KEYS")
    if [ "$added" -gt 0 ]; then ok "authorized_keys: $added kunci user ditambahkan ($AK)"; else skip "authorized_keys sudah memuat kunci user ($AK)"; fi
  fi
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    # Only publish a shell if there is actually an sshd to reach. The tunnel
    # runs with ExitOnForwardFailure=yes, so a forward to a dead :22 would make
    # ssh exit and kill the WHOLE tunnel — taking the bridge down with it. So
    # fail safe: no sshd, no shell forward, bridge keeps working.
    SHELL_ENV=""
    if [ "$SHELL_ACCESS" = 1 ]; then
      if port_up 22; then
        SHELL_ENV="Environment=SHELL_ACCESS=1
Environment=SHELL_PORT=$SHELL_PORT"
        ok "shell VM akan dipublikasikan: ssh -p $SHELL_PORT $(id -un)@${RELAY#*@}"
      else
        warn "MUSE_SHELL_ACCESS=1 tapi tidak ada sshd di :22 — shell dilewati (install openssh-server dulu)"
      fi
    fi
    write_unit muse-tunnel "[Unit]
Description=Muse reverse tunnel to relay
After=network-online.target
Wants=network-online.target
[Service]
# systemd does not export HOME. Without it ssh looks for the identity in
# /root/.ssh (empty) instead of \$HOME/.ssh/id_ed25519 — the key never gets
# offered and the relay answers \"Permission denied (publickey)\". The keypair
# lives in \$HOME/.ssh, so HOME must be exported to match.
Environment=HOME=$HOME
Environment=SSH_KEY=$HOME/.ssh/id_ed25519
Environment=RELAY=$RELAY
Environment=RELAY_PORT=22
Environment=BRIDGE_PORT=$PBRG
Environment=REMOTE_PORT=$RELAY_PORT
$SHELL_ENV
ExecStart=/usr/bin/env bash $BRIDGE_DIR/muse-ssh-tunnel.sh
Restart=always
RestartSec=5
User=$(id -un)
[Install]
WantedBy=multi-user.target"
    if [ "$TUNNEL_PAYLOAD_CHANGED" = 1 ]; then force_restart muse-tunnel; fi
  fi
fi

# ------------------------------------------------------- 8. self-heal ---
# A systemd timer re-runs this very script on a schedule, so if a service dies,
# a key file is lost, or the VM merely reboots with its disk intact, the stack
# repairs itself with no human in the loop. It is a no-op when everything is
# already healthy (every step above skips).
#
# LIMIT, stated plainly: if /etc is wiped (a VM reset), this timer goes with it.
# That is why step 8b ALSO registers a Muse hook under $HOME/hooks, which
# survives the wipe and re-runs the same recipe. The timer covers the
# reboot/corruption case; the hook covers the wipe case; the one-liner below
# covers a brand-new VM.
log "8. Self-heal timer"
if [ "$HAVE_SYSTEMD" = 1 ] && [ "${MUSE_NO_TIMER:-0}" != "1" ]; then
  # Keep the recipe on disk FIRST — the unit below points at this path, and the
  # timer must never fire against a missing script.
  if [ "$(readlink -f "$0" 2>/dev/null)" != "$BRIDGE_DIR/muse-bootstrap.sh" ]; then
    fetch "$REPO_RAW/muse-bootstrap.sh" "$BRIDGE_DIR/muse-bootstrap.sh"
  else
    skip "muse-bootstrap.sh (sudah di tempatnya)"
  fi
  # The self-heal run must rebuild the SAME stack, so every knob that shapes it
  # has to travel with the unit. A reset wipes muse-tunnel (and openssh-server)
  # while leaving the timer alive; without these the timer would faithfully
  # re-run bootstrap and still never bring the tunnel back — it would look
  # healthy and stay dark. Carry the tunnel/re shell knobs explicitly.
  HEAL_ENV="Environment=HOME=$HOME"
  [ -n "$RELAY" ] && HEAL_ENV="$HEAL_ENV
Environment=MUSE_RELAY=$RELAY"
  [ "$SHELL_ACCESS" = "1" ] && HEAL_ENV="$HEAL_ENV
Environment=MUSE_SHELL_ACCESS=1
Environment=MUSE_SHELL_PORT=$SHELL_PORT"
  write_unit muse-bootstrap "[Unit]
Description=Muse stack self-heal (re-run bootstrap)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
$HEAL_ENV
# Deliberately NOT pinning MUSE_REPO_RAW here: the timer should re-resolve the
# branch each run so self-heal also picks up new commits, not just re-apply an
# old snapshot forever.
ExecStart=/usr/bin/env bash $BRIDGE_DIR/muse-bootstrap.sh
[Install]
WantedBy=multi-user.target"
  TMR="$UNIT_DIR/muse-bootstrap.timer"
  if [ ! -f "$TMR" ] || ! grep -q 'OnUnitActiveSec=5min' "$TMR" 2>/dev/null; then
    $SUDO tee "$TMR" >/dev/null <<'EOF'
[Unit]
Description=Run Muse stack self-heal every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true
[Install]
WantedBy=timers.target
EOF
    $SUDO systemctl daemon-reload
    ok "timer muse-bootstrap.timer (tiap 5 menit)"; CHANGED=1
  else
    skip "timer muse-bootstrap.timer"
  fi
  $SUDO systemctl enable --now muse-bootstrap.timer >/dev/null 2>&1 \
    || warn "gagal enable timer"
else
  warn "systemd tidak ada / MUSE_NO_TIMER=1 — self-heal timer dilewati"
fi

# --------------------------------------------- 8b. self-heal via Muse hook ---
# The timer above dies with /etc. Muse's own hook system does not: hooks live
# under $HOME/hooks (which a reset keeps) and Muse re-runs them on an interval
# as root. Registering one here means a wipe of /etc can no longer leave the
# stack dark — Muse itself notices and rebuilds it from bootstrap.conf.
#
# The script is embedded rather than fetched on purpose: it must be able to
# repair the stack even when egress is down, which is exactly the state a
# reset tends to leave behind.
log "8b. Self-heal via hook Muse"
if [ "${MUSE_NO_HOOK:-0}" != "1" ] && [ -d "$HOME/hooks" ]; then
  HOOK_SCRIPT="$HOME/hooks/scripts/muse-selfheal.sh"
  HOOK_DEF="$HOME/hooks/definitions/muse-selfheal.json"
  mkdir -p "$(dirname "$HOOK_SCRIPT")" "$(dirname "$HOOK_DEF")"

  cat > "$HOOK_SCRIPT.tmp" <<'HOOKEOF'
#!/usr/bin/env bash
# Muse self-heal hook. Lives in $HOME/hooks so it survives a VM reset, unlike
# the systemd timer in /etc/systemd/system. Muse runs it on an interval as
# root; it repairs the stack and stays silent when everything is already fine.
set -uo pipefail
source "$HATCH_HOOK_RUNTIME"

BRIDGE_DIR=/home/hatch/muse-bridge
BOOT="$BRIDGE_DIR/muse-bootstrap.sh"
LOG="$BRIDGE_DIR/selfheal.log"
API="https://api.github.com/repos/tiyok9/Muse-on-9Router-Hermes-Agent-ai/contents/muse-bootstrap.sh"

mkdir -p "$BRIDGE_DIR" 2>/dev/null || true
exec 9>"$BRIDGE_DIR/.selfheal.lock" 2>/dev/null || true
command -v flock >/dev/null 2>&1 && { flock -n 9 || silent "selfheal sedang berjalan" '{}'; }

problems=()
for u in muse-bridge muse-worker muse-tunnel; do
  systemctl is-active --quiet "$u" 2>/dev/null || problems+=("$u tidak aktif")
done
curl -fsS -m 8 http://127.0.0.1:8765/health >/dev/null 2>&1 || problems+=("bridge /health gagal")
# Only police 9Router when it is actually installed — otherwise a machine
# without it would self-heal forever over a service it never had.
if [ -x /home/hatch/.npm-global/bin/9router ] || command -v 9router >/dev/null 2>&1; then
  curl -fsS -m 8 http://127.0.0.1:20128/api/health >/dev/null 2>&1 || problems+=("9Router /api/health gagal")
fi
ss -tln 2>/dev/null | grep -qE ':22\b' || problems+=("sshd :22 tidak listen")
[ -f "$BOOT" ] || problems+=("resep bootstrap hilang")
[ ${#problems[@]} -eq 0 ] && silent "stack sehat" '{}'

if [ ! -f "$BOOT" ]; then
  curl -fsSL -m 60 "$API" 2>/dev/null \
    | python3 -c 'import sys,json,base64;sys.stdout.write(base64.b64decode(json.load(sys.stdin)["content"]).decode())' \
    > "$BOOT" 2>/dev/null && chmod 700 "$BOOT" 2>/dev/null
fi

{
  echo "=== selfheal $(date -Is) : ${problems[*]} ==="
  HOME=/home/hatch bash "$BOOT"
} >>"$LOG" 2>&1
rc=$?

payload=$(printf '%s\n' "${problems[@]}" | jq -R . | jq -cs '{problems:.}')
if [ "$rc" -eq 0 ]; then
  wake "stack dipulihkan otomatis" "$payload"
else
  wake "pemulihan otomatis GAGAL (exit $rc)" "$payload"
fi
HOOKEOF
  if [ -f "$HOOK_SCRIPT" ] && cmp -s "$HOOK_SCRIPT.tmp" "$HOOK_SCRIPT"; then
    rm -f "$HOOK_SCRIPT.tmp"; skip "hook muse-selfheal.sh (identik)"
  else
    mv "$HOOK_SCRIPT.tmp" "$HOOK_SCRIPT"; chmod 700 "$HOOK_SCRIPT"
    ok "hook muse-selfheal.sh dipasang"; CHANGED=1
  fi

  # Mirror the schema of the known-good muse-bridge-queue hook exactly.
  NOW_MS="$(($(date +%s) * 1000))"
  cat > "$HOOK_DEF.tmp" <<EOF
{
  "version": 1,
  "id": "muse-selfheal",
  "enabled": true,
  "script_path": "~/hooks/scripts/muse-selfheal.sh",
  "prompt": "Self-heal untuk stack muse-bridge. Hook ini mengecek bridge/worker/tunnel/sshd dan menjalankan ulang muse-bootstrap.sh bila ada yang mati. Bila kamu terbangun karena ini, cukup laporkan singkat hasilnya ke pengguna (berhasil dipulihkan / perlu perhatian) — jangan jalankan perbaikan manual lagi.",
  "poll_interval_secs": 60,
  "script_timeout_secs": 300,
  "delivery": {
    "surface": "main"
  },
  "presentation_locale": "id-ID",
  "created_at_ms": $NOW_MS,
  "updated_at_ms": $NOW_MS
}
EOF
  if [ -f "$HOOK_DEF" ] && cmp -s "$HOOK_DEF.tmp" "$HOOK_DEF"; then
    rm -f "$HOOK_DEF.tmp"; skip "definisi hook muse-selfheal (identik)"
  else
    mv "$HOOK_DEF.tmp" "$HOOK_DEF"; chmod 600 "$HOOK_DEF"
    ok "definisi hook muse-selfheal dipasang (tiap 60 dtk)"; CHANGED=1
  fi
else
  warn "sistem hook Muse tidak ada / MUSE_NO_HOOK=1 — self-heal hook dilewati"
fi

# ------------------------------------------------------- 9. verifikasi ---
log "9. Verifikasi"
sleep 2
if http_ok "http://127.0.0.1:$PBRG/health"; then ok "bridge /health OK"
elif port_up "$PBRG"; then warn "port $PBRG hidup tapi /health belum OK (tunggu beberapa detik)"
else warn "bridge belum listen di $PBRG"; fi
if port_up "$P9R"; then ok "9Router listen di $P9R"
else warn "9Router belum listen di $P9R"; fi

# Prove the worker key is actually accepted. Both units can report "active"
# while every request 401s (worker.env holding a key that was minted into the
# wrong keys.json). Assert the credential end-to-end, and REPAIR on 401 —
# re-running alone would not help, because the bootstrap reuses the same bad
# key from worker.env. Self-heal has to actually heal.
if [ -n "${WKEY_FINAL:-}" ]; then
  AUTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "Authorization: Bearer $WKEY_FINAL" \
    "http://127.0.0.1:$PBRG/muse/pending" 2>/dev/null || echo 000)"
  case "$AUTH_CODE" in
    200) ok "worker key diterima bridge (auth OK)" ;;
    401)
      warn "worker key DITOLAK (401) — terbitkan ulang & sinkronkan worker.env"
      NEW_WKEY="$(_keygen worker "muse-vm-heal-$(date +%Y%m%d%H%M%S)")"
      if [ -n "$NEW_WKEY" ]; then
        # Rewrite only the key line; leave every other knob (UPSTREAM, ports) as-is.
        if sed -i "s|^BRIDGE_WORKER_KEY=.*|BRIDGE_WORKER_KEY=$NEW_WKEY|" "$ENV_FILE" 2>/dev/null; then
          chmod 600 "$ENV_FILE"
          [ "$HAVE_SYSTEMD" = 1 ] && force_restart muse-worker
          sleep 2
          RETRY="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            -H "Authorization: Bearer $NEW_WKEY" \
            "http://127.0.0.1:$PBRG/muse/pending" 2>/dev/null || echo 000)"
          if [ "$RETRY" = 200 ]; then ok "worker key diperbaiki — auth OK"
          else warn "perbaikan belum berhasil (HTTP $RETRY) — cek worker.env vs keys.json"; fi
          CHANGED=1
        else
          warn "gagal menulis ulang $ENV_FILE"
        fi
      else
        warn "gagal menerbitkan worker key pengganti"
      fi
      ;;
    000) warn "auth belum bisa diuji (bridge tidak menjawab)" ;;
    *)   warn "auth tidak terduga: HTTP $AUTH_CODE" ;;
  esac
else
  warn "worker key tidak tersedia — auth tidak diuji"
fi

log "Selesai$([ "$CHANGED" = 1 ] && echo ' (ada perubahan)' || echo ' (tidak ada perubahan — sudah sehat)')"
cat <<EOF

  Bridge   : http://127.0.0.1:$PBRG
  Antrean  : $QUEUE_DIR
  Kunci    : $KEYS_FILE  (JANGAN pernah ditampilkan / di-commit)
  Worker   : $ENV_FILE  (UPSTREAM=$UPSTREAM)

  Cek cepat:
    curl -s http://127.0.0.1:$PBRG/health
    python3 $BRIDGE_DIR/bridge.py keylist

  Script ini aman dijalankan ulang kapan saja — VM baru cukup:
    curl -fsSL $BRANCH_RAW/muse-bootstrap.sh | bash
EOF
