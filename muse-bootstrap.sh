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
# from the recon in MUSE-SSH-RECON.md. NOT executed locally (user policy).
#
# Env knobs (all optional):
#   MUSE_REPO_RAW   base raw URL        (default: the public repo, main branch)
#   MUSE_BRIDGE_DIR bridge home         (default: $HOME/muse-bridge)
#   MUSE_PORT_9R    9Router port        (default: 20128)
#   MUSE_PORT_BRG   bridge port         (default: 8765)
#   MUSE_UPSTREAM   worker upstream     (default: none = smoke-test echo)
#   MUSE_RELAY      user@host to reverse-tunnel through (enables the tunnel step)
#   MUSE_RELAY_PORT relay port to publish on              (default: 8765)
set -euo pipefail

REPO_RAW="${MUSE_REPO_RAW:-https://raw.githubusercontent.com/tiyok9/Muse-on-9Router-Hermes-Agent-ai/main}"
BRIDGE_DIR="${MUSE_BRIDGE_DIR:-$HOME/muse-bridge}"
QUEUE_DIR="$BRIDGE_DIR/queue"
KEYS_FILE="$BRIDGE_DIR/keys.json"
ENV_FILE="$BRIDGE_DIR/worker.env"
P9R="${MUSE_PORT_9R:-20128}"
PBRG="${MUSE_PORT_BRG:-8765}"
UPSTREAM="${MUSE_UPSTREAM:-none}"
RELAY="${MUSE_RELAY:-}"
RELAY_PORT="${MUSE_RELAY_PORT:-8765}"
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

# fetch SRC DST — download only when content actually differs (idempotent).
# Sets FETCH_CHANGED=1 when the destination was actually replaced, so callers
# can restart the service that consumes it (a unit file that didn't change does
# not by itself tell systemd the payload changed).
fetch() {
  local src="$1" dst="$2" tmp
  FETCH_CHANGED=0
  tmp="$(mktemp)"
  if ! curl -fsSL --max-time 30 "$src" -o "$tmp"; then
    rm -f "$tmp"; die "gagal unduh $src"
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

if [ "$need_worker" = 1 ]; then
  if [ -n "${MUSE_WORKER_KEY:-}" ]; then
    _insert_key worker "$MUSE_WORKER_KEY" muse-vm-pinned
    WKEY="$MUSE_WORKER_KEY"; ok "worker key dipatok (${WKEY:0:14}…)"
  else
    WKEY="$(cd "$BRIDGE_DIR" && python3 bridge.py keygen --role worker --label muse-vm 2>/dev/null)"
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
    UKEY="$(cd "$BRIDGE_DIR" && python3 bridge.py keygen --role user --label 9router 2>/dev/null)"
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
  WKEY_FINAL="$(cd "$BRIDGE_DIR" && python3 bridge.py keygen --role worker \
                --label "muse-vm-$(date +%Y%m%d%H%M%S)" 2>/dev/null)"
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
    write_unit 9router "[Unit]
Description=9Router
After=network.target
[Service]
ExecStart=$RB serve --port $P9R --host 127.0.0.1
Restart=always
RestartSec=3
User=$(id -un)
[Install]
WantedBy=multi-user.target"
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
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    write_unit muse-tunnel "[Unit]
Description=Muse reverse tunnel to relay
After=network-online.target
Wants=network-online.target
[Service]
Environment=RELAY=$RELAY
Environment=RELAY_PORT=22
Environment=BRIDGE_PORT=$PBRG
Environment=REMOTE_PORT=$RELAY_PORT
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
# LIMIT, stated plainly: if the VM is *replaced* (fresh disk), this timer goes
# with it. Nothing inside an ephemeral VM can survive its own wipe — the recipe
# must be re-invoked from outside, which is exactly what the one-liner below is
# for. The timer covers the reboot/corruption case; the one-liner covers the
# swap case.
log "8. Self-heal timer"
if [ "$HAVE_SYSTEMD" = 1 ] && [ "${MUSE_NO_TIMER:-0}" != "1" ]; then
  # Keep the recipe on disk FIRST — the unit below points at this path, and the
  # timer must never fire against a missing script.
  if [ "$(readlink -f "$0" 2>/dev/null)" != "$BRIDGE_DIR/muse-bootstrap.sh" ]; then
    fetch "$REPO_RAW/muse-bootstrap.sh" "$BRIDGE_DIR/muse-bootstrap.sh"
  else
    skip "muse-bootstrap.sh (sudah di tempatnya)"
  fi
  write_unit muse-bootstrap "[Unit]
Description=Muse stack self-heal (re-run bootstrap)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
Environment=MUSE_REPO_RAW=$REPO_RAW
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

# ------------------------------------------------------- 9. verifikasi ---
log "9. Verifikasi"
sleep 2
if http_ok "http://127.0.0.1:$PBRG/health"; then ok "bridge /health OK"
elif port_up "$PBRG"; then warn "port $PBRG hidup tapi /health belum OK (tunggu beberapa detik)"
else warn "bridge belum listen di $PBRG"; fi
if port_up "$P9R"; then ok "9Router listen di $P9R"
else warn "9Router belum listen di $P9R"; fi

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
    curl -fsSL $REPO_RAW/muse-bootstrap.sh | bash
EOF
