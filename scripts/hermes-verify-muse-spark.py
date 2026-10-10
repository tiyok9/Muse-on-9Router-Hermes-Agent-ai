#!/usr/bin/env python3
"""hermes-verify-muse-spark — verifikasi jalur combo `muse` -> Muse Spark ASLI.

Canonical check for the Muse Spark integration (sibling of
scripts/hermes-verify-nine.sh). Safe to run repeatedly; read-only except for
nothing at all — it only inspects and calls the live endpoints.

  A. syntax    : py_compile shim + wiring, bash -n installer
  B. secrets   : no credential values in the tracked artifacts
  C. drift     : repo shim/unit byte-identical to what runs in the VM
  D. VM        : shim unit enabled+active, /health, real Muse Spark answer
  E. PC        : combo `muse` -> model "Muse Spark" (non-stream + SSE)
  F. git       : working tree clean

Usage: python scripts/hermes-verify-muse-spark.py
Exit: 0 = all pass, 1 = at least one failure.
"""
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.environ.get("NINE_ROUTER_BASE", "http://127.0.0.1:20128")
SSH = ["ssh", "-o", "ConnectTimeout=15", "-o", "BatchMode=yes",
       os.environ.get("MUSE_VM_SSH", "musevm")]

ARTIFACTS = ["scripts/muse_spark_shim.py", "scripts/muse-spark-shim.service",
             "scripts/install-muse-spark-shim.sh",
             "scripts/nine-router-muse-spark.py"]
VM_SHIM = "/home/hatch/muse-bridge/muse-spark-shim.py"
VM_UNIT = "/etc/systemd/system/muse-spark-shim.service"

# Values that must never appear in a tracked file.
LEAK = re.compile(r"sk-[A-Za-z0-9]{16,}|Muse_k[A-Za-z0-9]{8,}|"
                  r"BRIDGE_USER_KEY\s*=\s*[^\s\"']+|BEGIN [A-Z ]*PRIVATE KEY")

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name +
          ("   <- " + detail if (detail and not ok) else ""))


def run(cmd, shell=False, timeout=300):
    return subprocess.run(cmd, shell=shell, cwd=REPO, capture_output=True,
                          text=True, encoding="utf-8", errors="replace",
                          timeout=timeout)


def ssh(cmd, timeout=300):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def digest(text):
    """CRLF-insensitive digest — a line-ending difference is not real drift."""
    return hashlib.sha256(text.replace("\r\n", "\n").encode()).hexdigest()[:16]


def read(rel):
    return open(os.path.join(REPO, rel), encoding="utf-8").read()


def api_key():
    db = os.path.join(os.environ.get("APPDATA", "~"), "9router", "db", "data.sqlite")
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    cols = [r[1] for r in con.execute("PRAGMA table_info(apiKeys)")]
    for row in con.execute("select * from apiKeys"):
        for v in dict(zip(cols, row)).values():
            if isinstance(v, str) and v.startswith("sk-") and len(v) > 20:
                return v
    raise SystemExit("API key 9Router tidak ditemukan di tabel apiKeys")


def chat(model, key, stream=False, content="Reply with exactly VERIFY-OK"):
    body = json.dumps({"model": model, "stream": stream, "max_tokens": 400,
                       "messages": [{"role": "user", "content": content}]}).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=body)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("Authorization", "Bearer " + key)
    try:
        with urllib.request.urlopen(req, timeout=180) as x:
            return x.status, x.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def section(title):
    print("\n" + "=" * 70 + "\n" + title + "\n" + "=" * 70)


section("A. SYNTAX")
for rel in ("scripts/muse_spark_shim.py", "scripts/nine-router-muse-spark.py"):
    r = run([sys.executable, "-m", "py_compile", rel])
    check("py_compile " + rel, r.returncode == 0, (r.stderr or "").strip()[:160])
r = run(["bash", "-n", "scripts/install-muse-spark-shim.sh"])
check("bash -n install-muse-spark-shim.sh", r.returncode == 0,
      (r.stderr or "").strip()[:160])

section("B. SECRET SCAN")
leaks = ["%s: %s" % (f, m.group(0)[:20])
         for f in ARTIFACTS for m in LEAK.finditer(read(f))]
check("no credential values in artifacts", not leaks, "; ".join(leaks))

section("C. REPO <-> VM DRIFT")
r = ssh("cat " + VM_SHIM)
check("VM shim reachable", r.returncode == 0, (r.stderr or "").strip()[:120])
check("shim repo == VM", digest(read(ARTIFACTS[0])) == digest(r.stdout))
r = ssh("cat " + VM_UNIT)
check("unit repo == VM", digest(read(ARTIFACTS[1])) == digest(r.stdout))
check("artifacts are LF-only",
      all("\r" not in read(f) for f in ARTIFACTS[:2]))

section("D. VM: SHIM LIVE")
check("shim unit enabled (survives reboot)",
      ssh("systemctl is-enabled muse-spark-shim.service").stdout.strip() == "enabled")
check("shim unit active",
      ssh("systemctl is-active muse-spark-shim.service").stdout.strip() == "active")
r = ssh("curl -sf --max-time 8 http://127.0.0.1:8766/health")
check("shim /health 200", r.returncode == 0 and '"ok"' in r.stdout)
r = ssh("curl -s --max-time 120 http://127.0.0.1:8766/v1/chat/completions "
        "-H 'Content-Type: application/json' -d "
        "'{\"model\":\"muse-spark-1.3\",\"stream\":false,\"messages\":"
        "[{\"role\":\"user\",\"content\":\"Reply with exactly SHIM-OK\"}]}'")
check("shim answers as Muse Spark", "SHIM-OK" in r.stdout and "Muse Spark" in r.stdout,
      r.stdout.strip()[:160])

section("E. PC: COMBO `muse` -> MUSE SPARK")
key = api_key()
st, raw = chat("muse", key)
check("combo muse non-stream HTTP 200", st == 200, "HTTP %s" % st)
check('combo muse -> model "Muse Spark"', '"Muse Spark"' in raw, raw[:200])
try:
    body = json.loads(raw)
    check("non-stream body is pure JSON", "choices" in body)
    check("answer non-empty", bool(body["choices"][0]["message"]["content"].strip()))
except Exception as exc:
    check("non-stream body parses", False, str(exc))
st, sraw = chat("muse", key, stream=True)
check("combo muse stream HTTP 200", st == 200, "HTTP %s" % st)
check("stream carries Muse Spark chunks",
      sraw.lstrip().startswith("data:") and '"Muse Spark"' in sraw, sraw[:160])

section("F. GIT STATE")
# Only tracked files matter: an untracked file (e.g. this verifier before its
# first commit) is not "dirty work" — an uncommitted edit to a committed
# artifact is.
dirty = run("git status --porcelain --untracked-files=no", shell=True).stdout.strip()
check("no uncommitted changes to tracked files", dirty == "", dirty[:200])

passed, total = sum(results), len(results)
print("\n" + "=" * 70)
print("HASIL: %d PASS, %d FAIL" % (passed, total - passed))
print("=" * 70)
sys.exit(0 if passed == total else 1)
