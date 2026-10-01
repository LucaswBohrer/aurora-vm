#!/usr/bin/env python3
"""AURORA runtime ABI & services tests (Phase 6, L8).

Validates docs/RUNTIME.md against the reference implementation in
runtime/aurora_rt.asm:

- ABI contract: arguments (R0-R2), return (R0), preserved R3-R15/SP/FP,
  clobbered R1/R2/FLAGS;
- svc_exit: status codes, D22 NORMAL(HALT) classification;
- svc_write: valid/zero-length/boundary/invalid/overflow buffers, fd checks;
- svc_read: normal/EOF/empty/zero-length/invalid input, short counts;
- memory safety: no corruption of unrelated memory, SP/FP/PC correct;
- debugger: step/run/breakpoint/reset over service calls;
- determinism: repeated runs byte-identical;
- independence: frozen golden fixtures + one fully hand-encoded program.

Linking: guest sources are concatenated AFTER nothing / BEFORE the
library is wrong — the guest program comes FIRST so entry 0 is guest
code (see docs/RUNTIME.md §3):

    cat prog.asm runtime/aurora_rt.asm > linked.asm

Exit 0 = all pass, 1 = failures.
"""
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(REPO, "build", "aurora")
ASM = os.path.join(REPO, "tools", "aurora-asm")
LIB = os.path.join(REPO, "runtime", "aurora_rt.asm")
FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

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

def link(name, prog_src):
    """prog_src (str) + runtime library -> assembled temp .bin path."""
    d = tempfile.mkdtemp(prefix="rttest_")
    lp = os.path.join(d, name + ".linked.asm")
    bp = os.path.join(d, name + ".bin")
    with open(lp, "w") as f:
        f.write(prog_src)
        f.write(open(LIB).read())
    r = subprocess.run([sys.executable, ASM, lp, "-o", bp],
                       capture_output=True, text=True)
    assert r.returncode == 0, f"asm failed for {name}: {r.stderr}"
    return bp

def runb(binpath, stdin_bytes=b"", stdout_to=None, timeout=10):
    """aurora run. stdout_to: path to redirect stdout to (e.g. /dev/full)."""
    if stdout_to is None:
        r = subprocess.run([BIN, "run", binpath], input=stdin_bytes,
                           capture_output=True, timeout=timeout)
        return r.stdout, r.stderr, r.returncode
    with open(stdout_to, "wb") as f:
        r = subprocess.run([BIN, "run", binpath], input=stdin_bytes,
                           stdout=f, stderr=subprocess.PIPE, timeout=timeout)
        return b"", r.stderr, r.returncode

def dbg(binpath, commands, timeout=10):
    """aurora debug with piped commands. Returns (stdout, stderr, rc)."""
    inp = "\n".join(commands) + "\n"
    r = subprocess.run([BIN, "debug", binpath], input=inp,
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout, r.stderr, r.returncode

# ------------------------------------------------------------------ programs
# Each program is linked with the runtime library (guest first).

# write 5 bytes, then OUT the return count
P_WCOUNT = link("wcount",
    "MOV R0, 1\nMOV R1, msg\nMOV R2, 5\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\nmsg: DB \"hello\"\n")

# write 5 bytes, then HALT directly (R0 keeps the return value)
P_WRET = link("wret",
    "MOV R0, 1\nMOV R1, msg\nMOV R2, 5\nCALL svc_write\n"
    "HALT\nmsg: DB \"hello\"\n")

# R3/R15 preservation across svc_write
P_WPRES = link("wpres",
    "MOV R3, 0x12345678\nMOV R15, 0xABCDEF\n"
    "MOV R0, 1\nMOV R1, msg\nMOV R2, 3\nCALL svc_write\n"
    "OUT R3\nOUT R15\nMOV R0, 0\nHALT\nmsg: DB \"bye\"\n")

# invalid fd for write
P_WBADFD = link("wbadfd",
    "MOV R0, 7\nMOV R1, msg\nMOV R2, 3\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\nmsg: DB \"bye\"\n")

# zero-length write
P_WZERO = link("wzero",
    "MOV R0, 1\nMOV R1, msg\nMOV R2, 0\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\nmsg: DB \"bye\"\n")

# buffer crossing the end of memory: buf=0xFFFF, len=2
P_WOVER = link("wover",
    "MOV R0, 1\nMOV R1, 0xFFFF\nMOV R2, 2\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\n")

# huge buffer address: MOV R1, -1 -> 0xFFFFFFFFFFFFFFFF (bit 63 set)
P_WHUGE = link("whuge",
    "MOV R0, 1\nMOV R1, -1\nMOV R2, 1\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\n")

# len with bit 63 set (MOV R2, -1)
P_WLEN63 = link("wlen63",
    "MOV R0, 1\nMOV R1, msg\nMOV R2, -1\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\nmsg: DB \"bye\"\n")

# len > 0x10000
P_WBIGLEN = link("wbiglen",
    "MOV R0, 1\nMOV R1, msg\nMOV R2, 0x10001\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\nmsg: DB \"bye\"\n")

# last five bytes before the stack region: store ABCDE at 0xEFFB..0xEFFF.
# (0xFFFB would work for the bounds check, but the CALL's own frame uses
# the live stack 0xFFE0..0xFFFF and would clobber it — inherent guest
# behavior for any nested call, not a service bug.)
P_WTAIL = link("wtail",
    "MOV R3, 0xEFFB\n"
    "MOV R4, 65\nSTOREB [R3], R4\n"
    "ADD R3, 1\nMOV R4, 66\nSTOREB [R3], R4\n"
    "ADD R3, 1\nMOV R4, 67\nSTOREB [R3], R4\n"
    "ADD R3, 1\nMOV R4, 68\nSTOREB [R3], R4\n"
    "ADD R3, 1\nMOV R4, 69\nSTOREB [R3], R4\n"
    "MOV R0, 1\nMOV R1, 0xEFFB\nMOV R2, 5\nCALL svc_write\n"
    "MOV R0, 0\nHALT\n")

# read from code segment start (allowed): 8 bytes
P_WCODE = link("wcode",
    "MOV R0, 1\nMOV R1, 0\nMOV R2, 8\nCALL svc_write\n"
    "OUT R0\nMOV R0, 0\nHALT\n")

# exit variants
P_EXIT0 = link("exit0", "MOV R0, 0\nCALL svc_exit\n")
P_EXIT42 = link("exit42", "MOV R0, 42\nCALL svc_exit\n")
P_EXIT106 = link("exit106", "MOV R0, 106\nCALL svc_exit\n")
P_EXIT256 = link("exit256", "MOV R0, 256\nCALL svc_exit\n")

# read: stdin -> buffer -> echo back; OUT the count first
P_READ = link("read",
    "MOV R0, 0\nMOV R1, buf\nMOV R2, 16\nCALL svc_read\n"
    "OUT R0\n"
    "MOV R2, R0\nMOV R0, 1\nMOV R1, buf\nCALL svc_write\n"
    "MOV R0, 0\nHALT\n"
    "buf: DB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0\n")

# read with len=0 over a pre-filled buffer; then write the buffer back
P_READZERO = link("readzero",
    "MOV R0, 0\nMOV R1, buf\nMOV R2, 0\nCALL svc_read\n"
    "OUT R0\n"
    "MOV R0, 1\nMOV R1, buf\nMOV R2, 4\nCALL svc_write\n"
    "MOV R0, 0\nHALT\n"
    "buf: DB 0xAA, 0xAA, 0xAA, 0xAA\n")

# read with invalid fd
P_RBADFD = link("rbadfd",
    "MOV R0, 1\nMOV R1, buf\nMOV R2, 4\nCALL svc_read\n"
    "OUT R0\nMOV R0, 0\nHALT\n"
    "buf: DB 0, 0, 0, 0\n")

# read with out-of-range buffer
P_RBADBUF = link("rbadbuf",
    "MOV R0, 0\nMOV R1, 0xFFFF\nMOV R2, 8\nCALL svc_read\n"
    "OUT R0\nMOV R0, 0\nHALT\n")

# read into the code segment -> WRITE_TO_CODE (fatal), like direct STOREB
P_RCODE = link("rcode",
    "MOV R0, 0\nMOV R1, 8\nMOV R2, 4\nCALL svc_read\n"
    "MOV R0, 0\nHALT\n")

# PC continues correctly after the call: marker in R5 after return
P_PCMARK = link("pcmark",
    "MOV R0, 1\nMOV R1, msg\nMOV R2, 2\nCALL svc_write\n"
    "MOV R5, 0xBEEF\nOUT R5\nMOV R0, 0\nHALT\nmsg: DB \"hi\"\n")

# unrelated memory must survive services: pattern at 0x2000
P_MEMOK = link("memok",
    "MOV R3, 0x2000\nMOV R4, 0x5A6B7C8D\nSTORE [R3], R4\n"
    "MOV R0, 1\nMOV R1, msg\nMOV R2, 2\nCALL svc_write\n"
    "MOV R0, 0\nMOV R1, buf\nMOV R2, 4\nCALL svc_read\n"
    "LOAD R5, [R3]\nOUT R5\nMOV R0, 0\nHALT\n"
    "msg: DB \"hi\"\nbuf: DB 0, 0, 0, 0\n")

print("== ABI: svc_write ==")
out, err, rc = runb(P_WCOUNT)
check("write returns byte count", out == b"hello5\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WPRES)
check("write preserves R3-R15", out == b"bye305419896\n11259375\n" and rc == 0,
      f"out={out!r} rc={rc}")
# 0x12345678 = 305419896, 0xABCDEF = 11259375

out, err, rc = runb(P_WBADFD)
check("write invalid fd -> -1, no output", out == b"-1\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WZERO)
check("write len=0 -> 0, no output", out == b"0\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WOVER)
check("write buf=0xFFFF len=2 -> -1", out == b"-1\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WHUGE)
check("write huge buf -> -1", out == b"-1\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WLEN63)
check("write len=-1 (bit63) -> -1", out == b"-1\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WBIGLEN)
check("write len=0x10001 -> -1", out == b"-1\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WTAIL)
check("write 5 bytes at 0xEFFB", out == b"ABCDE" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_WCODE)
check("write from addr 0 returns 8", out[8:] == b"8\n" and len(out) == 10
      and rc == 0, f"out={out!r} rc={rc}")

print("== ABI: svc_exit ==")
out, err, rc = runb(P_EXIT0)
check("exit 0: rc 0, silent", rc == 0 and out == b"" and err == b"",
      f"rc={rc} out={out!r} err={err!r}")

out, err, rc = runb(P_EXIT42)
check("exit 42", rc == 42 and err == b"", f"rc={rc} err={err!r}")

out, err, rc = runb(P_EXIT106)
check("exit 106 is NORMAL (D22)", rc == 106 and b"aurora: error" not in err,
      f"rc={rc} err={err!r}")

out, err, rc = runb(P_EXIT256)
check("exit 256 wraps to 0 (R0 & 0xFF)", rc == 0, f"rc={rc}")

print("== ABI: svc_read ==")
out, err, rc = runb(P_READ, b"hello")
check("read 5 bytes + echo", out == b"5\nhello" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_READ, b"")
check("read empty stdin -> 0", out == b"0\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_READ, b"ab")
check("read short (2 of 16)", out == b"2\nab" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_READZERO, b"xyz")
check("read len=0 -> 0, buffer untouched",
      out == b"0\n\xaa\xaa\xaa\xaa" and rc == 0, f"out={out!r} rc={rc}")

out, err, rc = runb(P_RBADFD, b"xyz")
check("read invalid fd -> -1", out == b"-1\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_RBADBUF, b"xyz")
check("read bad bounds -> -1", out == b"-1\n" and rc == 0,
      f"out={out!r} rc={rc}")

out, err, rc = runb(P_RCODE, b"abcd")
check("read into code -> FATAL WRITE_TO_CODE",
      rc == 111 and b"aurora: error: WRITE_TO_CODE" in err,
      f"rc={rc} err={err!r}")

print("== CPU / memory integrity ==")
out, err, rc = runb(P_PCMARK)
check("PC continues after CALL", out == b"hi48879\n" and rc == 0,
      f"out={out!r} rc={rc}")
# 0xBEEF = 48879

out, err, rc = runb(P_MEMOK, b"test")
check("unrelated memory intact", out == b"hi1516993677\n" and rc == 0,
      f"out={out!r} rc={rc}")
# 0x5A6B7C8D = 1516993677

out, err, rc = dbg(P_WCOUNT, ["run", "regs", "quit"])
check("debugger regs: SP/FP balanced after service",
      "SP: 0x0000000000010000" in out and "FP: 0x0000000000010000" in out,
      out[:300])
out, err, rc = dbg(P_WRET, ["run", "regs", "quit"])
check("debugger regs: R0 = return count 5", "R0: 0x0000000000000005" in out,
      out[:300])

print("== debugger over services ==")
# program layout: 0x00 MOV R0,1 / 0x08 MOV R1,msg / 0x10 MOV R2,5 /
#                 0x18 CALL svc_write / 0x20 OUT R0 / 0x28 MOV R0,0 / 0x30 HALT
out, err, rc = dbg(P_WCOUNT, ["break 24", "run", "quit"])
check("breakpoint at CALL hit", "stopped at breakpoint 0x00000018" in out,
      out[:200])
out, err, rc = dbg(P_WCOUNT, ["break 24", "run", "step 3", "regs", "quit"])
check("step into service: SP reflects CALL+2 PUSH",
      "SP: 0x000000000000FFE0" in out, out[:400])
out, err, rc = dbg(P_WCOUNT, ["break 24", "run", "continue", "quit"])
check("continue runs service to HALT",
      "terminated: NORMAL (HALT), exit code 0" in out, out[:200])
out, err, rc = dbg(P_WCOUNT, ["break 32", "run", "regs", "quit"])
check("breakpoint after CALL: R0 = 5", "R0: 0x0000000000000005" in out,
      out[:400])
out, err, rc = dbg(P_WCOUNT, ["run", "reset", "run", "quit"])
n = out.count("terminated: NORMAL (HALT), exit code 0")
check("reset re-runs the service", n == 2, f"n={n} out={out[:200]!r}")

print("== determinism ==")
a = runb(P_WCOUNT)
b = runb(P_WCOUNT)
check("write deterministic", a == b, f"{a} vs {b}")
a = runb(P_READ, b"hello deterministic")
b = runb(P_READ, b"hello deterministic")
check("read deterministic", a == b, f"{a} vs {b}")

print("== IO_ERROR propagation ==")
_, err, rc = runb(P_WCOUNT, stdout_to="/dev/full")
check("write to /dev/full -> FATAL IO_ERROR",
      rc == 112 and b"aurora: error: IO_ERROR" in err,
      f"rc={rc} err={err!r}")

print("== independence: golden fixtures (no assembler) ==")
# Frozen binaries, generated once by the assembler and hand-verified
# (header magic/version/sizes + spot disassembly via `aurora debug`).
# They must keep passing even if the assembler changes.
for name, want_out, want_rc in [
    ("hello_runtime.bin", b"Hello, runtime!\n", 0),
    ("exit_runtime.bin", b"", 42),
    ("io_runtime.bin", None, 0),  # stdin-driven; checked below
]:
    p = os.path.join(FIX, name)
    if not os.path.exists(p):
        check(f"fixture {name} exists", False, "missing file")
        continue
    out, err, rc = runb(p)
    ok = (out == want_out and rc == want_rc) if want_out is not None else (rc == want_rc)
    check(f"fixture {name}", ok, f"out={out!r} rc={rc}")
out, err, rc = runb(os.path.join(FIX, "io_runtime.bin"), b"fixture-stdin")
check("fixture io_runtime echo", out == b"fixture-stdin" and rc == 0,
      f"out={out!r} rc={rc}")

print("== independence: fully hand-encoded program ==")
# Hand-built bytes, no assembler and no runtime library involved.
#   MOV_RI R0, 72 ; OUTC R0 ; MOV_RI R0, 105 ; OUTC R0 ; HALT
# Encoded per ISA §4: op dst src class imm32(le).
def instr(op, dst=0xFF, src=0xFF, cls=0, imm=0):
    import struct
    return struct.pack("<BBBBi", op, dst, src, cls, imm)
code = (instr(0x03, 0x00, 0xFF, 0x02, 72) +     # MOV R0, 72 ('H')
        instr(0x29, 0xFF, 0x00, 0x03) +          # OUTC R0
        instr(0x03, 0x00, 0xFF, 0x02, 105) +    # MOV R0, 105 ('i')
        instr(0x29, 0xFF, 0x00, 0x03) +          # OUTC R0
        instr(0x01, 0xFF, 0xFF, 0x00))           # HALT
import struct as _s
hdr = b"AURORA\x01\x00" + _s.pack("<H", 1) + _s.pack("<III",
      len(code), 0, 0) + _s.pack("<I", 0)
d = tempfile.mkdtemp(prefix="rthand_")
hp = os.path.join(d, "hand.bin")
open(hp, "wb").write(hdr + code)
out, err, rc = runb(hp)
check("hand-encoded 'Hi' program", out == b"Hi" and rc == 105 and err == b"",
      f"out={out!r} rc={rc} err={err!r}")
# rc=105: HALT exits R0 & 0xFF, and R0 still holds 'i' (105) — by design.

print(f"\n{PASS} passed, {FAIL} failed")
if FAILURES:
    print("failures:", ", ".join(FAILURES))
sys.exit(1 if FAIL else 0)
