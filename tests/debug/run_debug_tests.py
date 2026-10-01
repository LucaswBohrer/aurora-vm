#!/usr/bin/env python3
"""AURORA debugger automated tests (Phase 5).

Runs debugger sessions via stdin pipe and checks stdout/stderr patterns.
Each test feeds commands to `aurora debug <file>` and asserts on output.

Exit 0 = all pass, 1 = failures.
"""
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(REPO, "build", "aurora")
ASM = os.path.join(REPO, "tools", "aurora-asm")

PASS = 0
FAIL = 0
FAILURES = []

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok: {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"  FAIL: {name} {detail}")

def asm_source(name, src):
    """Assemble src text -> temp .bin path."""
    d = tempfile.mkdtemp(prefix="dbgtest_")
    ap = os.path.join(d, name + ".asm")
    bp = os.path.join(d, name + ".bin")
    with open(ap, "w") as f:
        f.write(src)
    r = subprocess.run([sys.executable, ASM, ap, "-o", bp],
                       capture_output=True, text=True)
    assert r.returncode == 0, f"asm failed for {name}: {r.stderr}"
    return bp

def dbg(binpath, commands, timeout=10):
    """Run debugger with commands list (strings). Returns (stdout, stderr, rc)."""
    inp = "\n".join(commands) + "\n"
    r = subprocess.run([BIN, "debug", binpath], input=inp,
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout, r.stderr, r.returncode

# ---------------------------------------------------------------- fixtures
# Simple: R0=42, HALT. Code starts at 0x20 (after 26-byte header + padding).
SIMPLE = asm_source("simple", "MOV R0, 42\nHALT\n")
# Div-by-zero: R0=10, R1=0, DIV R0, R1, HALT
DIVZERO = asm_source("divzero", "MOV R0, 10\nMOV R1, 0\nDIV R0, R1\nHALT\n")
# Loop: R0=0; loop: ADD R0, 1; CMP R0, 5; JL loop; HALT
LOOP = asm_source("loop",
                  "MOV R0, 0\nMOV R1, 1\nMOV R2, 5\nloop:\nADD R0, R1\nCMP R0, R2\nJL loop\nHALT\n")
# HALT with exit 106 (D22: same exit as DIVISION_BY_ZERO, different class)
HALT106 = asm_source("halt106", "MOV R0, 106\nHALT\n")

print("== debugger CLI ==")
out, err, rc = dbg(SIMPLE, ["help", "quit"])
check("help lists commands", "run" in out and "break" in out and "quit" in out)
check("quit exits 0", rc == 0, f"rc={rc}")

# debug --help
r = subprocess.run([BIN, "debug", "--help"], capture_output=True, text=True)
check("debug --help exits 0", r.returncode == 0)
check("debug --help usage", "Usage: aurora debug" in r.stdout)

# missing file
r = subprocess.run([BIN, "debug", "/nonexistent.bin"],
                   capture_output=True, text=True)
check("missing file exits 2", r.returncode == 2, f"rc={r.returncode}")

print("== run/continue/step ==")
out, err, rc = dbg(SIMPLE, ["run", "quit"])
check("run executes", "terminated: NORMAL (HALT), exit code 42" in out, out[:200])
check("run rc 0 (debugger stays)", rc == 0)

out, err, rc = dbg(SIMPLE, ["step", "regs", "quit"])
check("step 1 executes MOV", "R0:" in out)
# After 1 step, R0 should be 42
check("step sets R0=42", "0x000000000000002a" in out.lower() or
      "42" in out, out[:300])

out, err, rc = dbg(SIMPLE, ["step 2", "info", "quit"])
check("step 2 halts", "terminated: NORMAL (HALT)" in out)

print("== breakpoints ==")
out, err, rc = dbg(LOOP, ["break 0x0", "run", "quit"])
check("break at entry stops", "stopped at breakpoint" in out, out[:200])
check("break addr printed", "0x00000000" in out)

out, err, rc = dbg(LOOP, ["break 0x0", "break 0x8", "breakpoints", "quit"])
check("two breakpoints listed", out.count("0x") >= 2, out[:200])

out, err, rc = dbg(LOOP, ["break 0x0", "delete 0x0", "breakpoints", "quit"])
check("delete removes", "0/16" in out or "no breakpoints" in out.lower(),
      out[:200])

out, err, rc = dbg(LOOP, ["break 0x9999", "quit"])
check("break invalid addr rejected", "error" in out.lower(), out[:200])

print("== registers/flags ==")
out, err, rc = dbg(SIMPLE, ["regs", "quit"])
check("regs shows PC", "PC:" in out)
check("regs shows SP", "SP:" in out)
check("regs shows R0", "R0:" in out)
out, err, rc = dbg(SIMPLE, ["flags", "quit"])
check("flags shows Z", "Z=" in out)

print("== memory ==")
out, err, rc = dbg(SIMPLE, ["memory 0x0 16", "quit"])
check("memory hex addr", "0x00000000:" in out, out[:120])
out, err, rc = dbg(SIMPLE, ["memory 0 16", "quit"])
check("memory decimal addr", "0x00000000:" in out)
out, err, rc = dbg(SIMPLE, ["memory 0x0 32", "quit"])
check("memory count 32", out.count("0x000000") >= 2, out[:200])
out, err, rc = dbg(SIMPLE, ["memory 0x10000 16", "quit"])
check("memory out of range", "error" in out.lower())
out, err, rc = dbg(SIMPLE, ["memory 0xFFFFF 16", "quit"])
check("memory huge addr rejected", "error" in out.lower())

print("== stack/backtrace ==")
out, err, rc = dbg(SIMPLE, ["stack", "quit"])
check("stack shows SP", "SP:" in out)
out, err, rc = dbg(SIMPLE, ["backtrace", "quit"])
check("backtrace runs", "FP=" in out or "return=" in out or "empty" in out.lower(),
      out[:200])

print("== disassembler ==")
out, err, rc = dbg(SIMPLE, ["disasm 0x0 2", "quit"])
check("disasm shows MOV", "MOV" in out, out[:200])
out, err, rc = dbg(SIMPLE, ["disasm 0 1", "quit"])
check("disasm decimal", "MOV" in out or "0x00000000:" in out)
# 43/43: disassemble a program using many opcodes; just check it doesn't crash
out, err, rc = dbg(LOOP, ["disasm 0x0 5", "quit"])
check("disasm loop", "ADD" in out or "CMP" in out or "JL" in out, out[:200])

print("== reset ==")
out, err, rc = dbg(SIMPLE, ["step", "reset", "regs", "quit"])
check("reset restores PC", out.count("PC:") >= 1)
# After reset + step, R0 should be 42 again (re-executed)
out, err, rc = dbg(SIMPLE, ["run", "reset", "run", "quit"])
check("reset allows re-run",
      out.count("terminated: NORMAL (HALT), exit code 42") == 2, out[:300])

print("== max-steps ==")
out, err, rc = dbg(SIMPLE, ["set max-steps 500", "quit"])
check("set max-steps prints", "max-steps = 500" in out, out[:200])
out, err, rc = dbg(LOOP, ["set max-steps 2", "run", "quit"])
check("max-steps stops run", "MAX_STEPS" in out or "max" in out.lower(),
      out[:200])

print("== termination (D22) ==")
out, err, rc = dbg(DIVZERO, ["run", "quit"])
check("DIVISION_BY_ZERO fatal",
      "terminated: FATAL (DIVISION_BY_ZERO), exit code 106" in out, out[:200])
out, err, rc = dbg(HALT106, ["run", "quit"])
check("HALT 106 normal (D22)",
      "terminated: NORMAL (HALT), exit code 106" in out, out[:200])
# Commands after termination should be rejected
out, err, rc = dbg(SIMPLE, ["run", "step", "quit"])
check("step after halt rejected", "error" in out.lower() or
      "terminated" in out.lower(), out[:200])

print("== determinism ==")
out1, _, _ = dbg(LOOP, ["run", "quit"])
out2, _, _ = dbg(LOOP, ["run", "quit"])
check("deterministic run", out1 == out2)

print("== robustness ==")
# Long line (over buffer): should not crash, should handle gracefully
long_cmd = "x" * 300
out, err, rc = dbg(SIMPLE, [long_cmd, "quit"])
check("long line no crash", rc == 0, f"rc={rc}")
# Empty command
out, err, rc = dbg(SIMPLE, ["", "quit"])
check("empty line ok", rc == 0)
# Unknown command
out, err, rc = dbg(SIMPLE, ["frobnicate", "quit"])
check("unknown cmd error", "error" in out.lower() or "unknown" in out.lower(),
      out[:200])

print(f"\n{ PASS} passed, {FAIL} failed")
if FAILURES:
    print("failures:", FAILURES)
sys.exit(1 if FAIL else 0)
