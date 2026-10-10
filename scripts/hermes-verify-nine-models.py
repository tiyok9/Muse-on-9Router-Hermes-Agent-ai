#!/usr/bin/env python
"""Verifikasi model Muse di 9Router PC — re-runnable, read-only.

Menguji setiap model-ID Muse lewat endpoint chat 9Router PC dan memastikan
semuanya 200. Menangkap regresi "model langsung 503" / entri `oc/` rusak.

Jalankan di PC:  python scripts/hermes-verify-nine-models.py
Exit 0 = semua PASS.
"""
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

R = os.path.join(os.environ.get("APPDATA", ""), "9router")
DB = os.path.join(R, "db", "data.sqlite")
BASE = "http://127.0.0.1:20128"

# (label, model-id) yang WAJIB 200
CASES = [
    ("combo muse", "muse"),
    ("combo agnes", "agnes"),
    ("combo anti", "anti"),
    ("combo codebudy", "codebudy"),
    ("model langsung (UI PC)", "musespark/muse-spark-1.3"),
    ("musespark/muse", "musespark/muse"),
    ("musespark/muse-spark-1.2", "musespark/muse-spark-1.2"),
    ("oc 1.3 hyphen", "musespark/oc-muse-spark-1.3-contributor-free"),
    ("oc 1.2 hyphen", "musespark/oc-muse-spark-1.2-contributor-free"),
    ("combo muse double-prefix", "musespark/musespark/muse-spark-1.3"),
]


def _key() -> str:
    con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    try:
        return [r[0] for r in con.execute("SELECT key FROM apiKeys WHERE isActive=1")][0]
    finally:
        con.close()


def _call(key: str, model: str):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 5,
        "stream": False,
    }).encode()
    req = urllib.request.Request(
        BASE + "/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer %s" % key},
    )
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            r.read()
            return r.status, round(time.time() - t, 1), ""
    except urllib.error.HTTPError as e:
        return e.code, round(time.time() - t, 1), e.read()[:90].decode(errors="replace")
    except Exception as e:
        return "ERR", round(time.time() - t, 1), str(e)[:90]


def main() -> int:
    key = _key()
    npass = nfail = 0
    print("=" * 70)
    print("VERIFIKASI MODEL MUSE — 9Router PC (%s)" % BASE)
    print("=" * 70)
    for label, model in CASES:
        st, dt, msg = _call(key, model)
        ok = st == 200
        npass += ok
        nfail += not ok
        print("  %-4s %-26s %-46s HTTP=%-4s %ss %s"
              % ("PASS" if ok else "FAIL", label, model, st, dt, "" if ok else msg))

    # katalog bersih: tidak boleh ada entri `oc/` (bentrok alias bawaan)
    req = urllib.request.Request(BASE + "/v1/models",
                                headers={"Authorization": "Bearer %s" % key})
    ids = [m["id"] for m in json.load(urllib.request.urlopen(req, timeout=20)).get("data", [])]
    bad = [i for i in ids if "musespark/oc/" in i]
    npass += not bad
    nfail += bool(bad)
    print("  %-4s %-26s %s" % ("PASS" if not bad else "FAIL",
                               "katalog tanpa entri oc/",
                               "bersih" if not bad else "sisa: %s" % bad))

    print("=" * 70)
    print("HASIL: %d PASS, %d FAIL" % (npass, nfail))
    print("=" * 70)
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
