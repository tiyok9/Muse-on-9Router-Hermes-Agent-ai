#!/usr/bin/env python3
"""
Jadikan provider `muse` di 9Router benar-benar melayani combo `muse`.

Latar: model `muse-spark-*-contributor-free` HANYA dilayani provider bawaan
`opencode` (alias `oc`, "OpenCode Free", noAuth). Node `openai-compatible`
biasa TIDAK bisa menembusnya (403 FreeTierError) karena 9Router memasang
emulasi sesi OpenCode khusus pada provider bawaan itu.

Solusi (tanpa patch biner, tanpa tulis DB mentah): node `muse` dijadikan
pass-through ke 9Router sendiri (`http://127.0.0.1:20128/v1`) memakai API key
9Router, dan model-nya diberi prefix `oc/` agar hop dalam resolve ke provider
bawaan `opencode`. Hasilnya combo `muse` benar-benar masuk lewat provider
`muse`, terlihat di usageHistory sebagai dua hop berantai.

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
APPDATA = os.environ.get("APPDATA", os.path.expanduser("~"))
DB = os.path.join(APPDATA, "9router", "db", "data.sqlite")

NODE_ID = "openai-compatible-chat-8248d428-ccef-4ea4-a40f-df1415d09175"
CONN_ID = "02487516-98de-4448-85bb-3f5813d70277"
COMBO_ID = "d8c79b4d-0189-4d20-8cc1-cc5681a57fd7"

PREFIX = "musespark"          # prefix node, sengaja BUKAN alias bawaan
NODE_NAME = "muse"
MODELS = [                     # prefix oc/ -> resolve ke provider bawaan opencode
    "oc/muse-spark-1.3-contributor-free",
    "oc/muse-spark-1.2-contributor-free",
]


def cli_token():
    """x-9r-cli-token = sha256(machineId + '9r-cli-auth' + cliSecret)[:16]."""
    import hashlib
    d = os.path.join(APPDATA, "9router")
    with open(os.path.join(d, "machine-id")) as f:
        mid = f.read().strip()
    with open(os.path.join(d, "auth", "cli-secret")) as f:
        sec = f.read().strip()
    return hashlib.sha256((mid + "9r-cli-auth" + sec).encode()).hexdigest()[:16]


def api_key():
    """API key 9Router sendiri, dipakai sebagai kredensial hop loopback."""
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


def main():
    tok = cli_token()
    key = api_key()

    print("[1/5] node provider ->", req("PUT", f"/api/provider-nodes/{NODE_ID}", {
        "name": NODE_NAME, "prefix": PREFIX, "apiType": "chat",
        "baseUrl": f"{BASE}/v1",
    }, tok))

    print("[2/5] connection ->", req("PUT", f"/api/providers/{CONN_ID}", {
        "apiKey": key, "defaultModel": MODELS[0], "isActive": True,
        "providerSpecificData": {"prefix": PREFIX, "apiType": "chat",
                                 "baseUrl": f"{BASE}/v1", "nodeName": NODE_NAME},
    }, tok))

    print("[3/5] register models")
    for m in MODELS:
        print("      ", m, req("POST", "/api/models/custom", {
            "providerAlias": NODE_ID, "id": m, "name": m, "type": "llm"}, tok))

    print("[4/5] combo ->", req("PUT", f"/api/combos/{COMBO_ID}", {
        "name": "muse", "kind": None,
        "models": [f"{PREFIX}/{m}" for m in MODELS]}, tok))

    print("[5/5] clear stale overrides ->", req(
        "PUT", f"/api/providers/{NODE_ID}/overrides", {"headers": {}}, tok))

    # verifikasi — endpoint /v1 butuh Bearer API key, bukan cli token
    print("\nVERIFIKASI")
    for model in ("muse", f"{PREFIX}/{MODELS[0]}", f"{PREFIX}/{MODELS[1]}"):
        tag = "ok" + secrets.token_hex(2)
        data = json.dumps({"model": model, "max_tokens": 400, "messages": [
            {"role": "user", "content": f"Reply with exactly {tag} and nothing else."}]}).encode()
        r = urllib.request.Request(BASE + "/v1/chat/completions", data=data)
        r.add_header("Content-Type", "application/json")
        r.add_header("Authorization", f"Bearer {key}")
        try:
            with urllib.request.urlopen(r, timeout=180) as x:
                raw, st = x.read().decode(), x.status
        except urllib.error.HTTPError as e:
            raw, st = e.read().decode(), e.code
        ok = tag in raw
        print(f"  {model:52} HTTP {st} menjawab={ok}")
        if not ok:
            print("    ", raw[:200])
            return 1
    print("\nSELESAI — provider muse aktif & combo muse lewat provider muse.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
