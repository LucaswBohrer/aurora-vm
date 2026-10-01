#!/bin/sh
# tests/phase1/run_cli_tests.sh — Phase 1: CLI skeleton + error reporting.
# Asserts observable behavior: exit codes and stdout/stderr substrings.
set -u

BIN="${AURORA_BIN:-build/aurora}"
PASS=0
FAIL=0

# run_test <name> <expected_exit> <expected_substring> [args...]
run_test() {
    name="$1"; exp_exit="$2"; exp_sub="$3"; shift 3
    out="$("$BIN" "$@" 2>&1)"
    code=$?
    if [ "$code" -eq "$exp_exit" ] && printf '%s' "$out" | grep -qF -- "$exp_sub"; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (exit=%s want %s; output=[%s])\n' "$name" "$code" "$exp_exit" "$out"
    fi
}

if [ ! -x "$BIN" ]; then
    printf 'FAIL: binary not executable: %s\n' "$BIN"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
touch "$TMP/empty.bin"

run_test "help-long"            0 "Usage:" --help
run_test "help-short"           0 "Usage:" -h
run_test "version-long"         0 "aurora 1.0.0" --version
run_test "version-short"        0 "aurora 1.0.0" -V
run_test "no-args-shows-help"   0 "Usage:"
run_test "run-missing-file"     2 "run: missing file operand" run
run_test "run-nonexistent"      2 "run: cannot open"              run "$TMP/nope.bin"
run_test "run-stub"             3 "not implemented in this build" run "$TMP/empty.bin"
run_test "run-maxsteps-eq"      3 "not implemented in this build" run "$TMP/empty.bin" --max-steps=1000
run_test "run-maxsteps-space"   3 "not implemented in this build" run "$TMP/empty.bin" --max-steps 1000
run_test "run-maxsteps-zero"    3 "not implemented in this build" run "$TMP/empty.bin" --max-steps 0
run_test "run-maxsteps-u64max"  3 "not implemented in this build" run "$TMP/empty.bin" --max-steps 18446744073709551615
run_test "run-maxsteps-bad"     2 "invalid value for --max-steps" run "$TMP/empty.bin" --max-steps abc
run_test "run-maxsteps-empty"   2 "invalid value for --max-steps" run "$TMP/empty.bin" --max-steps=
run_test "run-maxsteps-neg"     2 "invalid value for --max-steps" run "$TMP/empty.bin" --max-steps -5
run_test "run-maxsteps-over"    2 "invalid value for --max-steps" run "$TMP/empty.bin" --max-steps 18446744073709551616
run_test "run-maxsteps-noval"   2 "--max-steps requires a value" run "$TMP/empty.bin" --max-steps
run_test "run-unknown-option"   2 "run: unknown option '--frobnicate'" run "$TMP/empty.bin" --frobnicate
run_test "run-extra-operand"    2 "run: unexpected operand 'extra'" run "$TMP/empty.bin" extra
run_test "unknown-command"      2 "unknown command 'frobnicate'" frobnicate
run_test "debug-missing-file"   2 "expected exactly one file operand" debug
run_test "debug-nonexistent"    2 "debug: cannot open"            debug "$TMP/nope.bin"
run_test "debug-stub"           3 "not implemented in this build" debug "$TMP/empty.bin"
run_test "debug-extra-operand"  2 "expected exactly one file operand" debug "$TMP/empty.bin" extra

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
