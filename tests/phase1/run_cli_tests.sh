#!/bin/sh
# tests/phase1/run_cli_tests.sh — Phase 1: CLI skeleton + error reporting.
# Asserts observable behavior: exit codes and stdout/stderr substrings.
set -u

BIN="${AURORA_BIN:-build/aurora}"
PASS=0
FAIL=0

# run_test <name> <expected_exit> <expected_substring> [args...]
# An empty expected_substring asserts empty stdout+stderr.
run_test() {
    name="$1"; exp_exit="$2"; exp_sub="$3"; shift 3
    out="$("$BIN" "$@" 2>&1)"
    code=$?
    if [ -z "$exp_sub" ]; then
        [ -z "$out" ] && out_ok=1 || out_ok=0
    else
        printf '%s' "$out" | grep -qF -- "$exp_sub" && out_ok=1 || out_ok=0
    fi
    if [ "$code" -eq "$exp_exit" ] && [ "$out_ok" -eq 1 ]; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s (exit=%s want %s; output=[%s])\n' "$name" "$code" "$exp_exit" "$out"
    fi
}

# run_test_pipe <name> <expected_exit> <expected_substring> <stdin> [args...]
# Like run_test but feeds <stdin> to the program (for interactive commands).
run_test_pipe() {
    name="$1"; exp_exit="$2"; exp_sub="$3"; stdin_data="$4"; shift 4
    out="$(printf '%s' "$stdin_data" | "$BIN" "$@" 2>&1)"
    code=$?
    if [ -z "$exp_sub" ]; then
        [ -z "$out" ] && out_ok=1 || out_ok=0
    else
        printf '%s' "$out" | grep -qF -- "$exp_sub" && out_ok=1 || out_ok=0
    fi
    if [ "$code" -eq "$exp_exit" ] && [ "$out_ok" -eq 1 ]; then
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
# Minimal valid program (docs/BYTECODE.md §6): single HALT, 34 bytes.
# Phase 2: the loader is real, so these tests use a *valid* file; an empty
# file is now (correctly) rejected with INVALID_PROGRAM (see L3 suite).
python3 -c "
import sys
sys.stdout.buffer.write(bytes.fromhex(
    '4155524f52410100'  # magic
    '0100'              # version 0x0001
    '08000000'          # code_size = 8
    '00000000'          # entry = 0
    '00000000'          # data_size = 0
    '00000000'          # reserved
    '01ffff0000000000'  # HALT
))" > "$TMP/halt.bin"
touch "$TMP/empty.bin"

run_test "help-long"            0 "Usage:" --help
run_test "help-short"           0 "Usage:" -h
run_test "version-long"         0 "aurora 1.0.0" --version
run_test "version-short"        0 "aurora 1.0.0" -V
run_test "no-args-shows-help"   0 "Usage:"
run_test "run-missing-file"     2 "run: missing file operand" run
run_test "run-nonexistent"      2 "run: cannot open"              run "$TMP/nope.bin"
run_test "run-exec-halt"       0 ""                              run "$TMP/halt.bin"
run_test "run-empty-file"       108 "INVALID_PROGRAM"             run "$TMP/empty.bin"
run_test "run-maxsteps-eq"      0 ""                              run "$TMP/halt.bin" --max-steps=1000
run_test "run-maxsteps-space"   0 ""                              run "$TMP/halt.bin" --max-steps 1000
run_test "run-maxsteps-zero"    0 ""                              run "$TMP/halt.bin" --max-steps 0
run_test "run-maxsteps-u64max"  0 ""                              run "$TMP/halt.bin" --max-steps 18446744073709551615
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
run_test_pipe "debug-exec-quit" 0 "AURORA debugger" "quit\n"      debug "$TMP/halt.bin"
run_test "debug-empty-file"     108 "INVALID_PROGRAM"             debug "$TMP/empty.bin"
run_test "debug-extra-operand"  2 "expected exactly one file operand" debug "$TMP/empty.bin" extra

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
