#!/usr/bin/env python3
"""Opcode field audit: cross-check every opcode's encoding against ISA.md §6.

Normative source: docs/ISA.md §6 (opcode table) and §12 (golden vectors V1-V9).
This script verifies that src/loader.asm accepts exactly the normative
(dst, src, class, imm32) placement for each of the 43 opcodes and rejects
field swaps / wrong classes / bad registers / nonzero imm32.

Regression test for the Phase-2 bug where class-r validation required
dst=0xFF,src=reg for ALL r-class opcodes, rejecting the normative
POP/INC/DEC/NOT/IN encoding (dst=reg,src=0xFF) from ISA.md §12 V6.

Two modes (auto-detected):
  - loader-only (pre-CPU):  valid program -> exit 3 (phase-2 scaffolding)
  - full (CPU present):     valid program -> executes; per-probe exit/stdout asserted

Usage: python3 tests/byte/audit_opcode_fields.py [path/to/aurora]
"""
import os
import struct
import subprocess
import sys
import tempfile

AURORA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "aurora")

PASS = 0
FAIL = 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append("%s %s" % (name, detail))


def slot(op, dst=0xFF, src=0xFF, cls=0, imm=0):
    return bytes([op, dst, src, cls]) + struct.pack("<I", imm)


def build_file(code, entry=0, data=b""):
    hdr = (bytes.fromhex("4155524f52410100") + struct.pack("<H", 1)
           + struct.pack("<I", len(code)) + struct.pack("<I", entry)
           + struct.pack("<I", len(data)) + struct.pack("<I", 0))
    return hdr + code + data


HALT = slot(0x01)

# Normative per-opcode table transcribed from ISA.md §6.
# cls: operand class byte. rd_rs: for class r, which byte holds the register
#   ('dst' for Rd-named: INC/DEC/NOT/POP/IN; 'src' for Rs-named: PUSH/OUT/OUTC).
NORM = {
    0x00: dict(cls=0, name="NOP"),
    0x01: dict(cls=0, name="HALT"),
    0x02: dict(cls=1, name="MOV_RR"),
    0x03: dict(cls=2, name="MOV_RI"),
    0x04: dict(cls=1, name="ADD_RR"),
    0x05: dict(cls=2, name="ADD_RI"),
    0x06: dict(cls=1, name="SUB_RR"),
    0x07: dict(cls=2, name="SUB_RI"),
    0x08: dict(cls=1, name="MUL_RR"),
    0x09: dict(cls=2, name="MUL_RI"),
    0x0A: dict(cls=1, name="DIV_RR"),
    0x0B: dict(cls=2, name="DIV_RI"),
    0x0C: dict(cls=3, name="INC", rd_rs="dst"),
    0x0D: dict(cls=3, name="DEC", rd_rs="dst"),
    0x0E: dict(cls=1, name="AND_RR"),
    0x0F: dict(cls=2, name="AND_RI"),
    0x10: dict(cls=1, name="OR_RR"),
    0x11: dict(cls=2, name="OR_RI"),
    0x12: dict(cls=1, name="XOR_RR"),
    0x13: dict(cls=2, name="XOR_RI"),
    0x14: dict(cls=3, name="NOT", rd_rs="dst"),
    0x15: dict(cls=1, name="CMP_RR"),
    0x16: dict(cls=2, name="CMP_RI"),
    0x17: dict(cls=4, name="LOAD_M"),
    0x18: dict(cls=1, name="LOAD_R"),
    0x19: dict(cls=4, name="STORE_M"),
    0x1A: dict(cls=1, name="STORE_R"),
    0x1B: dict(cls=1, name="LOADB_R"),
    0x1C: dict(cls=1, name="STOREB_R"),
    0x1D: dict(cls=3, name="PUSH", rd_rs="src"),
    0x1E: dict(cls=3, name="POP", rd_rs="dst"),
    0x1F: dict(cls=5, name="CALL"),
    0x20: dict(cls=0, name="RET"),
    0x21: dict(cls=5, name="JMP"),
    0x22: dict(cls=5, name="JE"),
    0x23: dict(cls=5, name="JNE"),
    0x24: dict(cls=5, name="JG"),
    0x25: dict(cls=5, name="JL"),
    0x26: dict(cls=5, name="JGE"),
    0x27: dict(cls=5, name="JLE"),
    0x28: dict(cls=3, name="OUT", rd_rs="src"),
    0x29: dict(cls=3, name="OUTC", rd_rs="src"),
    0x2A: dict(cls=3, name="IN", rd_rs="dst"),
}
assert len(NORM) == 43 and set(NORM) == set(range(0x2B))


def run_prog(code, stdin_data=b""):
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(build_file(code))
        path = f.name
    try:
        p = subprocess.run([AURORA, "run", path], input=stdin_data,
                           capture_output=True, timeout=20)
        return p.returncode, p.stdout, p.stderr
    finally:
        os.unlink(path)


def main():
    # Mode detection: a HALT-only program exits 3 on the phase-2 scaffolding,
    # 0 once the CPU executes.
    rc, _, _ = run_prog(HALT)
    full = (rc != 3)
    print("audit mode: %s" % ("full (CPU executes)" if full else "loader-only"))

    # ---- Positive probes: normative encoding must be accepted ----
    # Each entry: (opcode, code bytes, expected exit, expected stdout)
    # All probes are execution-safe and end in HALT.
    P = []
    P.append((0x00, slot(0x00) + HALT, 0, b""))
    P.append((0x01, HALT, 0, b""))
    P.append((0x02, slot(0x02, dst=5, src=6, cls=1) + HALT, 0, b""))
    P.append((0x03, slot(0x03, dst=7, cls=2, imm=0xFFFFFFFF) + HALT, 0, b""))
    P.append((0x04, slot(0x04, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x05, slot(0x05, dst=0, cls=2, imm=5) + HALT, 5, b""))
    P.append((0x06, slot(0x06, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x07, slot(0x07, dst=0, cls=2, imm=1) + HALT, 255, b""))
    P.append((0x08, slot(0x08, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x09, slot(0x09, dst=0, cls=2, imm=3) + HALT, 0, b""))
    P.append((0x0A, slot(0x03, dst=1, cls=2, imm=7)
              + slot(0x0A, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x0B, slot(0x03, dst=0, cls=2, imm=9)
              + slot(0x0B, dst=0, cls=2, imm=2) + HALT, 4, b""))
    P.append((0x0C, slot(0x0C, dst=8, cls=3) + HALT, 0, b""))
    P.append((0x0D, slot(0x0D, dst=8, cls=3) + HALT, 0, b""))
    P.append((0x0E, slot(0x0E, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x0F, slot(0x03, dst=0, cls=2, imm=0xFFFFFFFF)
              + slot(0x0F, dst=0, cls=2, imm=0xFF) + HALT, 255, b""))
    P.append((0x10, slot(0x10, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x11, slot(0x11, dst=0, cls=2, imm=5) + HALT, 5, b""))
    P.append((0x12, slot(0x12, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x13, slot(0x03, dst=0, cls=2, imm=7)
              + slot(0x13, dst=0, cls=2, imm=7) + HALT, 0, b""))
    P.append((0x14, slot(0x03, dst=8, cls=2, imm=0)
              + slot(0x14, dst=8, cls=3) + HALT, 0, b""))
    P.append((0x15, slot(0x15, dst=0, src=1, cls=1) + HALT, 0, b""))
    P.append((0x16, slot(0x16, dst=0, cls=2, imm=0) + HALT, 0, b""))
    P.append((0x17, slot(0x17, dst=2, cls=4, imm=0x1000) + HALT, 0, b""))
    P.append((0x18, slot(0x03, dst=1, cls=2, imm=0x1000)
              + slot(0x18, dst=2, src=1, cls=1) + HALT, 0, b""))
    P.append((0x19, slot(0x19, src=6, cls=4, imm=0xE000) + HALT, 0, b""))
    P.append((0x1A, slot(0x03, dst=5, cls=2, imm=0xE008)
              + slot(0x1A, dst=5, src=1, cls=1) + HALT, 0, b""))
    P.append((0x1B, slot(0x03, dst=1, cls=2, imm=0x1000)
              + slot(0x1B, dst=2, src=1, cls=1) + HALT, 0, b""))
    P.append((0x1C, slot(0x03, dst=5, cls=2, imm=0xE010)
              + slot(0x1C, dst=5, src=1, cls=1) + HALT, 0, b""))
    P.append((0x1D, slot(0x1D, src=4, cls=3) + HALT, 0, b""))
    P.append((0x1E, slot(0x1D, src=4, cls=3)
              + slot(0x1E, dst=3, cls=3) + HALT, 0, b""))
    # CALL 0x10; HALT; RET  (RET is exercised as the callee epilogue)
    P.append((0x1F, slot(0x1F, cls=5, imm=0x10) + HALT + slot(0x20), 0, b""))
    P.append((0x20, slot(0x1F, cls=5, imm=0x10) + HALT + slot(0x20), 0, b""))
    P.append((0x21, slot(0x21, cls=5, imm=0x08) + HALT, 0, b""))
    # JE taken (Z=1) -> skips to 0x18
    P.append((0x22, slot(0x15, dst=0, src=1, cls=1)
              + slot(0x22, cls=5, imm=0x18) + HALT + HALT, 0, b""))
    # JNE not taken (Z=1) -> falls through
    P.append((0x23, slot(0x15, dst=0, src=1, cls=1)
              + slot(0x23, cls=5, imm=0x18) + HALT + HALT, 0, b""))
    # JG taken: 5 > 3
    P.append((0x24, slot(0x03, dst=0, cls=2, imm=5)
              + slot(0x03, dst=1, cls=2, imm=3)
              + slot(0x15, dst=0, src=1, cls=1)
              + slot(0x24, cls=5, imm=0x28) + HALT + HALT, 5, b""))
    # JL taken: 3 < 5
    P.append((0x25, slot(0x03, dst=0, cls=2, imm=3)
              + slot(0x03, dst=1, cls=2, imm=5)
              + slot(0x15, dst=0, src=1, cls=1)
              + slot(0x25, cls=5, imm=0x28) + HALT + HALT, 3, b""))
    # JGE taken: 0 >= 0
    P.append((0x26, slot(0x15, dst=0, src=1, cls=1)
              + slot(0x26, cls=5, imm=0x18) + HALT + HALT, 0, b""))
    # JLE taken: 0 <= 0 (Z=1)
    P.append((0x27, slot(0x15, dst=0, src=1, cls=1)
              + slot(0x27, cls=5, imm=0x18) + HALT + HALT, 0, b""))
    P.append((0x28, slot(0x03, dst=4, cls=2, imm=42)
              + slot(0x28, src=4, cls=3) + HALT, 0, b"42\n"))
    P.append((0x29, slot(0x03, dst=4, cls=2, imm=65)
              + slot(0x29, src=4, cls=3) + HALT, 0, b"A"))
    # IN with EOF on stdin -> Rd = 0xFFFF...F; R0 untouched -> exit 0
    P.append((0x2A, slot(0x2A, dst=3, cls=3) + HALT, 0, b""))

    for op, code, exp_exit, exp_out in P:
        name = "accept %02x/%s" % (op, NORM[op]["name"])
        rc, out, err = run_prog(code)
        if full:
            check(name, rc == exp_exit and out == exp_out and err == b"",
                  "rc=%d out=%r err=%r" % (rc, out, err))
        else:
            check(name, rc == 3, "rc=%d err=%r" % (rc, err))

    # ---- Negative: wrong class byte for every opcode ----
    for op in range(0x2B):
        norm_cls = NORM[op]["cls"]
        wrong = (norm_cls + 1) % 6
        # normative fields, wrong class
        if norm_cls == 1:
            s = slot(op, dst=0, src=1, cls=wrong)
        elif norm_cls == 2:
            s = slot(op, dst=0, cls=wrong, imm=1)
        elif norm_cls == 3:
            rr = NORM[op].get("rd_rs", "dst")
            s = slot(op, dst=0, cls=wrong) if rr == "dst" else slot(op, src=0, cls=wrong)
        elif norm_cls == 4:
            s = slot(op, dst=0, cls=wrong, imm=0x1000)
        elif norm_cls == 5:
            s = slot(op, cls=wrong, imm=8) + HALT
        else:
            s = slot(op, cls=wrong)
        if norm_cls != 5:
            s += HALT
        rc, _, err = run_prog(s)
        check("reject bad-class %02x/%s" % (op, NORM[op]["name"]),
              rc == 109 and b"INVALID_INSTRUCTION" in err,
              "rc=%d err=%r" % (rc, err))

    # ---- Negative: class-r field placement ----
    for op in range(0x2B):
        if NORM[op]["cls"] != 3:
            continue
        nm = NORM[op]["name"]
        rr = NORM[op]["rd_rs"]
        # swapped: register in the wrong byte
        s = (slot(op, src=7, cls=3) if rr == "dst" else slot(op, dst=7, cls=3)) + HALT
        rc, _, err = run_prog(s)
        check("reject swapped-r %02x/%s" % (op, nm),
              rc == 109 and b"INVALID_INSTRUCTION" in err,
              "rc=%d err=%r" % (rc, err))
        # bad register value 0x10 in the normative byte
        s = (slot(op, dst=0x10, cls=3) if rr == "dst"
             else slot(op, src=0x10, cls=3)) + HALT
        rc, _, err = run_prog(s)
        check("reject badreg-r %02x/%s" % (op, nm),
              rc == 109 and b"INVALID_INSTRUCTION" in err,
              "rc=%d err=%r" % (rc, err))
        # nonzero imm32
        s = (slot(op, dst=7, cls=3, imm=1) if rr == "dst"
             else slot(op, src=7, cls=3, imm=1)) + HALT
        rc, _, err = run_prog(s)
        check("reject nzimm-r %02x/%s" % (op, nm),
              rc == 109 and b"INVALID_INSTRUCTION" in err,
              "rc=%d err=%r" % (rc, err))

    # ---- M-class address boundary (loader rule: imm32 <= 0x10000-8) ----
    rc, out, err = run_prog(slot(0x17, dst=2, cls=4, imm=0xFFF8) + HALT)
    check("accept LOAD_M max addr", (rc == 3) if not full else (rc == 0 and err == b""),
          "rc=%d err=%r" % (rc, err))
    for op, nm in ((0x17, "LOAD_M"), (0x19, "STORE_M")):
        s = (slot(op, dst=2, cls=4, imm=0xFFF9) if op == 0x17
             else slot(op, src=2, cls=4, imm=0xFFF9)) + HALT
        rc, _, err = run_prog(s)
        check("reject %s addr 0xFFF9" % nm,
              rc == 109 and b"INVALID_INSTRUCTION" in err,
              "rc=%d err=%r" % (rc, err))

    # ---- Golden vectors V1-V9: exact bytes from ISA.md §12 ----
    GV = [
        ("V1", 24, "0301FF020A000000" "0200010100000000" "01FFFF0000000000", 10, b""),
        ("V2", 16, "0305FF02FFFFFFFF" "01FFFF0000000000", 0, b""),
        ("V3", 32, "0300FF02FFFFFFFF" "0301FF0201000000"
                   "0400010100000000" "01FFFF0000000000", 0, b""),
        ("V4", 32, "0300FF020A000000" "0301FF0214000000"
                   "0600010100000000" "01FFFF0000000000", 246, b""),
        ("V5", 64, "0300FF0205000000" "0301FF0205000000"
                   "1500010100000000" "22FFFF0530000000"
                   "0302FF0200000000" "01FFFF0000000000"
                   "0302FF0201000000" "01FFFF0000000000", 5, b""),
        ("V6", 40, "0300FF022A000000" "1DFF000300000000"
                   "0300FF0200000000" "1E01FF0300000000"
                   "01FFFF0000000000", 0, b""),
        ("V7", 32, "1FFFFF0510000000" "01FFFF0000000000"
                   "0300FF0207000000" "20FFFF0000000000", 7, b""),
        ("V8", 48, "0300FF0200100000" "0301FF025A5A0000"
                   "1A00010100000000" "0302FF0200000000"
                   "1702FF0400100000" "01FFFF0000000000", 0, b""),
        ("V9", 16, "0300FF02C8000000" "01FFFF0000000000", 200, b""),
    ]
    for name, csize, hexcode, exp_exit, exp_out in GV:
        code = bytes.fromhex(hexcode)
        assert len(code) == csize, name
        rc, out, err = run_prog(code)
        if full:
            check("golden %s executes" % name,
                  rc == exp_exit and out == exp_out and err == b"",
                  "rc=%d out=%r err=%r" % (rc, out, err))
        else:
            check("golden %s loads" % name, rc == 3,
                  "rc=%d err=%r" % (rc, err))

    print("PASS: %d  FAIL: %d" % (PASS, FAIL))
    for f in FAILURES:
        print("FAIL:", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
