#!/bin/sh
# tests/byte/run_l3_tests.sh — L3: bytecode rejection tests (phase 2).
# Regenerates fixtures with tests/byte/gen.py, then asserts exit code and
# stderr substrings for every case in the manifest.
set -u

BIN="${AURORA_BIN:-build/aurora}"
GEN="tests/byte/gen.py"
FIX="tests/byte/fixtures"
PASS=0
FAIL=0

if [ ! -x "$BIN" ]; then
    printf 'FAIL: binary not executable: %s\n' "$BIN"
    exit 1
fi

python3 "$GEN" > /dev/null || { printf 'FAIL: fixture generation\n'; exit 1; }

while IFS="$(printf '\t')" read -r name exp_exit subs; do
    case "$name" in name|'') continue;; esac
    f="$FIX/$name.bin"
    if [ ! -f "$f" ]; then
        FAIL=$((FAIL + 1)); printf 'FAIL: %s (missing fixture)\n' "$name"
        continue
    fi
    out="$("$BIN" run "$f" 2>&1)"
    code=$?
    ok=1
    if [ "$code" -ne "$exp_exit" ]; then ok=0; fi
    old_ifs="$IFS"; IFS='|'
    # shellcheck disable=SC2086
    set -- $subs
    IFS="$old_ifs"
    for sub in "$@"; do
        if ! printf '%s' "$out" | grep -qF -- "$sub"; then ok=0; fi
    done
    if [ "$ok" -eq 1 ]; then
        PASS=$((PASS + 1)); printf 'PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (exit=%s want %s; output=[%s])\n' "$name" "$code" "$exp_exit" "$out"
    fi
done < "$FIX/manifest.tsv"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
