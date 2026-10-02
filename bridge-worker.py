#!/usr/bin/env python3
"""Muse bridge worker v1 — pull jobs from the Muse bridge, answer them, done.

Tailscale-friendly by design: every call this script makes is OUTBOUND
(GET /muse/pending, POST /muse/answer, POST /muse/release), so the machine
running the worker needs no inbound port, no public IP and no SSH tunnel.
Point BRIDGE_URL at the bridge's Tailscale IP and the two sides find each
other on the tailnet.

Modes
-----
  --once    poll once, answer whatever is pending, exit   (cron / Task Scheduler)
  --loop    poll forever with a short sleep                (systemd / service)

Upstream (who actually composes the answer)
-------------------------------------------
  none                 placeholder echo — smoke test only
  hermes               run the local Hermes CLI:  hermes -z "<prompt>"
  http://host:port/v1  any OpenAI-compatible /chat/completions endpoint

Env (CLI flags win over env)
----------------------------
  BRIDGE_URL          base URL of the bridge    (default http://127.0.0.1:8765)
  BRIDGE_WORKER_KEY   worker-role key           (REQUIRED)
  WORKER_LABEL        name recorded in leases   (default: hostname)
  UPSTREAM            none | hermes | <base url>    (default: none)
  UPSTREAM_KEY        bearer key for the upstream   (if it needs one)
  UPSTREAM_MODEL      model name for the upstream   (default: muse)
  POLL_INTERVAL       seconds between polls     (default: 3)
  REQUEST_TIMEOUT     seconds per upstream call (default: 120)
  WATCH_DIR           optional <queue>/pending dir for instant wake-up
  HERMES_BIN          path to the hermes CLI    (default: found on PATH)

Silence policy: the worker prints nothing while idle. It only logs when it
picks up a job, when a job fails, or when the bridge is unreachable / rejects
the key — so it is safe to run as a chatty-free service.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from urllib.parse import urlparse


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


# --------------------------------------------------------------- http ---
def _req(url: str, key: str, method: str = "GET", payload=None, timeout: int = 30):
    """Minimal JSON request helper (stdlib only)."""
    headers = {"Accept": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", "replace") or "{}"
    return json.loads(body)


# -------------------------------------------------------------- prompt ---
def messages_to_prompt(request) -> str:
    """Flatten an OpenAI-style messages[] into one prompt string."""
    if isinstance(request, str):
        return request
    msgs = (request or {}).get("messages") or []
    if isinstance(msgs, str):
        return msgs
    out = []
    for m in msgs:
        if not isinstance(m, dict):
            continue
        role = m.get("role", "user")
        content = m.get("content", "")
        if isinstance(content, list):  # multimodal-style content blocks
            content = "".join(
                p.get("text", "") for p in content if isinstance(p, dict)
            )
        content = str(content).strip()
        if not content:
            continue
        label = {"system": "System", "assistant": "Assistant"}.get(role, "User")
        out.append(f"{label}: {content}")
    return "\n\n".join(out) or "(empty request)"


# ----------------------------------------------------------- upstream ---
def ask_none(prompt: str, cfg: dict) -> str:
    return (f"[worker:{cfg['label']}] bridge aktif, upstream belum di-set. "
            f"Diterima: {prompt[:400]}")


def ask_hermes(prompt: str, cfg: dict) -> str:
    exe = cfg["hermes_bin"] or shutil.which("hermes")
    if not exe:
        raise RuntimeError("hermes CLI tidak ditemukan (set HERMES_BIN)")
    proc = subprocess.run(
        [exe, "-z", prompt],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=cfg["timeout"],
    )
    if proc.returncode != 0:
        raise RuntimeError(f"hermes exit {proc.returncode}: "
                           f"{(proc.stderr or '').strip()[:300]}")
    text = (proc.stdout or "").strip()
    if not text:
        raise RuntimeError("hermes mengembalikan output kosong")
    return text


def ask_openai(prompt: str, cfg: dict) -> str:
    base = cfg["upstream"].rstrip("/")
    url = base if base.endswith("/chat/completions") else base + "/chat/completions"
    body = {"model": cfg["model"], "stream": False,
            "messages": [{"role": "user", "content": prompt}]}
    res = _req(url, cfg["upstream_key"], "POST", body, timeout=cfg["timeout"])
    choices = res.get("choices") or [{}]
    ch = choices[0] or {}
    text = (ch.get("message") or {}).get("content") or ch.get("text") or ""
    if isinstance(text, list):
        text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
    text = str(text).strip()
    if not text:
        raise RuntimeError(f"upstream mengembalikan jawaban kosong: {str(res)[:200]}")
    return text


def make_answer(prompt: str, cfg: dict) -> str:
    up = (cfg["upstream"] or "none").strip()
    if up in ("", "none"):
        return ask_none(prompt, cfg)
    if up == "hermes":
        return ask_hermes(prompt, cfg)
    return ask_openai(prompt, cfg)


# --------------------------------------------------------------- loop ---
def _snapshot(d: str):
    try:
        return {f for f in os.listdir(d) if f.endswith(".json")}
    except Exception:
        return set()


def run_once(cfg: dict) -> int:
    """Claim and answer pending jobs. Returns how many were answered."""
    data = _req(f"{cfg['bridge']}/muse/pending?limit={cfg['limit']}",
                cfg["worker_key"], timeout=30)
    jobs = data.get("jobs") or []
    if not jobs:
        return 0

    answered = 0
    for job in jobs:
        jid = str(job.get("id") or "")
        if not jid:
            continue
        prompt = messages_to_prompt(job.get("request"))
        head = prompt.splitlines()[0][:70] if prompt else ""
        log(f"job {jid[:12]}… diambil  <- {head}")

        try:
            answer = make_answer(prompt, cfg)
        except Exception as exc:
            log(f"job {jid[:12]}… GAGAL ({exc}) — lease dilepas kembali")
            try:
                _req(f"{cfg['bridge']}/muse/release", cfg["worker_key"],
                     "POST", {"id": jid}, timeout=20)
            except Exception as exc2:
                log(f"release gagal: {exc2}")
            continue

        try:
            res = _req(f"{cfg['bridge']}/muse/answer", cfg["worker_key"],
                       "POST", {"id": jid, "content": answer}, timeout=30)
            dup = " (duplikat)" if res.get("duplicate") else ""
            log(f"job {jid[:12]}… dijawab -> {len(answer)} char{dup}")
            answered += 1
        except Exception as exc:
            log(f"job {jid[:12]}… gagal kirim jawaban: {exc}")
    return answered


def _check_not_self_loop(bridge: str, upstream: str) -> None:
    """Refuse to point the worker at the bridge itself (infinite loop)."""
    if not upstream or upstream in ("none", "hermes"):
        return
    try:
        a, b = urlparse(bridge), urlparse(upstream)
        pa = a.port or (443 if a.scheme == "https" else 80)
        pb = b.port or (443 if b.scheme == "https" else 80)
        if a.hostname == b.hostname and pa == pb:
            raise SystemExit(
                f"FATAL: UPSTREAM ({upstream}) menunjuk ke bridge itu sendiri "
                f"({bridge}) — ini akan membuat loop tanpa akhir. "
                f"Pakai UPSTREAM=hermes atau base URL model lain."
            )
    except SystemExit:
        raise
    except Exception:
        pass


def build_cfg(args) -> dict:
    env = os.environ.get
    bridge = (args.bridge or env("BRIDGE_URL") or "http://127.0.0.1:8765").rstrip("/")
    worker_key = args.key or env("BRIDGE_WORKER_KEY") or ""
    if not worker_key:
        raise SystemExit(
            "FATAL: BRIDGE_WORKER_KEY belum di-set.\n"
            "Buat dengan:  python bridge.py keygen --role worker --label "
            f"{socket.gethostname()}"
        )
    upstream = (args.upstream or env("UPSTREAM") or "none").strip()
    cfg = {
        "bridge": bridge,
        "worker_key": worker_key,
        "label": args.label or env("WORKER_LABEL") or socket.gethostname(),
        "upstream": upstream,
        "upstream_key": args.upstream_key or env("UPSTREAM_KEY") or "",
        "model": args.model or env("UPSTREAM_MODEL") or "muse",
        "interval": int(args.interval or env("POLL_INTERVAL") or 3),
        "timeout": int(args.timeout or env("REQUEST_TIMEOUT") or 120),
        "limit": max(1, min(10, int(args.limit or 3))),
        "watch_dir": args.watch_dir or env("WATCH_DIR") or "",
        "hermes_bin": args.hermes_bin or env("HERMES_BIN") or "",
    }
    _check_not_self_loop(cfg["bridge"], cfg["upstream"])
    return cfg


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="bridge-worker.py",
        description="Muse bridge worker — pull /muse/pending, answer, repeat.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true",
                      help="poll once, answer, exit (cron / Task Scheduler)")
    mode.add_argument("--loop", action="store_true",
                      help="poll forever (default; systemd / service)")
    ap.add_argument("--bridge", help="bridge base URL")
    ap.add_argument("--key", help="worker-role key")
    ap.add_argument("--label", help="worker label shown in leases")
    ap.add_argument("--upstream", help="none | hermes | http://host:port/v1")
    ap.add_argument("--upstream-key", dest="upstream_key", help="upstream bearer key")
    ap.add_argument("--model", help="upstream model name")
    ap.add_argument("--interval", type=int, help="seconds between polls")
    ap.add_argument("--timeout", type=int, help="seconds per upstream call")
    ap.add_argument("--limit", type=int, help="max jobs per poll (1-10)")
    ap.add_argument("--watch-dir", dest="watch_dir",
                    help="<queue>/pending dir for instant wake-up")
    ap.add_argument("--hermes-bin", dest="hermes_bin", help="path to hermes CLI")
    args = ap.parse_args()

    cfg = build_cfg(args)

    if args.once:
        try:
            run_once(cfg)
        except urllib.error.HTTPError as exc:
            hint = " (worker key salah?)" if exc.code == 401 else ""
            log(f"bridge HTTP {exc.code}{hint}")
            return 1
        except Exception as exc:
            log(f"bridge tidak terjangkau: {exc}")
            return 1
        return 0

    log(f"worker '{cfg['label']}' -> {cfg['bridge']} | upstream={cfg['upstream']} "
        f"| poll={cfg['interval']}s"
        + (f" | watch={cfg['watch_dir']}" if cfg["watch_dir"] else ""))

    prev = _snapshot(cfg["watch_dir"]) if cfg["watch_dir"] else set()
    last_err = ""
    try:
        while True:
            try:
                run_once(cfg)
                last_err = ""
            except urllib.error.HTTPError as exc:
                hint = " (worker key salah?)" if exc.code == 401 else ""
                msg = f"bridge HTTP {exc.code}{hint}"
                if msg != last_err:
                    log(msg)
                    last_err = msg
            except Exception as exc:
                msg = f"bridge tidak terjangkau: {exc}"
                if msg != last_err:
                    log(msg)
                    last_err = msg

            if not cfg["watch_dir"]:
                time.sleep(cfg["interval"])
                continue

            # fast wake: sleep 1s at a time, bail out early on a new job file
            for _ in range(max(1, cfg["interval"])):
                time.sleep(1)
                cur = _snapshot(cfg["watch_dir"])
                if cur - prev:
                    prev = cur
                    break
                prev = cur
    except KeyboardInterrupt:
        log("worker dihentikan")
        return 0


if __name__ == "__main__":
    sys.exit(main())
