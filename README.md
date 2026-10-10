# Muse Bridge for 9Router + Hermes inside the Muse VM

[![Python](https://img.shields.io/badge/python-3.8%2B-blue.svg)](https://www.python.org/)
[![9Router](https://img.shields.io/badge/9Router-provider-brightgreen.svg)](https://github.com/)

**Muse Bridge** runs **9Router + Hermes inside the Muse VM** and provides a bridge for integrating Muse with **Telegram, Discord, and WhatsApp bots**. Your bots can send messages to the Muse environment and receive AI-generated responses through the bridge, without exposing inbound ports, setting up SSH tunnels, or requiring a public domain.

## How it works

```
 ┌──────────┐   POST /v1/chat/completions    ┌──────────┐  queue as file   ┌────────┐
 │ 9Router  │  ──────────────────────────▶   │ bridge.py│ ───────────────▶ │ worker │
 │ :20128   │   (key role=user)               │  :8765   │  GET /muse/      │ (Muse) │
 └────▲─────┘                                │          │ ◀─────────────── │        │
      │        OpenAI-compatible              └────▲─────┘  pending/answer  └────────┘
      │        /v1/* API                           │       (key role=worker)
 ┌────┴─────┐      ┌──────────────┐                │  answer flows back,
 │  Hermes  │      │ Telegram /   │                │  client long-polls
 │  agent   │◀────▶│ Discord / WA │◀───────────────┘  up to 4 minutes
 └──────────┘      │ bot (gateway)│
                   └──────────────┘
```

1. A client (9Router, Hermes CLI, or a chat bot) sends a standard **OpenAI chat-completions request** to the bridge with the model name `muse`.
2. The bridge **queues the request as a JSON file** and holds the HTTP connection (long-poll, up to ~4 minutes).
3. A **worker** (any agent able to answer as Muse — in the reference setup, a scheduled Muse task) polls `GET /muse/pending`, picks up the job with an atomic lease, composes a reply, and posts it to `POST /muse/answer`.
4. The bridge delivers the reply to the waiting client as a normal OpenAI-style response.

Because the worker **pulls** jobs outbound, the bridge never needs inbound connectivity from the worker's network — it works behind NAT, and over Tailscale or any tunnel for remote setups.

---

## Muse Spark as a real provider (no login, no cost)

The bridge above works with *any* agent answering as Muse. But the Muse VM itself
already runs the **real Muse runtime** (`hatch`), which owns a local inference
socket:

```
/run/hatch/sandbox/space-inference.sock   # length-prefixed JSON frames
```

That socket serves the user's **genuine Muse Spark** model — no Meta login, no
OAuth, no API key, no billing. `scripts/muse_spark_shim.py` translates it into a
plain OpenAI endpoint (`http://127.0.0.1:8766/v1`) so 9Router can use it as a
normal provider:

```
[PC] 9Router  combo `muse`
  -> node `musespark`  http://10.100.0.1:22028/v1   (9Router VM, via WireGuard)
  -> [VM] 9Router      http://127.0.0.1:8766/v1
  -> shim              muse-spark-shim.service
  -> /run/hatch/sandbox/space-inference.sock
  -> Muse Spark (Meta)  ← the user's real Muse AI
```

Install inside the Muse VM (idempotent, survives reboot):

```bash
scp scripts/{muse_spark_shim.py,muse-spark-shim.service,install-muse-spark-shim.sh} musevm:/tmp/
ssh musevm 'sudo bash /tmp/install-muse-spark-shim.sh'
```

Then point the 9Router PC at it (key is read from `MUSE_VM_KEY`, never stored):

```bash
MUSE_VM_KEY=<9Router-VM-key> python scripts/nine-router-muse-spark.py
```

Verify: `curl :20128/v1/chat/completions -d '{"model":"muse",...}'` must answer
with `"model":"Muse Spark"`.

## Self-provisioning (survives a VM swap)

The Muse VM is **ephemeral** — it gets swapped or restarted at will, and 9Router,
the bridge, the keys and the worker all live inside it. So the recipe lives
**outside** the VM, in this repo, and a brand-new VM rebuilds the whole stack
from one command:

```bash
curl -fsSL https://raw.githubusercontent.com/tiyok9/Muse-on-9Router-Hermes-Agent-ai/main/muse-bootstrap.sh | bash
```

That single script is idempotent — every step first asks "is this already done?"
and skips if so. Re-run it any time; a healthy stack reports *no changes*.

| Case | What recovers it |
|------|------------------|
| Service died, key file lost, VM rebooted (disk intact) | `muse-bootstrap.timer` re-runs the script every 5 min |
| VM **replaced** (fresh disk) | paste the one-liner above into the new VM's chat |
| Want the *same* keys on the new VM | point `MUSE_KEYS_FROM` at a `keys.pin` you keep outside the VM |

```bash
# a fresh VM that must keep the SAME identity (no external reconfig needed)
MUSE_KEYS_FROM=ubuntu@your-relay:/home/ubuntu/muse-keys.pin \
  bash <(curl -fsSL .../muse-bootstrap.sh)
```

Nothing inside an ephemeral VM can survive its own wipe — the timer covers the
reboot case, the one-liner covers the swap case. `VM-BARU.txt` is the paste-ready
prompt for that swap.

### Env knobs

| Var | Default | Purpose |
|-----|---------|---------|
| `MUSE_REPO_SLUG` | `tiyok9/Muse-on-9Router-Hermes-Agent-ai` | which repo to fetch from |
| `MUSE_REPO_BRANCH` | `main` | branch to resolve to a commit SHA |
| `MUSE_REPO_RAW` | — | force a raw base URL (skips SHA resolution) |
| `MUSE_BRIDGE_DIR` | `$HOME/muse-bridge` | install location |
| `MUSE_UPSTREAM` | `none` | `none` \| `hermes` \| OpenAI-compatible base URL |
| `MUSE_KEYS_FROM` | — | `user@host:/path` to pull pinned keys over SSH |
| `MUSE_WORKER_KEY` / `MUSE_USER_KEY` | — | pin the key strings directly |
| `MUSE_RELAY` | — | `user@host`; enables the `ssh -R` reverse tunnel |
| `MUSE_NO_TIMER` | `0` | `1` disables the 5-minute self-heal timer |

> **Cache note.** `raw.githubusercontent.com` serves branch URLs through a CDN
> with `Cache-Control: max-age=300`, so a branch URL can hand back a copy that is
> up to 5 minutes stale after a push. The script resolves `main` to a commit SHA
> and fetches by SHA (immutable, not cached that way), falling back to the branch
> URL only if the GitHub API is unreachable. If you push a fix and re-run within
> 5 minutes, the SHA path is what keeps you from silently re-running the old one.

---

## Features

- **OpenAI-compatible** `/v1/chat/completions` and `/v1/models` — drop-in for 9Router providers, Hermes custom models, or any OpenAI client.
- **File-based queue** with atomic worker leases (default 3 min), automatic lease expiry, crash recovery, and duplicate-answer detection.
- **Role-based API keys** (`user` / `worker`), plus legacy `BRIDGE_TOKEN` support.
- **Zero dependencies** — pure Python standard library. No `pip install` needed.

---

## Repository contents

| File | Purpose |
|------|---------|
| `bridge.py` | The bridge (v5.1). Upload it when u paste prompt. |
| `PROMPT.md` | Prompting to Muse.ai |
| `muse-bootstrap.sh` | Idempotent self-provisioning setup for a fresh/ephemeral VM. |
| `bridge-worker.py` | Pull-based worker (`--once` / `--loop`). |
| `muse-ssh-tunnel.sh` | `ssh -R` reverse tunnel so the VM's bridge is reachable. |
| `VM-BARU.txt` | Paste-ready prompt for a swapped VM. |

---

## Requirements

- **Bridge:** Python 3.8+ (standard library only).
- **9Router:** Node.js + npm (installed via `npm i -g 9router` or a local prefix).
- **Hermes:** the Hermes Agent CLI.
- **Bots:** a bot token (Telegram via BotFather, Discord via the Developer Portal, …) for the Hermes gateway.

---

## Quick start

### Option A — everything on one Linux VPS

This is the reference deployment: 9Router, bridge, worker, Hermes, and a Telegram bot all on the same machine.

**1. Install 9Router and run it as a service**

```bash
npm install -g 9router          # or use a persistent prefix like ~/.npm-global
sudo tee /etc/systemd/system/9router.service > /dev/null <<'EOF'
[Unit]
Description=9Router
After=network.target
[Service]
ExecStart=/home/<user>/.npm-global/bin/9router serve --port 20128 --host 127.0.0.1
Restart=always
User=<user>
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now 9router
```

Grab the 9Router API key from its first-run output (or config) and back it up with `chmod 600`.

**2. Run the bridge as a service**

```bash
mkdir -p ~/muse-bridge && cp bridge.py ~/muse-bridge/
sudo tee /etc/systemd/system/muse-bridge.service > /dev/null <<'EOF'
[Unit]
Description=Muse bridge for 9Router
After=network.target
[Service]
ExecStart=/usr/bin/python3 /home/<user>/muse-bridge/bridge.py serve
Restart=always
User=<user>
Environment=BRIDGE_QUEUE=/home/<user>/muse-bridge/queue
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now muse-bridge
curl -s http://127.0.0.1:8765/health   # -> {"ok": true}
```

**3. Install Hermes and point it at 9Router**

```yaml
# ~/.hermes/config.yaml
model:
  provider: custom
  base_url: http://127.0.0.1:20128/v1
  default: muse
```


**7. (Optional) Add a chat bot** — Telegram, Discord, or WhatsApp via the Hermes gateway.
Which one is up to you; the gateway handles the platform, the model chain stays
the same (bot → Hermes → 9Router → bridge → worker).

Example for Telegram:

```bash
# ~/.hermes/.env  (chmod 600)
TELEGRAM_BOT_TOKEN=<token from @BotFather>
TELEGRAM_ALLOWED_USERS=<your numeric Telegram user id>
```
