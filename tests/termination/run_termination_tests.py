#!/usr/bin/env python3
"""Normative termination tests (D22 / TESTING.md section 10).

Proves the termination model of ISA.md section 6.1.1: the exit code, in
isolation, does NOT determine whether execution ended normally (HALT) or
fatally. Each fixture asserts the full
(termination_class, termination_reason, exit_code) triple.

What this script does NOW (no CPU yet):
  1. Rebuilds each .bin fixture from the normative code bytes below
     (hand-derived from the frozen spec, assembler-independent, like
     the L1 golden vectors) plus a spec-correct 26-byte header.
  2. Validates the container: magic, version, size equation
     (file_size == 0x1A + code_size + data_size), entry bounds.
  3. Runs an independent per-slot scan: opcode range, class tag matches
     the opcode's required class, register fields, imm32 rules.
  4. Asserts the cross-test properties: T2/T3 share exit 106 with
     different termination classes; T4/T5 share exit 105 with different
     termination classes.

What runs LATER (phase 3, CPU): each fixture is executed under
`aurora run` and the reported termination triple is asserted. Until the
loader/CPU exists, execution is skipped with a clear message.

Exit code: 0 if all fixture checks pass, 1 otherwise.
"""

import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXDIR = os.path.join(HERE, "fixtures")
REPO = os.path.dirname(os.path.dirname(HERE))
AURORA = os.path.join(REPO, "build", "aurora")

MAGIC = bytes([0x41, 0x55, 0x52, 0x4F, 0x52, 0x41, 0x01, 0x00])
VERSION = 0x0001

# opcode -> required class (only the opcodes used by these fixtures;
# full table lives in ISA.md section 6). Classes: N=0, R=1, I=2, r=3.
REQUIRED_CLASS = {0x01: 0, 0x03: 2, 0x0A: 1, 0x1E: 3}

# fatal error name -> id (frozen spec; exit code = 100 + id).
ERROR_IDS = {
    "INVALID_OPCODE": 1, "INVALID_REGISTER": 2, "INVALID_MEMORY_ACCESS": 3,
    "STACK_OVERFLOW": 4, "STACK_UNDERFLOW": 5, "DIVISION_BY_ZERO": 6,
    "INVALID_PC": 7, "INVALID_PROGRAM": 8, "INVALID_INSTRUCTION": 9,
    "MAX_STEPS_EXCEEDED": 10, "WRITE_TO_CODE": 11, "IO_ERROR": 12,
}

# name, code bytes (hand-derived from ISA.md/BYTECODE.md), expected triple.
FIXTURES = [
    {
        "name": "t1_halt0",
        "code": bytes.fromhex("0300ff0200000000" "01ffff0000000000"),
        "tclass": "NORMAL", "reason": "HALT", "exit": 0,
    },
    {
        "name": "t2_halt106",
        "code": bytes.fromhex("0300ff026a000000" "01ffff0000000000"),
        "tclass": "NORMAL", "reason": "HALT", "exit": 106,
    },
    {
        "name": "t3_divzero",
        "code": bytes.fromhex(
            "0301ff020a000000"   # MOV R1, 10
            "0302ff0200000000"   # MOV R2, 0
            "0a01020100000000"   # DIV R1, R2  -> DIVISION_BY_ZERO
            "01ffff0000000000"   # HALT (unreached)
        ),
        "tclass": "FATAL", "reason": "DIVISION_BY_ZERO", "exit": 106,
    },
    {
        "name": "t4_halt105",
        "code": bytes.fromhex("0300ff0269000000" "01ffff0000000000"),
        "tclass": "NORMAL", "reason": "HALT", "exit": 105,
    },
    {
        "name": "t5_underflow",
        "code": bytes.fromhex(
            "1eff000300000000"   # POP R0 on empty stack -> STACK_UNDERFLOW
            "01ffff0000000000"   # HALT (unreached)
        ),
        "tclass": "FATAL", "reason": "STACK_UNDERFLOW", "exit": 105,
    },
]

failures = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print("%s: %s%s" % (status, name, (" (%s)" % detail) if detail else ""))
    if not cond:
        failures.append(name)


def build_bin(code):
    header = (MAGIC + struct.pack("<H", VERSION)
              + struct.pack("<I", len(code))   # code_size
              + struct.pack("<I", 0)           # entry
              + struct.pack("<I", 0)           # data_size
              + struct.pack("<I", 0))          # reserved
    assert len(header) == 0x1A
    return header + code


def scan_slots(code, label):
    """Independent per-slot validation (mirrors BYTECODE.md section 2)."""
    ok = True
    for i in range(0, len(code), 8):
        slot = code[i:i + 8]
        op, dst, src, cls = slot[0], slot[1], slot[2], slot[3]
        imm = struct.unpack("<I", slot[4:8])[0]
        where = "%s slot %d" % (label, i // 8)
        if op > 0x2A:
            check(where + " opcode range", False, "0x%02x" % op)
            ok = False
            continue
        if op not in REQUIRED_CLASS:
            check(where + " opcode known-to-test", False, "0x%02x" % op)
            ok = False
            continue
        if cls != REQUIRED_CLASS[op]:
            check(where + " class tag", False,
                  "got %d want %d" % (cls, REQUIRED_CLASS[op]))
            ok = False
        if cls == 0:      # N
            good = dst == 0xFF and src == 0xFF and imm == 0
        elif cls == 1:    # R
            good = dst <= 0x0F and src <= 0x0F and imm == 0
        elif cls == 2:    # I
            good = dst <= 0x0F and src == 0xFF
        elif cls == 3:    # r
            good = dst == 0xFF and src <= 0x0F and imm == 0
        else:
            good = False
        if not good:
            check(where + " operand fields", False,
                  "op=0x%02x dst=0x%02x src=0x%02x cls=%d imm=0x%08x"
                  % (op, dst, src, cls, imm))
            ok = False
    return ok


def main():
    os.makedirs(FIXDIR, exist_ok=True)

    for fx in FIXTURES:
        blob = build_bin(fx["code"])
        path = os.path.join(FIXDIR, fx["name"] + ".bin")
        with open(path, "wb") as f:
            f.write(blob)

        # 1. container validation
        check(fx["name"] + " size equation",
              len(blob) == 0x1A + len(fx["code"]),
              "%d bytes" % len(blob))
        check(fx["name"] + " magic+version",
              blob[0:8] == MAGIC and struct.unpack("<H", blob[8:10])[0] == VERSION)
        code_size = struct.unpack("<I", blob[0x0A:0x0E])[0]
        entry = struct.unpack("<I", blob[0x0E:0x12])[0]
        check(fx["name"] + " header fields",
              code_size == len(fx["code"]) and entry < code_size
              and entry % 8 == 0)

        # 2. independent slot scan
        if scan_slots(fx["code"], fx["name"]):
            check(fx["name"] + " slot scan", True)

        # 3. expected triple self-consistency (spec rules, not execution)
        if fx["tclass"] == "NORMAL":
            check(fx["name"] + " triple",
                  fx["reason"] == "HALT" and 0 <= fx["exit"] <= 255)
        else:
            check(fx["name"] + " triple",
                  fx["reason"] in ERROR_IDS
                  and fx["exit"] == 100 + ERROR_IDS[fx["reason"]])

    # 4. the decisive cross-test properties (D22)
    by_name = {fx["name"]: fx for fx in FIXTURES}
    t2, t3 = by_name["t2_halt106"], by_name["t3_divzero"]
    check("T2/T3 same exit, different termination",
          t2["exit"] == t3["exit"] == 106
          and t2["tclass"] == "NORMAL" and t3["tclass"] == "FATAL"
          and t2["reason"] == "HALT" and t3["reason"] == "DIVISION_BY_ZERO",
          "exit=106: NORMAL/HALT vs FATAL/DIVISION_BY_ZERO")
    t4, t5 = by_name["t4_halt105"], by_name["t5_underflow"]
    check("T4/T5 same exit, different termination",
          t4["exit"] == t5["exit"] == 105
          and t4["tclass"] == "NORMAL" and t5["tclass"] == "FATAL"
          and t4["reason"] == "HALT" and t5["reason"] == "STACK_UNDERFLOW",
          "exit=105: NORMAL/HALT vs FATAL/STACK_UNDERFLOW")

    # 5. execution (phase 3): try one fixture; skip cleanly if no CPU yet.
    exec_failures = []
    probe = subprocess.run([AURORA, "run",
                            os.path.join(FIXDIR, "t1_halt0.bin")],
                           capture_output=True, text=True)
    if "not implemented" in probe.stderr and probe.returncode == 3:
        print("SKIP: execution checks (loader/CPU not implemented yet, phase 3)")
    else:
        for fx in FIXTURES:
            path = os.path.join(FIXDIR, fx["name"] + ".bin")
            p = subprocess.run([AURORA, "run", path],
                               capture_output=True, text=True)
            m = re.search(r"aurora: error: ([A-Z_]+)", p.stderr)
            if m:  # fatal: stderr names the error, exit = 100 + id
                got = ("FATAL", m.group(1), p.returncode)
                want = (fx["tclass"], fx["reason"], fx["exit"])
                ok = (got == want
                      and p.returncode == 100 + ERROR_IDS[m.group(1)])
            else:  # HALT: any exit 0..255, no error line
                ok = (fx["tclass"] == "NORMAL" and fx["reason"] == "HALT"
                      and p.returncode == fx["exit"]
                      and "aurora: error:" not in p.stderr)
            check(fx["name"] + " execution triple", ok,
                  "exit=%d stderr=%r" % (p.returncode, p.stderr.strip()[:60]))
            if not ok:
                exec_failures.append(fx["name"])

    print("---")
    if failures:
        print("%d FAILED" % len(failures))
        return 1
    print("all termination fixture checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
