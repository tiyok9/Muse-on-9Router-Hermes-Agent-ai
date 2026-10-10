#!/usr/bin/env python
"""Perbaiki model Muse Spark di 9Router PC — idempotent.

AKAR MASALAH (terbukti 2026-10-10):
  Node PC "Muse (Spark asli)" prefix=`musespark`, baseUrl -> relay VM.
  9Router PC men-strip SATU level prefix `musespark` sebelum forward ke relay.

  * Model LANGSUNG `musespark/muse-spark-1.3` (yang dipakai UI PC)
      -> relay menerima `muse-spark-1.3` -> 404
      -> `503 No active credentials for provider: openai`
      + `modelLock_muse-spark-1.3`.
  * Varian `musespark/oc/...` (slash) juga gagal: setelah strip prefix,
    relay menerima `oc/...` yang bertabrakan dengan ALIAS BAWAAN `oc`
    (opencode) -> 503.

PERBAIKAN (dua sisi):
  A. RELAY (9Router VM, 127.0.0.1:20128): tambah combo yang mengekspos
     ID bare `muse-spark-1.3` -> `musespark/muse-spark-1.3`, sehingga
     PC cukup memakai `musespark/muse-spark-1.3` (satu level prefix).
     Jalankan `--relay` di VM untuk ini.
  B. PC: buang customModel node musespark yang memakai id ber-slash
     (`oc/...`) karena bentrok alias bawaan; sisakan varian hyphen
     (`oc-muse-spark-1.x-contributor-free`) yang resolve 200.

Cara: API manajemen resmi 9Router (bukan tulis DB langsung).
    DELETE /api/models/custom?providerAlias=&id=&type=llm
    POST   /api/models/custom   body {providerAlias,id,type,name}
    header x-9r-cli-token = sha256(machineId + "9r-cli-auth" + cliSecret)[:16]

Backup DB dibuat lebih dulu. Idempotent: yang sudah benar dilewati.
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
import urllib.parse
import urllib.request

R = os.path.join(os.environ.get("APPDATA", ""), "9router")
DB = os.path.join(R, "db", "data.sqlite")
BASE = "http://localhost:20128"

# id customModel yang WAJIB ADA (bentuk hyphen, tidak bentrok alias bawaan)
WANT_HYPHEN = [
    "oc-muse-spark-1.3-contributor-free",
    "oc-muse-spark-1.2-contributor-free",
]
# id customModel yang rusak (bentrok alias bawaan `oc`)
BAD_SLASH = [
    "oc/muse-spark-1.3-contributor-free",
    "oc/muse-spark-1.2-contributor-free",
]


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


def _musespark_node() -> str | None:
    con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    try:
        for nid, data in con.execute("SELECT id, data FROM providerNodes"):
            try:
                pfx = json.loads(data or "{}").get("prefix")
            except Exception:
                pfx = None
            if pfx == "musespark":
                return nid
    finally:
        con.close()
    return None


def main() -> int:
    ts = time.strftime("%Y%m%dT%H%M%S")
    bak = DB + ".bak.musemodels." + ts
    shutil.copy2(DB, bak)
    print("BACKUP DB: %s" % os.path.basename(bak))

    node = _musespark_node()
    if not node:
        print("FATAL: node prefix 'musespark' tidak ditemukan")
        return 2
    print("NODE musespark: %s" % node)

    _s, j = _api("GET", "/api/models/custom")
    have = {
        m.get("id")
        for m in (j or {}).get("models", [])
        if m.get("providerAlias") == node
    }
    rc = 0

    # 1) buang id ber-slash yang bentrok alias bawaan
    for bad in BAD_SLASH:
        if bad not in have:
            print("OK    sudah bersih: %s" % bad)
            continue
        q = urllib.parse.urlencode({"providerAlias": node, "id": bad, "type": "llm"})
        st, _b = _api("DELETE", "/api/models/custom?" + q)
        print("%-5s hapus %s -> %s" % ("DEL" if st == 200 else "FAIL", bad, st))
        rc |= 0 if st == 200 else 1

    # 2) pastikan varian hyphen ada
    for good in WANT_HYPHEN:
        if good in have:
            print("OK    sudah ada: %s" % good)
            continue
        st, _b = _api("POST", "/api/models/custom",
                      {"providerAlias": node, "id": good, "type": "llm", "name": good})
        print("%-5s tambah %s -> %s" % ("ADD" if st == 200 else "FAIL", good, st))
        rc |= 0 if st == 200 else 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
