#!/usr/bin/env python3
"""hermes-verify-moa — verifikasi Hermes multi-agent (Mixture of Agents).

Memeriksa bahwa Hermes dikonfigurasi sebagai multi-agent memakai combo 9Router
sebagai penasihat (default `anti`, `muse`, `agnes`) + aggregator (default
`codebudy`). Read-only: hanya membaca config + memanggil endpoint.

  A. config    : model.provider == moa, model.default == <preset>
  B. preset    : preset berisi ref (anti/muse/agnes) + aggregator
  C. runtime   : tiap slot resolve ke provider custom + base_url 9Router
  D. combo     : keempat combo benar-benar ada di /v1/models 9Router
  E. cli       : `hermes moa list` menampilkan preset sebagai default
  F. backup    : ada backup config sebelum MoA diubah

Usage: python scripts/hermes-verify-moa.py
Env  : MOA_AGG=<nama aggregator>   (default: codebudy)
       MOA_REFS=<ref1,ref2,...>    (default: anti,muse,agnes)
Exit : 0 = semua lulus, 1 = ada yang gagal.
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.request

HOME = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "hermes")
PKG = os.path.join(HOME, "hermes-agent")
CONFIG = os.path.join(HOME, "config.yaml")
BASE = os.environ.get("NINE_ROUTER_BASE", "http://127.0.0.1:20128")

PRESET = os.environ.get("MOA_PRESET", "multi")
REFS = [s.strip() for s in os.environ.get(
    "MOA_REFS", "anti,muse,agnes").split(",") if s.strip()]
AGG = os.environ.get("MOA_AGG", "codebudy")

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name +
          ("   <- " + detail if (detail and not ok) else ""))


def section(title):
    print("\n" + "=" * 70 + "\n" + title + "\n" + "=" * 70)


def load_cfg():
    sys.path.insert(0, PKG)
    os.environ.setdefault("HERMES_HOME", HOME)
    from hermes_cli.config import load_config
    from hermes_cli.moa_config import normalize_moa_config
    cfg = load_config() or {}
    return cfg, normalize_moa_config(cfg.get("moa") or {})


def api_key():
    db = os.path.join(os.environ.get("APPDATA", "~"), "9router", "db", "data.sqlite")
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    cols = [r[1] for r in con.execute("PRAGMA table_info(apiKeys)")]
    for row in con.execute("select * from apiKeys"):
        for v in dict(zip(cols, row)).values():
            if isinstance(v, str) and v.startswith("sk-") and len(v) > 20:
                return v
    raise SystemExit("API key 9Router tidak ditemukan")


section("A. CONFIG HERMES")
raw = open(CONFIG, encoding="utf-8").read()
m = re.search(r"^model:\n((?:[ \t]+.*\n|\n)*)", raw, re.M)
block = m.group(1) if m else ""
prov = re.search(r"^\s+provider:\s*(\S+)", block, re.M)
dflt = re.search(r"^\s+default:\s*(\S+)", block, re.M)
check("model.provider == moa", bool(prov) and prov.group(1) == "moa",
      prov.group(1) if prov else "tidak ada")
check("model.default == %s" % PRESET, bool(dflt) and dflt.group(1) == PRESET,
      dflt.group(1) if dflt else "tidak ada")

section("B. PRESET MoA")
cfg, moa = load_cfg()
check("default_preset == %s" % PRESET, moa["default_preset"] == PRESET,
      moa["default_preset"])
preset = moa["presets"].get(PRESET)
check("preset '%s' ada" % PRESET, preset is not None)
if preset:
    got_refs = [s["model"] for s in preset["reference_models"]]
    check("reference = %s" % REFS, got_refs == REFS, str(got_refs))
    check("semua reference pakai provider custom",
          all(s["provider"] == "custom" for s in preset["reference_models"]))
    check("aggregator == custom:%s" % AGG,
          preset["aggregator"]["provider"] == "custom"
          and preset["aggregator"]["model"] == AGG,
          "%s:%s" % (preset["aggregator"]["provider"], preset["aggregator"]["model"]))
    check("aggregator != reference (independensi MoA)",
          preset["aggregator"]["model"] not in got_refs,
          "aggregator '%s' juga ada di reference" % preset["aggregator"]["model"])

section("C. RESOLUSI RUNTIME SLOT")
try:
    sys.path.insert(0, PKG)
    from hermes_cli.runtime_provider import resolve_runtime_provider
    for model in REFS + [AGG]:
        rt = resolve_runtime_provider(requested="custom", target_model=model) or {}
        ok = rt.get("provider") == "custom" and "20128" in str(rt.get("base_url", ""))
        check("slot %s -> custom + base_url 9Router" % model, ok,
              "%s @ %s" % (rt.get("provider"), rt.get("base_url")))
except Exception as exc:
    check("resolusi runtime", False, "%s: %s" % (type(exc).__name__, exc))

section("D. COMBO HIDUP DI 9ROUTER")
key = api_key()
req = urllib.request.Request(BASE + "/v1/models")
req.add_header("Authorization", "Bearer " + key)
try:
    with urllib.request.urlopen(req, timeout=60) as x:
        ids = {m.get("id") for m in json.loads(x.read().decode()).get("data", [])}
    for combo in REFS + [AGG]:
        check("combo '%s' terdaftar" % combo, combo in ids)
except Exception as exc:
    check("daftar /v1/models", False, "%s: %s" % (type(exc).__name__, exc))

section("E. CLI hermes moa list")
try:
    out = subprocess.run(["hermes", "moa", "list"], cwd=HOME, capture_output=True,
                         text=True, encoding="utf-8", errors="replace",
                         timeout=180).stdout
    check("default_preset tampil = %s" % PRESET, ("Default: " + PRESET) in out)
    check("preset '%s' tampil" % PRESET, ("* " + PRESET) in out or PRESET in out)
except Exception as exc:
    check("hermes moa list", False, "%s: %s" % (type(exc).__name__, exc))

section("F. BACKUP CONFIG")
baks = [f for f in os.listdir(HOME) if f.startswith("config.yaml.bak.premoa")]
check("backup sebelum MoA ada", bool(baks), ", ".join(sorted(baks)[:3]))

passed, total = sum(results), len(results)
print("\n" + "=" * 70)
print("HASIL: %d PASS, %d FAIL" % (passed, total - passed))
print("=" * 70)
sys.exit(0 if passed == total else 1)
