#!/usr/bin/env bash
# install-muse-spark-shim.sh — pasang shim Muse Spark di dalam VM Muse.
#
# Dijalankan DI DALAM VM Muse (ssh musevm), sebagai root. Idempotent.
#
# Latar: VM Muse (htch-runtime) menjalankan runtime Meta "hatch". Runtime itu
# memiliki socket inference /run/hatch/sandbox/space-inference.sock yang
# melayani model Muse Spark ASLI milik user — tanpa login, tanpa biaya.
# Skrip ini memasang jembatan OpenAI-compatible di :8766 supaya 9Router bisa
# memakainya sebagai provider biasa.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR=/home/hatch/muse-bridge
SOCK=/run/hatch/sandbox/space-inference.sock

echo "== 1. prasyarat =="
[[ -S $SOCK ]] || { echo "FATAL: $SOCK tidak ada (runtime Muse belum jalan?)"; exit 1; }
echo "   socket OK: $SOCK"

echo "== 2. salin shim =="
install -d -m 755 "$DEST_DIR"
install -m 700 "$SRC_DIR/muse_spark_shim.py" "$DEST_DIR/muse-spark-shim.py"
echo "   -> $DEST_DIR/muse-spark-shim.py"

echo "== 3. pasang unit systemd =="
install -m 644 "$SRC_DIR/muse-spark-shim.service" /etc/systemd/system/muse-spark-shim.service
systemctl daemon-reload
systemctl enable --now muse-spark-shim.service
echo "   enabled + started"

echo "== 4. tunggu siap =="
for i in $(seq 1 20); do
  if curl -sf --max-time 3 http://127.0.0.1:8766/health >/dev/null 2>&1; then
    echo "   shim sehat setelah ${i}s"; break
  fi
  sleep 1
done

echo "== 5. verifikasi end-to-end (Muse Spark asli) =="
curl -s --max-time 120 http://127.0.0.1:8766/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"muse-spark-1.3","stream":false,
       "messages":[{"role":"user","content":"Reply with exactly SHIM-OK"}]}' \
  | grep -q 'SHIM-OK' && echo "   OK — Muse Spark menjawab lewat shim." \
  || { echo "   GAGAL verifikasi"; exit 1; }

echo
echo "SELESAI. Shim aktif di 127.0.0.1:8766 (systemd: muse-spark-shim.service)."
