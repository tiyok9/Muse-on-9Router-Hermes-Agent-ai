#!/usr/bin/env python3
"""Perbaiki RELAY 9Router (VM) agar ID model Muse dari PC resolve — idempotent.

Dijalankan DI VM relay (127.0.0.1:20128), bukan di PC.

KONTEKS:
  Node PC "Muse (Spark asli)" prefix=`musespark` men-strip SATU level prefix
  sebelum forward ke relay ini. Jadi PC yang mengirim `musespark/muse-spark-1.3`
  tiba di relay sebagai `muse-spark-1.3` — ID yang tidak dikenal relay
  -> 404 -> PC balas `503 No active credentials for provider: openai`.

SOLUSI:
  Buat COMBO di relay yang NAMANYA sama dengan ID bare yang dikirim PC,
  memetakan ke model ber-prefix `musespark/...` yang relay memang layani.
  Idempotent: combo yang sudah benar dilewati.

Cara: API manajemen resmi 9Router.
    GET  /api/combos
    POST /api/combos            body {name, models, kind}
    PUT  /api/combos/{id}       body {name, models, kind}
    header x-9r-cli-token = sha256(machineId + "9r-cli-auth" + cliSecret)[:16]

Backup DB dibuat lebih dulu. Kredensial dibaca lokal, tidak dicetak.
"""
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request

def _find_router_dir() -> str:
    """Auto-deteksi direktori data 9Router relay (ssh bisa masuk sbg root)."""
    cands = [
        os.environ.get("NINE_ROUTER_HOME", ""),
        os.path.expanduser("~/.9router"),
        "/home/hatch/.9router",
        "/root/.9router",
    ]
    for c in cands:
        if c and os.path.exists(os.path.join(c, "db", "data.sqlite")):
            return c
    return os.path.expanduser("~/.9router")


R = _find_router_dir()
DB = os.path.join(R, "db", "data.sqlite")
BASE = "http://127.0.0.1:20128"

# nama-combo (ID bare yang dikirim PC) -> model relay yang valid
WANT = {
    "muse-spark-1.3": ["musespark/muse-spark-1.3"],
    "muse-spark-1.2": ["musespark/muse-spark-1.2"],
    "oc-muse-spark-1.3-contributor-free": [
        "musespark/oc-muse-spark-1.3-contributor-free"
    ],
    "oc-muse-spark-1.2-contributor-free": [
        "musespark/oc-muse-spark-1.2-contributor-free"
    ],
}


def _token() -> str:
    mid = open(os.path.join(R, "machine-id")).read().strip()
    cs = open(os.path.join(R, "auth", "cli-secret")).read().strip()
    return hashlib.sha256((mid + "9r-cli-auth" + cs).encode()).hexdigest()[:16]


def _api(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("x-9r-cli-token", _token())
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw


def main() -> int:
    ts = time.strftime("%Y%m%dT%H%M%S")
    bak = DB + ".bak.relaymuse." + ts
    shutil.copy2(DB, bak)
    print("BACKUP DB: %s" % os.path.basename(bak))

    _s, j = _api("GET", "/api/combos")
    combos = (j or {}).get("combos", []) if isinstance(j, dict) else (j or [])
    by_name = {c.get("name"): c for c in combos}
    rc = 0
    for name, models in WANT.items():
        c = by_name.get(name)
        if c and list(c.get("models") or []) == models:
            print("OK    combo '%s' sudah benar" % name)
            continue
        if c:
            st, _b = _api("PUT", "/api/combos/%s" % c["id"],
                          {"name": name, "models": models, "kind": c.get("kind") or "chat"})
            print("%-5s ubah  combo '%s' -> %s" % ("PUT" if st == 200 else "FAIL", name, st))
        else:
            st, _b = _api("POST", "/api/combos",
                          {"name": name, "models": models, "kind": "chat"})
            print("%-5s buat  combo '%s' -> %s" % ("ADD" if st == 200 else "FAIL", name, st))
        rc |= 0 if st == 200 else 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
