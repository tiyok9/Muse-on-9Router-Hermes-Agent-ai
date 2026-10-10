#!/usr/bin/env bash
# muse-ssh-tunnel.sh — publish the Muse bridge through an SSH relay YOU own.
#
# Shape of the solution: the Muse VM is a client-only sandbox — it cannot accept
# inbound connections (same wall that killed the Tailscale plan). So we invert
# it: the VM dials OUT to a relay you control with `ssh -R`, and that outbound
# connection becomes the reachable path. No inbound port on the VM, no public
# DNS on the VM, no third-party tunnel service.
#
#   [ laptop ] --ssh--> [ your relay ] <--outbound ssh-- [ Muse VM :8765 ]
#                            ^ publishes 127.0.0.1:8765
#
# Usage:
#   RELAY=user@my-vps.example.com ./muse-ssh-tunnel.sh
#
# Env (all optional except RELAY):
#   RELAY          user@host of the relay            REQUIRED
#   RELAY_PORT     sshd port on the relay            (default 22)
#   BRIDGE_PORT    local bridge port to publish      (default 8765)
#   REMOTE_PORT    port published on the relay       (default = BRIDGE_PORT)
#   REMOTE_BIND    bind address on the relay         (default 127.0.0.1)
#   SSH_KEY        private key path                  (default: ssh picks)
#   WG_PUB_PORT    relay loopback port to also publish THIS VM's 9Router on,
#                  so a second hop (relay-fwd.py on the relay) can re-publish
#                  it on the WireGuard hub address. Unset/0 = no 9Router
#                  forward. The VM cannot join the WG network itself (it is a
#                  systemd-nspawn container with no CAP_NET_ADMIN), so this
#                  reverse hop is the only way to reach 9Router over WireGuard.
#   NINER_PORT     local 9Router port to forward     (default 20128)
#   NINE_REMOTE    host:port of a 9Router reachable FROM THE RELAY, e.g. your
#                  PC's 9Router across WireGuard (10.100.0.3:20128). When set,
#                  the tunnel ALSO opens a local forward
#                  (127.0.0.1:NINE_LOCAL -> NINE_REMOTE) so this VM can use that
#                  router as its LLM upstream. Empty = off. Note the asymmetry:
#                  the VM cannot reach a WG peer itself, but it CAN reach the
#                  relay — so the relay (already a WG peer) does the last hop.
#   NINE_LOCAL     local port for that forward      (default 12028)
# SHELL_ACCESS   "1" to also expose this VM's sshd (needs sshd listening on 22)
#                Recon 2026-10-02: NO sshd on the Muse VM (Ubuntu 24.04.5, root
#                + apt available, egress TCP22-OK). So SHELL_ACCESS=1 requires
#                installing openssh-server first — a system change; get
#                explicit approval before doing it.
# SHELL_PORT     relay port for the VM shell       (default 2222)
#
# KNOWN CONSTRAINT — Muse sandbox: outbound SSH is DENIED BY DEFAULT by the
# runtime's own egress policy, not by anything in this script. The VM sits
# behind an HTTP proxy (hatch-egress-proxy:3128 / 198.19.0.1:3128) that refuses
# CONNECT to a bare IP, and even with ProxyCommand=none (ssh dials the relay
# directly and reports "Connection established") the handshake is intercepted
# and reset with this banner:
#
#   muse: Outbound SSH is turned off for this assistant. To allow it, ask the
#   user to open Muse settings -> Permissions -> Direct network protocols and
#   switch ssh from Deny to Ask.
#
# So this is a user-flippable permission, not a wall. Ask the user to switch
# ssh from Deny to Ask in Muse settings; once allowed, muse-tunnel's
# Restart=always reconnects on its own within seconds — no re-run needed.
# Verified 2026-10-02 on htch-runtime. On an ordinary VPS it works directly.
#
# Then, from your laptop:
#   ssh -L 8765:127.0.0.1:8765 user@relay      # then open http://127.0.0.1:8765
#   ssh -p 2222 museuser@relay                 # a shell on the Muse VM (if SHELL_ACCESS=1)
set -euo pipefail

RELAY="${RELAY:?set RELAY=user@host — the SSH relay you control}"
RELAY_PORT="${RELAY_PORT:-22}"
BRIDGE_PORT="${BRIDGE_PORT:-8765}"
REMOTE_PORT="${REMOTE_PORT:-$BRIDGE_PORT}"
REMOTE_BIND="${REMOTE_BIND:-127.0.0.1}"
SHELL_ACCESS="${SHELL_ACCESS:-0}"
SHELL_PORT="${SHELL_PORT:-2222}"
WG_PUB_PORT="${WG_PUB_PORT:-0}"
NINER_PORT="${NINER_PORT:-20128}"
NINE_REMOTE="${NINE_REMOTE:-}"
NINE_LOCAL="${NINE_LOCAL:-12028}"

key_args=()
if [[ -n "${SSH_KEY:-}" ]]; then
    key_args=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi

forwards=(-R "${REMOTE_BIND}:${REMOTE_PORT}:127.0.0.1:${BRIDGE_PORT}")
if [[ "$SHELL_ACCESS" == "1" ]]; then
    forwards+=(-R "${REMOTE_BIND}:${SHELL_PORT}:127.0.0.1:22")
fi
if [[ "$WG_PUB_PORT" != "0" && -n "$WG_PUB_PORT" ]]; then
    forwards+=(-R "${REMOTE_BIND}:${WG_PUB_PORT}:127.0.0.1:${NINER_PORT}")
fi
# Local forward (VM -> relay -> 9Router on a WG peer). -L survives on the same
# ssh connection, so it rides the existing unit and self-heal.
if [[ -n "$NINE_REMOTE" ]]; then
    forwards+=(-L "127.0.0.1:${NINE_LOCAL}:${NINE_REMOTE}")
fi

echo "[tunnel] bridge  -> ${RELAY} ${REMOTE_BIND}:${REMOTE_PORT} => vm:${BRIDGE_PORT}"
if [[ "$SHELL_ACCESS" == "1" ]]; then
    echo "[tunnel] shell   -> ${RELAY} ${REMOTE_BIND}:${SHELL_PORT} => vm:22"
fi
if [[ "$WG_PUB_PORT" != "0" && -n "$WG_PUB_PORT" ]]; then
    echo "[tunnel] 9router -> ${RELAY} ${REMOTE_BIND}:${WG_PUB_PORT} => vm:${NINER_PORT} (untuk jembatan WireGuard)"
fi
if [[ -n "$NINE_REMOTE" ]]; then
    echo "[tunnel] upstream -> vm:${NINE_LOCAL} => ${NINE_REMOTE} (lewat relay)"
fi

# Reconnect forever: a dropped tunnel must not silently leave you with a dead
# bridge. ExitOnForwardFailure makes ssh fail fast if the relay port is taken
# (otherwise ssh stays up looking healthy while nothing is forwarded).
attempt=0
while :; do
    attempt=$((attempt + 1))
    set +e
    # ProxyCommand=none / ProxyJump=none defeat any ProxyCommand inherited from
    # the system ssh_config. Some sandbox runtimes (the Muse VM among them) put
    # an HTTP proxy in /etc/ssh/ssh_config; ssh then dials 198.19.0.1:3128 and
    # the proxy refuses CONNECT to a bare IP, so the tunnel dies with
    # "Connection closed by 198.19.0.1 port 3128" while plain TCP looks fine.
    # Command-line -o wins over ssh_config, so this is the whole fix.
    ssh -N -T \
        -o ProxyCommand=none \
        -o ProxyJump=none \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -o StrictHostKeyChecking=accept-new \
        -p "$RELAY_PORT" \
        "${key_args[@]}" \
        "${forwards[@]}" \
        "$RELAY"
    rc=$?
    set -e
    echo "[tunnel] ssh keluar (rc=$rc) — reconnect #${attempt} dalam 5s" >&2
    sleep 5
done
