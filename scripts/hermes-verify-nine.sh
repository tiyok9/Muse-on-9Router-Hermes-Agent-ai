#!/usr/bin/env bash
# hermes-verify-nine.sh — ad-hoc verifier for the "Muse uses PC's 9Router" leg.
# Runs the REAL code blocks extracted from the scripts, with no network access.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[ -f "$REPO/muse-bootstrap.sh" ] || REPO="$PWD"
BASH_BIN="$(command -v bash)"
BOOT="$REPO/muse-bootstrap.sh"
TUN="$REPO/muse-ssh-tunnel.sh"
PASS=0; FAIL=0
ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n    exp=[%s]\n    got=[%s]\n' "$1" "$2" "$3"; fi
}
has() { case "$2" in *"$1"*) echo 1;; *) echo 0;; esac; }

echo "== A. sintaks =="
for f in "$BOOT" "$TUN"; do bash -n "$f" && echo "  ok $(basename "$f")" || echo "  SYNTAX-FAIL $(basename "$f")"; done
ck "bootstrap LF-pure" 0 "$(awk '/\r/{n++} END{print n+0}' "$BOOT")"
ck "tunnel LF-pure"    0 "$(awk '/\r/{n++} END{print n+0}' "$TUN")"

echo
echo "== B. blok forward tunnel (kode ASLI) =="
FB="$(mktemp)"
awk '/^RELAY="\$\{RELAY:\?/{p=1} p{print} /^echo "\[tunnel\] bridge/{exit}' "$TUN" > "$FB"
# sanity: block must contain the real forward array and the -L line
ck "blok memuat -R bridge" 1 "$(has 'forwards=(-R "${REMOTE_BIND}:${REMOTE_PORT}' "$(cat "$FB")")"
ck "blok memuat -L"        1 "$(has 'forwards+=(-L "127.0.0.1:${NINE_LOCAL}:${NINE_REMOTE}")' "$(cat "$FB")")"

run_fwd() { # run_fwd <NINE_REMOTE> <NINE_LOCAL> <WG_PUB_PORT>
  env -i RELAY=u@h BRIDGE_PORT=8765 NINE_REMOTE="$1" NINE_LOCAL="$2" WG_PUB_PORT="$3" \
    "$BASH_BIN" -c "source '$FB'; printf '%s\n' \"\${forwards[@]}\""
}
out="$(run_fwd "" "" 0)"
ck "tanpa knob: 1 forward (bridge)" 1 "$(printf '%s\n' "$out" | grep -c -- '-R')"
ck "tanpa knob: 0 forward -L"       0 "$(printf '%s\n' "$out" | grep -c -- '-L')"
out="$(run_fwd "" "" 22028)"
ck "WG saja: 2 forward -R"          2 "$(printf '%s\n' "$out" | grep -c -- '-R')"
out="$(run_fwd "10.100.0.3:20128" 12028 0)"
ck "NINE saja: ada -L"              1 "$(printf '%s\n' "$out" | grep -c -- '-L')"
ck "NINE saja: -L addr benar"       1 "$(has '127.0.0.1:12028:10.100.0.3:20128' "$out")"
ck "NINE saja: -R tetap 1"          1 "$(printf '%s\n' "$out" | grep -c -- '-R')"
out="$(run_fwd "10.100.0.3:20128" 12028 22028)"
ck "keduanya: -R=2 -L=1"            "2 1" "$(printf '%s\n' "$out" | grep -c -- '-R') $(printf '%s\n' "$out" | grep -c -- '-L')"
out="$(run_fwd "10.100.0.3:20128" 19999 0)"
ck "NINE_LOCAL dihormati"           1 "$(has '127.0.0.1:19999:10.100.0.3:20128' "$out")"
ck "NINE_REMOTE kosong = off"        0 "$(printf '%s\n' "$(run_fwd "" 12028 0)" | grep -c -- '-L')"

echo
echo "== C. parser knob bootstrap (kode ASLI) =="
PB="$(mktemp)"
awk '/^CFG_FILE="\$BRIDGE_DIR\/bootstrap.conf"/{p=1} p{print} p&&/^fi$/{exit}' "$BOOT" > "$PB"
ck "parser memuat NINE_REMOTE"  1 "$(has 'MUSE_NINE_REMOTE)' "$(cat "$PB")")"
ck "parser memuat UPSTREAM_KEY" 1 "$(has 'MUSE_UPSTREAM_KEY)' "$(cat "$PB")")"
BD="$(mktemp -d)"
printf 'MUSE_NINE_REMOTE=10.100.0.3:20128\nMUSE_NINE_LOCAL=12028\nMUSE_UPSTREAM_KEY=sk-test123\nMUSE_UPSTREAM_MODEL=muse\nMUSE_WG_PUB_PORT=22028\n' > "$BD/bootstrap.conf"
# NB: the parser block sets CFG_FILE itself from $BRIDGE_DIR — so BRIDGE_DIR is
# the knob to set here, not CFG_FILE.
res="$(MUSE_NINE_REMOTE= MUSE_NINE_LOCAL= MUSE_UPSTREAM_KEY= MUSE_UPSTREAM_MODEL= MUSE_WG_PUB_PORT= \
  BRIDGE_DIR="$BD" "$BASH_BIN" -c "source '$PB'; printf '%s|%s|%s|%s' \"\$MUSE_NINE_REMOTE\" \"\$MUSE_NINE_LOCAL\" \"\$MUSE_UPSTREAM_KEY\" \"\$MUSE_UPSTREAM_MODEL\"")"
ck "knob dipulihkan dari conf" "10.100.0.3:20128|12028|sk-test123|muse" "$res"
res="$(MUSE_NINE_REMOTE= BRIDGE_DIR="$BD" "$BASH_BIN" -c "MUSE_NINE_REMOTE=explicit; source '$PB'; printf '%s' \"\$MUSE_NINE_REMOTE\"")"
ck "env eksplisit menang atas conf" "explicit" "$res"

echo
echo "== D. blok worker.env (kode ASLI) =="
WB="$(mktemp)"
awk '/^ENV_TMP="\$\(mktemp\)"/{p=1} p{print} p&&/^chmod 600 "\$ENV_FILE"$/{exit}' "$BOOT" > "$WB"
ck "blok memuat UPSTREAM_KEY"   1 "$(has 'UPSTREAM_KEY=$UPSTREAM_KEY' "$(cat "$WB")")"
ck "blok memuat UPSTREAM_MODEL" 1 "$(has 'UPSTREAM_MODEL=' "$(cat "$WB")")"
WOUT="$(mktemp)"
env -i HOME=/tmp BRIDGE_DIR=/tmp PBRG=8765 WKEY_FINAL=k1 UPSTREAM=http://127.0.0.1:12028/v1 \
  UPSTREAM_KEY=sk-abc UPSTREAM_MODEL=muse QUEUE_DIR=/tmp/q ENV_FILE="$WOUT" \
  "$BASH_BIN" -c "source '$WB'" >/dev/null 2>&1
ck "worker.env: UPSTREAM ditulis"       1 "$(has 'UPSTREAM=http://127.0.0.1:12028/v1' "$(cat "$WOUT" 2>/dev/null)")"
ck "worker.env: UPSTREAM_KEY ditulis"   1 "$(has 'UPSTREAM_KEY=sk-abc' "$(cat "$WOUT" 2>/dev/null)")"
ck "worker.env: UPSTREAM_MODEL ditulis" 1 "$(has 'UPSTREAM_MODEL=muse' "$(cat "$WOUT" 2>/dev/null)")"

echo
echo "== E. unit muse-tunnel (kode ASLI) =="
UB="$(mktemp)"
awk '/^    NINE_ENV=""$/{p=1} p{print} p&&/^WantedBy=multi-user.target"$/{exit}' "$BOOT" > "$UB"
ck "unit memuat NINE_ENV block" 1 "$(has 'NINE_ENV="Environment=NINE_REMOTE=' "$(cat "$UB")")"
ck "unit menyuntik \$NINE_ENV"  1 "$(has '$NINE_ENV' "$(cat "$UB")")"
ck "unit tetap punya ExecStart" 1 "$(has 'ExecStart=/usr/bin/env bash' "$(cat "$UB")")"
ck "unit tetap punya WantedBy"  1 "$(has 'WantedBy=multi-user.target' "$(cat "$UB")")"

rm -f "$FB" "$PB" "$WB" "$WOUT" "$UB"; rm -rf "$BD"
echo
printf '== HASIL: %d PASS, %d FAIL ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
