#!/usr/bin/env python
"""Perbaiki combo 9Router PC: `agnes` (404) & `muse` (503) — idempotent.

Akar masalah (terbukti 2026-10-10):
  * combo `agnes` memakai model-ID `agnes/agnes-3.0-flash`, padahal TIDAK ada
    provider bernama `agnes` → "No active credentials for provider: agnes".
    Model-ID yang resolve: <node-anthropic-compatible>/agnes-3.0-flash.
  * combo `muse` memakai `muse-spark-1.3`; node PC `musespark` meneruskan ke
    9Router VM yang SUDAH ber-prefix `musespark` → prefix ter-strip DUA KALI
    → 503. Model-ID yang resolve: musespark/musespark/muse-spark-1.3.

Cara: API manajemen resmi 9Router (bukan tulis DB langsung):
    PUT http://localhost:20128/api/combos/{id}   body {name, models, kind}
    header x-9r-cli-token = sha256(machineId + "9r-cli-auth" + cliSecret)[:16]

Backup DB dibuat lebih dulu. Idempotent: combo yang sudah benar dilewati.
Kredensial dibaca dari file lokal 9Router, tidak pernah dicetak.
"""
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import time
import urllib.error
import urllib.request

R = os.path.join(os.environ.get("APPDATA", ""), "9router")
DB = os.path.join(R, "db", "data.sqlite")
BASE = "http://localhost:20128"


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
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode()
        return resp.status, (json.loads(raw) if raw else None)


def _combos():
    _s, j = _api("GET", "/api/combos")
    return j.get("combos", j) if isinstance(j, dict) else j


def main() -> int:
    # --- backup DB ---
    ts = time.strftime("%Y%m%dT%H%M%S")
    bak = DB + ".bak.combofix." + ts
    shutil.copy2(DB, bak)
    print("BACKUP DB: %s" % os.path.basename(bak))

    # --- temukan node id yang benar dari DB ---
    con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    nodes = {}
    for nid, name, data in con.execute("SELECT id, name, data FROM providerNodes"):
        try:
            pfx = json.loads(data or "{}").get("prefix")
        except Exception:
            pfx = None
        nodes[name] = (nid, pfx)
    agnes_node = nodes.get("agnes", (None, None))[0]
    muses_node = nodes.get("Muse (Spark asli)", (None, None))[0]
    con.close()
    if not agnes_node or not muses_node:
        print("FATAL: node 'agnes'/'Muse (Spark asli)' tidak ditemukan")
        return 2

    # Aturan perbaikan: pastikan bentuk model-ID yang RESOLVE ada di daftar,
    # buang alias rusak, dan JANGAN buang model lain yang sudah benar.
    #   * agnes : `agnes/agnes-3.0-flash` (provider `agnes` tak ada) -> node-id penuh
    #   * muse  : `muse-spark-1.3` (double-strip prefix) -> node/musespark/...
    fixes = {
        "agnes": (
            "%s/agnes-3.0-flash" % agnes_node,
            {"agnes/agnes-3.0-flash", "agnes/agnes-2.5-flash"},
        ),
        "muse": (
            "musespark/musespark/muse-spark-1.3",
            {
                "muse-spark-1.3",
                "musespark/muse-spark-1.3",
                "%s/musespark/muse-spark-1.3" % muses_node,
            },
        ),
    }

    combos = _combos()
    by_name = {c.get("name"): c for c in combos}
    rc = 0
    for name, (good, broken) in fixes.items():
        c = by_name.get(name)
        if not c:
            print("SKIP  combo '%s' tidak ada" % name)
            rc = 1
            continue
        cur = list(c.get("models") or [])
        new = [m for m in cur if m not in broken]
        if good not in new:
            new.insert(0, good)
        if new == cur:
            print("OK    combo '%s' sudah benar" % name)
            continue
        _api("PUT", "/api/combos/%s" % c["id"],
             {"name": name, "models": new, "kind": c.get("kind", "chat")})
        print("PATCH combo '%s' -> %s" % (name, new))
    return rc


if __name__ == "__main__":
    sys.exit(main())
