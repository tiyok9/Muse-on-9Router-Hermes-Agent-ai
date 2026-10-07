#!/usr/bin/env bash
# relay-wg-bridge-setup.sh — make the WireGuard -> Muse 9Router bridge permanent
# ON THE RELAY (the WireGuard hub).
#
# Why this exists: the Muse VM is a systemd-nspawn container with no
# CAP_NET_ADMIN and no /dev/net/tun, so it can never join WireGuard. The only
# way a WG peer can reach the VM's 9Router is a two-hop bridge:
#
#   [ WG peer ] ==WireGuard==> [ relay 10.100.0.1:WG_PORT ] <==ssh -R== [ Muse VM :20128 ]
#                                    ^ this script owns this hop
#
# The VM side publishes its 9Router on a relay loopback port (muse-tunnel's
# WG_PUB_PORT). This script installs a tiny TCP forwarder that re-publishes that
# loopback port on the WG hub address, as a real systemd unit with `enable`, so
# it survives a relay reboot with no human in the loop.
#
# Idempotent: safe to re-run. It only rewrites the unit when the content
# changes, and only restarts the service when something actually changed.
#
# Usage:
#   sudo WG_PORT=22028 ./relay-wg-bridge-setup.sh
#
# Env:
#   WG_ADDR   address to listen on   (default: auto-detect wg0's address)
#   WG_PORT   port to listen on      (default 22028)
#   TGT_ADDR  loopback target        (default 127.0.0.1)
#   TGT_PORT  loopback target port   (default = WG_PORT)
#   DRY_RUN   1 = print the unit, change nothing
set -euo pipefail

WG_ADDR="${WG_ADDR:-}"
WG_PORT="${WG_PORT:-22028}"
TGT_ADDR="${TGT_ADDR:-127.0.0.1}"
TGT_PORT="${TGT_PORT:-$WG_PORT}"
DRY_RUN="${DRY_RUN:-0}"

UNIT="muse-wg-bridge"
OPT_DIR="/opt/$UNIT"
UNIT_PATH="/etc/systemd/system/$UNIT.service"

# Resolve the WG hub address from wg0 unless the caller pinned one. Listening on
# the tunnel address (not 0.0.0.0) is deliberate: it keeps 9Router off the public
# interface entirely — only WireGuard peers can reach it.
if [ -z "$WG_ADDR" ]; then
    WG_ADDR="$(ip -4 -brief addr show wg0 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)"
fi
if [ -z "$WG_ADDR" ]; then
    echo "! tidak bisa menentukan alamat wg0 — set WG_ADDR=10.x.y.z dan jalankan ulang" >&2
    exit 1
fi

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
FWD_SRC="$SRC_DIR/relay-fwd.py"
[ -f "$FWD_SRC" ] || { echo "! relay-fwd.py tidak ada di $SRC_DIR" >&2; exit 1; }

UNIT_BODY="[Unit]
Description=Muse WireGuard bridge ($WG_ADDR:$WG_PORT -> $TGT_ADDR:$TGT_PORT)
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 $OPT_DIR/relay-fwd.py $WG_ADDR $WG_PORT $TGT_ADDR $TGT_PORT
Restart=always
RestartSec=3
# Keep it minimal: no writable paths, no new privileges.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target"

if [ "$DRY_RUN" = "1" ]; then
    echo "--- unit yang akan dipasang ($UNIT_PATH) ---"
    printf '%s\n' "$UNIT_BODY"
    echo "--- target: $OPT_DIR/relay-fwd.py ---"
    exit 0
fi

$SUDO install -d -m 755 "$OPT_DIR"
if [ -f "$OPT_DIR/relay-fwd.py" ] && cmp -s "$FWD_SRC" "$OPT_DIR/relay-fwd.py"; then
    echo "• relay-fwd.py (identik)"
else
    $SUDO install -m 644 "$FWD_SRC" "$OPT_DIR/relay-fwd.py"
    echo "✓ relay-fwd.py dipasang di $OPT_DIR"
fi

TMP="$(mktemp)"
printf '%s\n' "$UNIT_BODY" > "$TMP"
CHANGED=0
if [ -f "$UNIT_PATH" ] && cmp -s "$TMP" "$UNIT_PATH"; then
    echo "• unit $UNIT (identik)"
else
    $SUDO install -m 644 "$TMP" "$UNIT_PATH"
    echo "✓ unit $UNIT ditulis"
    CHANGED=1
fi
rm -f "$TMP"

$SUDO systemctl daemon-reload
$SUDO systemctl enable "$UNIT" >/dev/null 2>&1 || true
if [ "$CHANGED" = 1 ] || ! $SUDO systemctl is-active --quiet "$UNIT"; then
    $SUDO systemctl restart "$UNIT"
    echo "✓ $UNIT di-restart"
else
    echo "• $UNIT sudah jalan"
fi

sleep 1
if $SUDO systemctl is-active --quiet "$UNIT"; then
    echo "✓ $UNIT active/enabled — WG peer bisa akses http://$WG_ADDR:$WG_PORT"
else
    echo "! $UNIT gagal start — cek: journalctl -u $UNIT -n 50" >&2
    exit 1
fi
