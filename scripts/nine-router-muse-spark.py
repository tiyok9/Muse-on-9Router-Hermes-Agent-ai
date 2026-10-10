#!/usr/bin/env python3
"""Sambungkan 9Router PC ke Muse Spark ASLI lewat 9Router VM Muse.

Arsitektur (tanpa login, tanpa biaya):

    [PC] 9Router  combo `muse`
      -> node `musespark`  (baseUrl http://10.100.0.1:22028/v1 , kunci VM)
      -> [VM Muse] 9Router  node `musespark` (baseUrl http://127.0.0.1:8766/v1)
      -> shim OpenAI        (muse-spark-shim.py, systemd unit)
      -> /run/hatch/sandbox/space-inference.sock
      -> Muse Spark (Meta)  <- model Muse AI milik user, asli

VM Muse tidak bisa menerima koneksi masuk; 9Router VM sudah dipublish relay ke
WireGuard hub `10.100.0.1:22028`, jadi PC memakai jalur itu.

Kunci 9Router VM dibaca dari env `MUSE_VM_KEY` (TIDAK pernah ditulis ke repo).
Idempotent: aman dijalankan berulang.
"""

import json
import os
import secrets
import sqlite3
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("NINE_ROUTER_BASE", "http://127.0.0.1:20128")
VM_BASE = os.environ.get("MUSE_VM_BASE", "http://10.100.0.1:22028")
VM_KEY = os.environ.get("MUSE_VM_KEY", "").strip()

APPDATA = os.environ.get("APPDATA", os.path.expanduser("~"))
DB = os.path.join(APPDATA, "9router", "db", "data.sqlite")

NODE_ID = "openai-compatible-chat-8248d428-ccef-4ea4-a40f-df1415d09175"
CONN_ID = "02487516-98de-4448-85bb-3f5813d70277"
COMBO_ID = "d8c79b4d-0189-4d20-8cc1-cc5681a57fd7"

PREFIX = "musespark"
NODE_NAME = "Muse (Spark asli)"

# 9Router memotong prefix node terluar lalu meneruskan sisanya apa adanya, jadi
# hop VM perlu melihat `musespark/muse-spark-1.3`. Kandidat diuji empiris.
CANDIDATES = [
    "musespark/musespark/muse-spark-1.3",
    "musespark/muse-spark-1.3",
]


def cli_token():
    """x-9r-cli-token = sha256(machineId + '9r-cli-auth' + cliSecret)[:16]."""
    import hashlib
    d = os.path.join(APPDATA, "9router")
    mid = open(os.path.join(d, "machine-id")).read().strip()
    sec = open(os.path.join(d, "auth", "cli-secret")).read().strip()
    return hashlib.sha256((mid + "9r-cli-auth" + sec).encode()).hexdigest()[:16]


def api_key():
    c = sqlite3.connect(DB)
    cols = [r[1] for r in c.execute("PRAGMA table_info(apiKeys)")]
    for row in c.execute("select * from apiKeys"):
        for v in dict(zip(cols, row)).values():
            if isinstance(v, str) and v.startswith("sk-") and len(v) > 20:
                return v
    raise SystemExit("API key 9Router tidak ditemukan di tabel apiKeys")


def req(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("x-9r-cli-token", token)
    try:
        with urllib.request.urlopen(r, timeout=90) as x:
            raw = x.read().decode()
            try:
                return x.status, json.loads(raw)
            except Exception:
                return x.status, raw[:300]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]


def chat(model, key, tag):
    body = json.dumps({"model": model, "stream": False, "max_tokens": 400,
                       "messages": [{"role": "user",
                                     "content": f"Reply with exactly {tag} and nothing else."}]}).encode()
    r = urllib.request.Request(BASE + "/v1/chat/completions", data=body)
    r.add_header("Content-Type", "application/json")
    r.add_header("Accept", "application/json")
    r.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(r, timeout=180) as x:
            return x.status, x.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    if not VM_KEY:
        raise SystemExit("MUSE_VM_KEY kosong — set kunci 9Router VM dulu.")

    tok, key = cli_token(), api_key()

    print("[1/5] node PC -> 9Router VM:", req("PUT", f"/api/provider-nodes/{NODE_ID}", {
        "name": NODE_NAME, "prefix": PREFIX, "apiType": "chat",
        "baseUrl": f"{VM_BASE}/v1"}, tok)[0])

    print("[2/5] connection ->", req("PUT", f"/api/providers/{CONN_ID}", {
        "apiKey": VM_KEY, "defaultModel": "muse-spark-1.3", "isActive": True,
        "providerSpecificData": {"prefix": PREFIX, "apiType": "chat",
                                 "baseUrl": f"{VM_BASE}/v1", "nodeName": NODE_NAME}}, tok)[0])

    print("[3/5] register model custom:", req("POST", "/api/models/custom", {
        "providerAlias": NODE_ID, "id": "muse-spark-1.3",
        "name": "Muse Spark 1.3", "type": "llm"}, tok)[0])

    print("[4/5] cari nama model yang benar-benar tembus ...")
    chosen = None
    for cand in CANDIDATES:
        req("PUT", f"/api/combos/{COMBO_ID}",
            {"name": "muse", "kind": None, "models": [cand]}, tok)
        tag = "ok" + secrets.token_hex(3)
        st, raw = chat("muse", key, tag)
        good = tag in raw and '"Muse Spark"' in raw
        print(f"      {cand:44} HTTP {st} -> {'BENAR' if good else 'gagal'}")
        if good:
            chosen = cand
            break

    if not chosen:
        print("\nGAGAL — tidak ada kandidat yang tembus. Cek shim/VM.")
        return 1

    print(f"[5/5] combo `muse` -> {chosen}")
    req("PUT", f"/api/combos/{COMBO_ID}",
        {"name": "muse", "kind": None, "models": [chosen]}, tok)

    st, raw = chat("muse", key, "FINAL" + secrets.token_hex(2))
    ok = '"Muse Spark"' in raw
    print(f"\nVERIFIKASI FINAL: HTTP {st} model=Muse Spark -> {'OK' if ok else 'GAGAL'}")
    if not ok:
        print("  ", raw[:200])
        return 1
    print("SELESAI — combo `muse` di 9Router PC melayani Muse Spark ASLI.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
