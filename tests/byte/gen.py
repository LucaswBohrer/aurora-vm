#!/usr/bin/env python3
"""tests/byte/gen.py — L3 fixture generator (phase 2).

Generates malformed bytecode files, each exercising one normative loader
rejection from docs/BYTECODE.md §4, plus valid boundary fixtures the
loader must ACCEPT. Every case is built by hand from explicit bytes —
independent of any assembler (the assembler is a phase-5 tool).

Output: tests/byte/fixtures/<name>.bin  (directory is gitignored)
Manifest: tests/byte/fixtures/manifest.tsv  (name, exit, substrings...)

Usage: python3 tests/byte/gen.py
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")

MAGIC = bytes.fromhex("4155524f52410100")
VERSION = struct.pack("<H", 1)


def build_file(code: bytes, entry: int = 0, data: bytes = b"",
               magic: bytes = MAGIC, version: bytes = VERSION,
               reserved: bytes = b"\x00\x00\x00\x00",
               code_size_override=None) -> bytes:
    code_size = len(code) if code_size_override is None else code_size_override
    header = (magic + version
              + struct.pack("<I", code_size)
              + struct.pack("<I", entry)
              + struct.pack("<I", len(data))
              + reserved)
    assert len(header) == 0x1A
    return header + code + data


def slot(op, dst=0xFF, src=0xFF, cls=0, imm=0) -> bytes:
    return bytes([op, dst, src, cls]) + struct.pack("<I", imm)


HALT = slot(0x01)                       # 01 FF FF 00 00000000
MOV_R0_0 = slot(0x03, dst=0x00, cls=0x02, imm=0)  # 03 00 FF 02 00000000

# Two-slot base (42 bytes total): MOV R0,0 ; HALT
BASE2_CODE = MOV_R0_0 + HALT

# Each case: (name, file_bytes, expected_exit, [expected stderr substrings])
CASES = []

# ---------- valid fixtures (loader must accept; run then hits phase-2 stub) --
CASES.append(("valid_halt", build_file(HALT), 3,
              ["not implemented in this build"]))
CASES.append(("valid_data", build_file(HALT, data=b"ABCD"), 3,
              ["not implemented in this build"]))
CASES.append(("valid_jmp_last",
              build_file(slot(0x21, cls=0x05, imm=8) + HALT), 3,
              ["not implemented in this build"]))
CASES.append(("valid_loadm_max",
              build_file(slot(0x17, dst=0x00, cls=0x04, imm=0xFFF8) + HALT), 3,
              ["not implemented in this build"]))
CASES.append(("valid_entry_last",
              build_file(BASE2_CODE, entry=8), 3,
              ["not implemented in this build"]))
CASES.append(("valid_layout_max",
              build_file(HALT, data=b"\x00" * (0xF000 - 8)), 3,
              ["not implemented in this build"]))
CASES.append(("valid_all_classes",
              build_file(
                  slot(0x01) +                                    # N  HALT-ish NOP
                  slot(0x02, dst=0x01, src=0x02, cls=0x01) +      # R  MOV
                  slot(0x03, dst=0x01, cls=0x02, imm=0xFFFFFFFF) +  # I  MOV max imm
                  slot(0x0C, src=0x03, cls=0x03) +               # r  INC
                  slot(0x17, dst=0x04, cls=0x04, imm=0) +        # M  LOAD [0]
                  slot(0x19, src=0x05, cls=0x04, imm=0xFFF8) +   # M  STORE max
                  slot(0x21, cls=0x05, imm=0) +                 # J  JMP 0
                  HALT,
                  entry=8 * 7), 3,
              ["not implemented in this build"]))

# ---------- L3: malformed fixtures (normative rejections) --------------------
# step 2: bad magic
bad = bytearray(build_file(HALT))
bad[0] ^= 0x01
CASES.append(("bad_magic", bytes(bad), 108, ["INVALID_PROGRAM", "bad magic"]))

# step 3: unsupported version
CASES.append(("bad_version",
              build_file(HALT, version=struct.pack("<H", 2)), 108,
              ["INVALID_PROGRAM", "unsupported version"]))

# step 4: reserved field nonzero
CASES.append(("bad_reserved",
              build_file(HALT, reserved=b"\x01\x00\x00\x00"), 108,
              ["INVALID_PROGRAM", "reserved"]))

# step 1: truncated header (10 bytes)
CASES.append(("trunc_header", build_file(HALT)[:10], 108,
              ["INVALID_PROGRAM", "truncated header"]))

# step 6: truncated code (header says 8, only 4 code bytes present)
CASES.append(("trunc_code", build_file(HALT)[:0x1A + 4], 108,
              ["INVALID_PROGRAM", "truncated program"]))

# step 6: trailing garbage byte
CASES.append(("trailing_data", build_file(HALT) + b"\x00", 108,
              ["INVALID_PROGRAM", "trailing data"]))

# step 5: code_size = 0
CASES.append(("code_size_zero",
              build_file(b"", code_size_override=0), 108,
              ["INVALID_PROGRAM", "invalid code size"]))

# step 5: code_size % 8 != 0 (header/file consistent at 12 code bytes)
CASES.append(("code_size_misaligned",
              build_file(b"\x00" * 12), 108,
              ["INVALID_PROGRAM", "invalid code size"]))

# step 7: entry >= code_size
CASES.append(("entry_oob",
              build_file(HALT, entry=8), 108,
              ["INVALID_PROGRAM", "invalid entry point"]))

# step 7: entry % 8 != 0
CASES.append(("entry_misaligned",
              build_file(BASE2_CODE, entry=4), 108,
              ["INVALID_PROGRAM", "invalid entry point"]))

# step 8: code_size + data_size > 0xF000
CASES.append(("layout_overflow",
              build_file(HALT, data=b"\x00" * 0xF000), 108,
              ["INVALID_PROGRAM", "invalid memory layout"]))

# step 9: opcode 0xFF in slot
CASES.append(("opcode_ff",
              build_file(slot(0xFF)), 109,
              ["INVALID_INSTRUCTION", "bad opcode", "0xff", "0x0"]))

# step 9: opcode 0x2B (first reserved)
CASES.append(("opcode_2b",
              build_file(slot(0x2B)), 109,
              ["INVALID_INSTRUCTION", "bad opcode", "0x2b"]))

# step 9: bad opcode in the SECOND slot (offset reporting)
CASES.append(("opcode_bad_offset",
              build_file(HALT + slot(0xFF)), 109,
              ["INVALID_INSTRUCTION", "bad opcode", "0x8"]))

# step 9: class byte mismatch (HALT declared as class R)
CASES.append(("class_mismatch",
              build_file(slot(0x01, cls=0x01)), 109,
              ["INVALID_INSTRUCTION", "bad class", "0x1", "0x1"]))

# step 9: register field 0x10 (MOV R0,imm with dst=0x10)
CASES.append(("reg_0x10",
              build_file(slot(0x03, dst=0x10, cls=0x02, imm=42)), 109,
              ["INVALID_INSTRUCTION", "bad register"]))

# step 9: register 0xFF where a register is required (MOV R,imm dst=0xFF)
CASES.append(("reg_ff_as_dst",
              build_file(slot(0x03, dst=0xFF, cls=0x02, imm=42)), 109,
              ["INVALID_INSTRUCTION", "bad register"]))

# step 9: nonzero imm32 on class N (HALT with imm=1)
CASES.append(("imm_nonzero_n",
              build_file(slot(0x01, imm=1)), 109,
              ["INVALID_INSTRUCTION", "nonzero imm32"]))

# step 9: nonzero imm32 on class R
CASES.append(("imm_nonzero_r",
              build_file(slot(0x02, dst=0x00, src=0x01, cls=0x01, imm=7)), 109,
              ["INVALID_INSTRUCTION", "nonzero imm32"]))

# step 9: JMP target >= code_size
CASES.append(("jmp_target_oob",
              build_file(slot(0x21, cls=0x05, imm=8)), 109,
              ["INVALID_INSTRUCTION", "bad jump target", "0x8"]))

# step 9: JMP target misaligned
CASES.append(("jmp_target_misaligned",
              build_file(slot(0x21, cls=0x05, imm=4)), 109,
              ["INVALID_INSTRUCTION", "bad jump target", "0x4"]))

# step 9: CALL target misaligned
CASES.append(("call_target_misaligned",
              build_file(slot(0x1F, cls=0x05, imm=4)), 109,
              ["INVALID_INSTRUCTION", "bad jump target", "0x4"]))

# step 9: LOAD_M address 0xFFFFFFF8 (wraparound-guard: > 0x10000 - 8)
CASES.append(("loadm_addr_huge",
              build_file(slot(0x17, dst=0x00, cls=0x04, imm=0xFFFFFFF8)), 109,
              ["INVALID_INSTRUCTION", "bad memory address", "0xfffffff8"]))

# step 9: LOAD_M address 0x10000 - 7 (one past the last valid 8-byte slot)
CASES.append(("loadm_addr_past_end",
              build_file(slot(0x17, dst=0x00, cls=0x04, imm=0xFFF9)), 109,
              ["INVALID_INSTRUCTION", "bad memory address"]))

# step 9: STORE_M with register in the wrong field (dst set, src=0xFF)
CASES.append(("storem_wrong_field",
              build_file(slot(0x19, dst=0x02, src=0xFF, cls=0x04, imm=0)), 109,
              ["INVALID_INSTRUCTION", "bad register"]))

# file larger than any well-formed file (64 KiB of zeros)
CASES.append(("file_too_large", b"\x00" * 65536, 108,
              ["INVALID_PROGRAM", "file too large"]))


def main() -> int:
    os.makedirs(OUT, exist_ok=True)
    # wipe stale fixtures
    for f in os.listdir(OUT):
        if f.endswith(".bin"):
            os.remove(os.path.join(OUT, f))
    with open(os.path.join(OUT, "manifest.tsv"), "w") as mf:
        mf.write("name\texit\tsubstrings\n")
        for name, blob, exit_code, subs in CASES:
            path = os.path.join(OUT, name + ".bin")
            with open(path, "wb") as f:
                f.write(blob)
            mf.write("%s\t%d\t%s\n" % (name, exit_code, "|".join(subs)))
    print("generated %d fixtures in %s" % (len(CASES), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
