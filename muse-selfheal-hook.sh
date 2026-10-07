#!/usr/bin/env bash
# Muse self-heal hook.
#
# WHY THIS EXISTS
#   The stack (bridge / worker / reverse tunnel / published sshd) is normally
#   kept alive by a systemd timer, but that timer lives in /etc/systemd/system
#   which a VM reset WIPES. After a reset the stack comes back dark and stays
#   dark until a human re-runs bootstrap by hand.
#   This hook lives in $HOME/hooks, which SURVIVES a reset, and Muse itself
#   runs it on an interval as root. So a reset can no longer leave the stack
#   down: the hook notices and rebuilds it with the CURRENT settings.
#
# BEHAVIOUR
#   healthy            -> silent (no message, no wake)
#   broken, repaired   -> wake once, so the user learns it recovered
#   broken, unrepaired -> wake, asking for attention
set -uo pipefail
source "$HATCH_HOOK_RUNTIME"

BRIDGE_DIR=/home/hatch/muse-bridge
BOOT="$BRIDGE_DIR/muse-bootstrap.sh"
LOG="$BRIDGE_DIR/selfheal.log"
REPO_RAW_API="https://api.github.com/repos/tiyok9/Muse-on-9Router-Hermes-Agent-ai/contents/muse-bootstrap.sh"

# Only one repair at a time: bootstrap takes ~30-60s, the poll is faster.
mkdir -p "$BRIDGE_DIR" 2>/dev/null || true
exec 9>"$BRIDGE_DIR/.selfheal.lock" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || silent "selfheal sedang berjalan" '{}'
fi

# ---- health check: collect every problem, don't stop at the first ----------
problems=()
for u in muse-bridge muse-worker muse-tunnel; do
  systemctl is-active --quiet "$u" 2>/dev/null || problems+=("$u tidak aktif")
done
curl -fsS -m 8 http://127.0.0.1:8765/health >/dev/null 2>&1 || problems+=("bridge /health gagal")
ss -tln 2>/dev/null | grep -qE ':22\b' || problems+=("sshd :22 tidak listen")
[ -f "$BOOT" ] || problems+=("resep bootstrap hilang")

if [ ${#problems[@]} -eq 0 ]; then
  silent "stack sehat" '{}'
fi

# ---- repair path -----------------------------------------------------------
# The recipe usually survives in $HOME; re-fetch only if it went missing.
if [ ! -f "$BOOT" ]; then
  curl -fsSL -m 60 "$REPO_RAW_API" 2>/dev/null \
    | python3 -c 'import sys,json,base64;sys.stdout.write(base64.b64decode(json.load(sys.stdin)["content"]).decode())' \
    > "$BOOT" 2>/dev/null && chmod 700 "$BOOT" 2>/dev/null
fi

# bootstrap.conf (under $HOME) already carries RELAY / SHELL_ACCESS / ports,
# so a bare re-run rebuilds the SAME stack with zero env vars.
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
