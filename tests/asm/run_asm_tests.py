#!/usr/bin/env python3
"""
tests/asm/run_asm_tests.py -- test suite for tools/aurora-asm (AURORA phase 4).

Layers covered (docs/TESTING.md):
  L1  assembler unit tests: lexer/parser, labels, immediates, diagnostics
      (this file: valid/, invalid/, golden/)
  L2  valid/*.asm round-trip: aurora-asm -> loader -> CPU
  L5  programs/*.asm end-to-end (also exercised here)

INDEPENDENCE CONTRACT (hard requirement):
  * This runner NEVER imports tools/aurora-asm. It decodes .bin files with
    the struct module only, using tables transcribed below from docs/ISA.md
    section 6 and docs/BYTECODE.md. If the assembler and this runner agree,
    they do so because both match the spec -- not because they share code.
  * The golden vectors V1-V9 below are byte-exact transcriptions of the
    normative vectors in docs/ISA.md section 12. They were NOT produced by
    the assembler. The fixtures under tests/fixtures/ remain untouched.
  * tests/asm/golden/*.asm are the assembly-language sources the assembler
    must turn into exactly those bytes.

Exit code: 0 = all green, 1 = any failure. No warnings, no skips.
"""

import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASM = os.path.join(ROOT, "tools", "aurora-asm")
VM = os.path.join(ROOT, "build", "aurora")
ASM_DIR = os.path.join(ROOT, "tests", "asm")

PASS = 0
FAIL = 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append(name if not detail else "%s -- %s" % (name, detail))


def run_asm(src, out, extra_args=()):
    """Assemble src -> out. Returns (exit_code, stdout_bytes, stderr_text)."""
    p = subprocess.run(
        [sys.executable, ASM, src, "-o", out] + list(extra_args),
        capture_output=True,
    )
    try:
        err = p.stderr.decode("utf-8", "replace")
    except Exception:
        err = "<undecodable>"
    return p.returncode, p.stdout, err


def run_vm(binpath, stdin_bytes=b"", vm_args=()):
    """Run a .bin through the VM. Returns (exit, stdout, stderr_text)."""
    p = subprocess.run(
        [VM, "run", binpath] + list(vm_args),
        input=stdin_bytes, capture_output=True,
    )
    try:
        err = p.stderr.decode("utf-8", "replace")
    except Exception:
        err = "<undecodable>"
    return p.returncode, p.stdout, err


# ---------------------------------------------------------------------------
# Independent bytecode decoder (struct only -- no assembler code involved).
# Transcribed from docs/BYTECODE.md sections 3-4.
# ---------------------------------------------------------------------------

MAGIC = b"AURORA\x01\x00"
HEADER_FMT = "<8sHIII I"  # magic, version, code_size, entry, data_size, reserved
HEADER_LEN = struct.calcsize(HEADER_FMT)  # 26


def decode_bin(path):
    """Returns (header_dict, [ (opcode, dst, src, cls, imm_u32), ... ], data)."""
    raw = open(path, "rb").read()
    if len(raw) < HEADER_LEN:
        raise ValueError("file shorter than header: %d bytes" % len(raw))
    magic, version, code_size, entry, data_size, reserved = struct.unpack(
        HEADER_FMT, raw[:HEADER_LEN])
    hdr = dict(magic=magic, version=version, code_size=code_size,
               entry=entry, data_size=data_size, reserved=reserved)
    if len(raw) != HEADER_LEN + code_size + data_size:
        raise ValueError(
            "length mismatch: file=%d header=%d code=%d data=%d"
            % (len(raw), HEADER_LEN, code_size, data_size))
    insns = []
    for off in range(0, code_size, 8):
        b = raw[HEADER_LEN + off: HEADER_LEN + off + 8]
        opcode, dst, src, cls = b[0], b[1], b[2], b[3]
        imm = struct.unpack("<I", b[4:8])[0]
        insns.append((opcode, dst, src, cls, imm))
    return hdr, insns, raw[HEADER_LEN + code_size:]


# Opcode -> class, transcribed from docs/ISA.md section 6.
# N=0 R=1 I=2 r=3 M=4 J=5. This table lives in the TEST, not the assembler.
OPCODE_CLASS = {
    0x00: 0, 0x01: 0, 0x20: 0,
    0x02: 1, 0x04: 1, 0x06: 1, 0x08: 1, 0x0A: 1,
    0x0E: 1, 0x10: 1, 0x12: 1, 0x15: 1,
    0x18: 1, 0x1A: 1, 0x1B: 1, 0x1C: 1,
    0x03: 2, 0x05: 2, 0x07: 2, 0x09: 2, 0x0B: 2,
    0x0F: 2, 0x11: 2, 0x13: 2, 0x16: 2,
    0x0C: 3, 0x0D: 3, 0x14: 3, 0x1E: 3, 0x2A: 3,   # r, register in dst
    0x1D: 3, 0x28: 3, 0x29: 3,                     # r, register in src
    0x17: 4, 0x19: 4,
    0x1F: 5, 0x21: 5, 0x22: 5, 0x23: 5,
    0x24: 5, 0x25: 5, 0x26: 5, 0x27: 5,
}
# Class-r opcodes whose single register lives in dst (the phase-3
# correction this suite pins down); the rest use src.
RCLASS_DST = {0x0C, 0x0D, 0x14, 0x1E, 0x2A}
RCLASS_SRC = {0x1D, 0x28, 0x29}
assert len(OPCODE_CLASS) == 43, "opcode table must cover exactly 43 opcodes"
assert set(OPCODE_CLASS) == set(range(0x00, 0x2B))


def check_header(name, hdr, data):
    check(name + ": magic", hdr["magic"] == MAGIC,
          "got %r" % hdr["magic"])
    check(name + ": version == 1", hdr["version"] == 1,
          "got %r" % hdr["version"])
    check(name + ": entry == 0", hdr["entry"] == 0,
          "got %r" % hdr["entry"])
    check(name + ": reserved == 0", hdr["reserved"] == 0,
          "got %r" % hdr["reserved"])
    check(name + ": code_size multiple of 8", hdr["code_size"] % 8 == 0)
    check(name + ": code+data within 64 KiB",
          hdr["code_size"] + hdr["data_size"] <= 0x10000)
    check(name + ": no code/data overlap with stack region",
          hdr["code_size"] + hdr["data_size"] <= 0xF000)


def check_insn_fields(name, idx, opcode, dst, src, cls, imm, code_size):
    """Class/field invariants per docs/ISA.md section 6 (independent)."""
    tag = "%s: insn@%d op=0x%02X" % (name, idx * 8, opcode)
    check(tag + " known opcode", opcode in OPCODE_CLASS)
    if opcode not in OPCODE_CLASS:
        return
    check(tag + " class", cls == OPCODE_CLASS[opcode],
          "got class %d, want %d" % (cls, OPCODE_CLASS[opcode]))
    if cls == 0:      # N
        check(tag + " N: dst/src = 0xFF", dst == 0xFF and src == 0xFF)
        check(tag + " N: imm = 0", imm == 0)
    elif cls == 1:    # R
        check(tag + " R: dst/src are registers",
              dst <= 15 and src <= 15, "dst=%d src=%d" % (dst, src))
        check(tag + " R: imm = 0", imm == 0)
    elif cls == 2:    # I
        check(tag + " I: dst is register, src = 0xFF",
              dst <= 15 and src == 0xFF, "dst=%d src=%d" % (dst, src))
    elif cls == 3:    # r (single register)
        check(tag + " r: imm = 0", imm == 0)
        if opcode in RCLASS_DST:
            check(tag + " r: reg in dst", dst <= 15 and src == 0xFF,
                  "dst=%d src=%d" % (dst, src))
        elif opcode in RCLASS_SRC:
            check(tag + " r: reg in src", dst == 0xFF and src <= 15,
                  "dst=%d src=%d" % (dst, src))
        else:
            check(tag + " r: known placement", False,
                  "opcode 0x%02X" % opcode)
    elif cls == 4:    # M
        if opcode == 0x17:      # LOAD Rd, [a32]
            check(tag + " M: LOAD dst=reg src=0xFF",
                  dst <= 15 and src == 0xFF)
        elif opcode == 0x19:    # STORE [a32], Rs
            check(tag + " M: STORE dst=0xFF src=reg",
                  dst == 0xFF and src <= 15)
        else:
            check(tag + " M: known shape", False)
    elif cls == 5:    # J
        check(tag + " J: dst/src = 0xFF", dst == 0xFF and src == 0xFF)
        check(tag + " J: target inside code",
              imm < code_size, "target=0x%X code_size=0x%X" % (imm, code_size))
        check(tag + " J: target aligned", imm % 8 == 0)


# ---------------------------------------------------------------------------
# Golden vectors V1-V9: byte-exact transcriptions of docs/ISA.md section 12.
# These hex strings were COPIED FROM THE SPEC TEXT, never generated by the
# assembler. If any byte here disagrees with ISA.md, ISA.md wins and this
# file must be fixed by hand -- never by running the assembler.
# Header layout: magic(8) version(u16=1) code_size(u32) entry(u32=0)
#                data_size(u32=0) reserved(u32=0); data section empty.
# ---------------------------------------------------------------------------

def _golden(code_size, code_hex):
    import binascii
    hdr = (binascii.unhexlify("4155524f52410100") + struct.pack("<H", 1)
           + struct.pack("<III", code_size, 0, 0) + struct.pack("<I", 0))
    return hdr + binascii.unhexlify(code_hex.replace(" ", "").replace("\n", ""))


GOLDEN = {
    # name: (asm source, expected full-file bytes, expected exit,
    #        expected stdout, expected stderr-substring-or-None)
    "v1": ("v1.asm", _golden(24,
        "0301ff020a000000 0200010100000000 01ffff0000000000"), 10, b"", None),
    "v2": ("v2.asm", _golden(16,
        "0305ff02ffffffff 01ffff0000000000"), 0, b"", None),
    "v3": ("v3.asm", _golden(32,
        "0300ff02ffffffff 0301ff0201000000 "
        "0400010100000000 01ffff0000000000"), 0, b"", None),
    "v4": ("v4.asm", _golden(32,
        "0300ff020a000000 0301ff0214000000 "
        "0600010100000000 01ffff0000000000"), 246, b"", None),
    "v5": ("v5.asm", _golden(64,
        "0300ff0205000000 0301ff0205000000 "
        "1500010100000000 22ffff0530000000 "
        "0302ff0200000000 01ffff0000000000 "
        "0302ff0201000000 01ffff0000000000"), 5, b"", None),
    "v6": ("v6.asm", _golden(40,
        "0300ff022a000000 1dff000300000000 "
        "0300ff0200000000 1e01ff0300000000 "
        "01ffff0000000000"), 0, b"", None),
    "v7": ("v7.asm", _golden(32,
        "1fffff0510000000 01ffff0000000000 "
        "0300ff0207000000 20ffff0000000000"), 7, b"", None),
    "v8": ("v8.asm", _golden(48,
        "0300ff0200100000 0301ff025a5a0000 "
        "1a00010100000000 0302ff0200000000 "
        "1702ff0400100000 01ffff0000000000"), 0, b"", None),
    "v9": ("v9.asm", _golden(16,
        "0300ff02c8000000 01ffff0000000000"), 200, b"", None),
}

# Exact bytes for the eight class-r opcodes (docs/ISA.md section 6 +
# the phase-3 dst/src correction). Order matches valid/r_class_fields.asm.
RCLASS_EXACT = [
    bytes.fromhex("1dff030300000000"),   # PUSH R3  (reg in src)
    bytes.fromhex("0c03ff0300000000"),   # INC R3   (reg in dst)
    bytes.fromhex("0d03ff0300000000"),   # DEC R3   (reg in dst)
    bytes.fromhex("1403ff0300000000"),   # NOT R3   (reg in dst)
    bytes.fromhex("1e03ff0300000000"),   # POP R3   (reg in dst)
    bytes.fromhex("2a03ff0300000000"),   # IN R3    (reg in dst)
    bytes.fromhex("28ff030300000000"),   # OUT R3   (reg in src)
    bytes.fromhex("29ff030300000000"),   # OUTC R3  (reg in src)
]

# Round-trip table: (source, stdin, expected stdout, expected exit,
#                    expected stderr substring or None, extra vm args)
ROUNDTRIP = [
    ("programs/hello.asm", b"", b"Hello, world!\n", 0, None, ()),
    ("programs/arith.asm", b"", b"90\n", 90, None, ()),
    ("programs/cond.asm", b"", b"1\n2\n3\n4\n5\n", 0, None, ()),
    ("programs/fact.asm", b"", b"3628800\n", 0, None, ()),
    ("programs/fib.asm", b"", b"55\n", 55, None, ()),
    ("programs/stack.asm", b"", b"6\n", 6, None, ()),
    ("programs/mem.asm", b"", b"1\n", 1, None, ()),
    ("examples/hello.asm", b"", b"Hello, world!\n", 0, None, ()),
    ("examples/arithmetic.asm", b"", b"90\n", 90, None, ()),
    ("examples/loop.asm", b"", b"1\n2\n3\n4\n5\n", 6, None, ()),
    ("examples/factorial.asm", b"", b"3628800\n", 0, None, ()),
    ("examples/fib.asm", b"", b"55\n", 55, None, ()),
    ("examples/stack.asm", b"", b"3\n2\n1\n6\n", 6, None, ()),
    ("examples/memory.asm", b"", b"23130\n1\n", 1, None, ()),
    ("tests/asm/valid/all_opcodes.asm", b"", b"-1\n\xff", 0, None, ()),
    ("tests/asm/valid/r_class_fields.asm", b"", b"-1\n\xff", 0, None, ()),
    ("tests/asm/valid/labels_forward.asm", b"", b"7\n", 7, None, ()),
    ("tests/asm/valid/immediates.asm", b"", b"2147483646\n", 254, None, ()),
    ("tests/asm/valid/data_directives.asm", b"",
     b"A-60876\n-4294967297\n-2\n", 0, None, ()),
    ("tests/asm/valid/case_insensitive.asm", b"", b"A", 0, None, ()),
    # Torture: fatal-error paths still go through assembler -> loader -> CPU.
    ("tests/asm/torture/div_zero.asm", b"", b"", 106, "DIVISION_BY_ZERO", ()),
    ("tests/asm/torture/stack_underflow.asm", b"", b"", 105,
     "STACK_UNDERFLOW", ()),
    ("tests/asm/torture/stack_overflow.asm", b"", b"", 104,
     "STACK_OVERFLOW", ()),
    ("tests/asm/torture/mem_write_code.asm", b"", b"", 111,
     "WRITE_TO_CODE", ()),
    ("tests/asm/torture/max_steps.asm", b"", b"", 110,
     "MAX_STEPS_EXCEEDED", ("--max-steps", "1000")),
    ("tests/asm/torture/halt_200.asm", b"", b"", 200, None, ()),
    ("tests/asm/torture/io_echo.asm", b"A", b"A", 65, None, ()),
]

# Negative table: (source, expected diagnostic category on stderr).
# Every case must exit 1, print no traceback, and produce no .bin.
NEGATIVE = [
    ("tests/asm/invalid/reg_r16.asm", "invalid register"),
    ("tests/asm/invalid/reg_r99.asm", "invalid register"),
    ("tests/asm/invalid/reg_neg.asm", "invalid register"),
    ("tests/asm/invalid/missing_operand.asm", "missing operand"),
    ("tests/asm/invalid/trailing_comma.asm", "missing operand"),
    ("tests/asm/invalid/missing_comma.asm", "syntax error"),
    ("tests/asm/invalid/unknown_mnemonic.asm", "unknown mnemonic"),
    ("tests/asm/invalid/imm_overflow.asm", "immediate out of range"),
    ("tests/asm/invalid/imm_underflow.asm", "immediate out of range"),
    ("tests/asm/invalid/bad_literal.asm", "invalid numeric literal"),
    ("tests/asm/invalid/halt_extra.asm", "unexpected operand"),
    ("tests/asm/invalid/add_missing.asm", "missing operand"),
    ("tests/asm/invalid/inc_extra.asm", "unexpected operand"),
    ("tests/asm/invalid/push_imm.asm", "invalid operand"),
    ("tests/asm/invalid/loadb_abs.asm", "invalid operand"),
    ("tests/asm/invalid/mem_expr.asm", "syntax error"),
    ("tests/asm/invalid/mem_bad_reg.asm", "invalid register"),
    ("tests/asm/invalid/db_reg.asm", "invalid data operand"),
    ("tests/asm/invalid/dw_str.asm", "invalid data operand"),
    ("tests/asm/invalid/db_overflow.asm", "immediate out of range"),
    ("tests/asm/invalid/dw_overflow.asm", "immediate out of range"),
    ("tests/asm/invalid/dot_directive.asm", "invalid directive"),
    ("tests/asm/invalid/jump_misaligned.asm", "invalid jump target"),
    ("tests/asm/invalid/undef_label.asm", "undefined label"),
    ("tests/asm/invalid/dup_label.asm", "duplicate label"),
    ("tests/asm/invalid/jump_to_data.asm", "jump to data label"),
    ("tests/asm/invalid/arith_label.asm", "invalid operand"),
    ("tests/asm/invalid/unclosed_bracket.asm", "syntax error"),
    ("tests/asm/invalid/addr_overflow.asm", "address out of range"),
    ("tests/asm/invalid/store_shape.asm", "invalid operand"),
    ("tests/asm/invalid/empty.asm", "empty program"),
    ("tests/asm/invalid/comment_only.asm", "empty program"),
    ("tests/asm/invalid/bad_label.asm", "invalid label"),
]


# ---------------------------------------------------------------------------
# Test sections
# ---------------------------------------------------------------------------

TMP = os.path.join(ASM_DIR, ".tmp")
os.makedirs(TMP, exist_ok=True)


def tmp_bin(name):
    safe = name.replace("/", "_").replace(".asm", ".bin")
    return os.path.join(TMP, safe)


def assemble_ok(rel):
    src = os.path.join(ROOT, rel)
    out = tmp_bin(rel)
    ec, so, se = run_asm(src, out)
    check("asm-exit0: " + rel, ec == 0, "exit=%d stderr=%s" % (ec, se[:200]))
    check("asm-no-stdout: " + rel, so == b"", "stdout=%r" % so[:80])
    check("asm-no-traceback: " + rel, "Traceback" not in se)
    if ec != 0:
        return None
    return out


def validate_structure(rel, out):
    """Independent re-validation of the emitted bytecode (BYTECODE.md 7)."""
    try:
        hdr, insns, data = decode_bin(out)
    except ValueError as e:
        check("decode: " + rel, False, str(e))
        return None
    check_header("hdr: " + rel, hdr, data)
    for i, (op, dst, src, cls, imm) in enumerate(insns):
        check_insn_fields("field", i, op, dst, src, cls, imm,
                          hdr["code_size"])
    return hdr, insns, data


def test_all_opcodes():
    rel = "tests/asm/valid/all_opcodes.asm"
    out = assemble_ok(rel)
    if out is None:
        return
    r = validate_structure(rel, out)
    if r is None:
        return
    hdr, insns, data = r
    ops = {op for op, _, _, _, _ in insns}
    check("all_opcodes: 43/43 distinct opcodes", ops == set(range(0x2B)),
          "missing=%s" % sorted(set(range(0x2B)) - ops))
    # Spot-check a few immediates end to end (positional; the .asm has
    # several MOVs to the same register, so a dict would collide).
    check("all_opcodes: MOV R1,10 imm", insns[2] == (0x03, 1, 0xFF, 2, 10),
          "got %r" % (insns[2],))
    check("all_opcodes: MOV R2,-1 imm",
          insns[3] == (0x03, 2, 0xFF, 2, 0xFFFFFFFF),
          "got %r" % (insns[3],))
    check("all_opcodes: MOV R4,0b101 imm", insns[5][4] == 5,
          "got %r" % (insns[5],))
    # Every J-class target must be the exact offset of a label the
    # assembler resolved (labels are at known instruction indexes).
    # func: instruction index 40 -> byte offset 320; done: index 42 -> 336.
    jumps = [(op, imm) for op, _, _, cls, imm in insns if cls == 5]
    check("all_opcodes: CALL func -> 320",
          (0x1F, 320) in jumps, "jumps=%s" % jumps)
    check("all_opcodes: JMP done -> 336",
          (0x21, 336) in jumps, "jumps=%s" % jumps)


def test_rclass_exact():
    rel = "tests/asm/valid/r_class_fields.asm"
    out = assemble_ok(rel)
    if out is None:
        return
    raw = open(out, "rb").read()
    code = raw[HEADER_LEN: HEADER_LEN + 8 * len(RCLASS_EXACT)]
    for i, want in enumerate(RCLASS_EXACT):
        got = code[i * 8:(i + 1) * 8]
        check("rclass byte-exact insn %d" % i, got == want,
              "got %s want %s" % (got.hex(), want.hex()))
    validate_structure(rel, out)


def test_valid_roundtrip():
    for rel in ["tests/asm/valid/labels_forward.asm",
                "tests/asm/valid/immediates.asm",
                "tests/asm/valid/data_directives.asm",
                "tests/asm/valid/case_insensitive.asm"]:
        out = assemble_ok(rel)
        if out is not None:
            validate_structure(rel, out)


def test_golden():
    for name in ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9"]:
        src_name, want_bytes, want_exit, want_out, want_err = GOLDEN[name]
        rel = "tests/asm/golden/" + src_name
        tag = "golden-" + name
        out = tmp_bin("golden_" + name)
        ec, so, se = run_asm(os.path.join(ROOT, rel), out)
        check(tag + ": assembles", ec == 0, se[:160])
        if ec != 0:
            continue
        got = open(out, "rb").read()
        check(tag + ": byte-exact vs ISA.md section 12", got == want_bytes,
              "len got=%d want=%d first-diff=%s"
              % (len(got), len(want_bytes),
                 next((i for i, (a, b) in enumerate(zip(got, want_bytes))
                       if a != b), "none")))
        # The golden binary must ALSO decode cleanly under the
        # independent decoder (structural sanity, not byte source).
        try:
            hdr, insns, data = decode_bin(out)
            check_header(tag + ": header", hdr, data)
        except ValueError as e:
            check(tag + ": decodes", False, str(e))
            continue
        ec2, so2, se2 = run_vm(out)
        check(tag + ": exit %d" % want_exit, ec2 == want_exit,
              "got %d" % ec2)
        check(tag + ": stdout", so2 == want_out, "got %r" % so2[:60])
        if want_err is None:
            check(tag + ": stderr empty", se2 == "", "got %r" % se2[:80])
        else:
            check(tag + ": stderr", want_err in se2, "got %r" % se2[:80])


def test_roundtrip():
    for rel, stdin_b, want_out, want_exit, want_err, vm_args in ROUNDTRIP:
        tag = "roundtrip: " + rel
        out = assemble_ok(rel)
        if out is None:
            continue
        validate_structure(rel, out)
        ec, so, se = run_vm(out, stdin_b, vm_args)
        check(tag + ": exit %d" % want_exit, ec == want_exit,
              "got %d stderr=%r" % (ec, se[:100]))
        check(tag + ": stdout", so == want_out,
              "got %r want %r" % (so[:80], want_out[:80]))
        if want_err is None:
            check(tag + ": stderr empty", se == "", "got %r" % se[:100])
        else:
            check(tag + ": stderr has %s" % want_err, want_err in se,
                  "got %r" % se[:100])


def test_negative():
    for rel, category in NEGATIVE:
        tag = "negative: " + rel.split("/")[-1]
        out = tmp_bin("neg_" + rel)
        if os.path.exists(out):
            os.remove(out)
        ec, so, se = run_asm(os.path.join(ROOT, rel), out)
        check(tag + ": exit 1", ec == 1, "got %d" % ec)
        check(tag + ": no traceback", "Traceback" not in se,
              se[:120])
        check(tag + ": diagnostic has '%s'" % category, category in se,
              "stderr=%r" % se[:160])
        check(tag + ": location file:line:col", ":1:" in se or ":2:" in se,
              "stderr=%r" % se[:120])
        check(tag + ": no .bin produced", not os.path.exists(out))
        check(tag + ": stdout empty", so == b"")


def test_determinism():
    sources = ([r for r, _, _, _, _, _ in ROUNDTRIP]
               + ["tests/asm/golden/%s.asm" % n
                  for n in ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9"]])
    for rel in sources:
        src = os.path.join(ROOT, rel)
        a, b = tmp_bin("det_a_" + rel), tmp_bin("det_b_" + rel)
        ec1, _, _ = run_asm(src, a)
        ec2, _, _ = run_asm(src, b)
        if ec1 != 0 or ec2 != 0:
            check("determinism: " + rel, False, "assembly failed")
            continue
        ba, bb = open(a, "rb").read(), open(b, "rb").read()
        check("determinism: " + rel, ba == bb,
              "len %d vs %d" % (len(ba), len(bb)))


def test_cli():
    p = subprocess.run([sys.executable, ASM, "--help"], capture_output=True)
    check("cli: --help exit 0", p.returncode == 0)
    check("cli: --help usage", b"usage" in p.stdout.lower())
    p = subprocess.run([sys.executable, ASM, "--version"], capture_output=True)
    check("cli: --version exit 0", p.returncode == 0)
    check("cli: --version names tool", b"aurora-asm" in p.stdout)
    p = subprocess.run([sys.executable, ASM], capture_output=True)
    check("cli: no args exit 2", p.returncode == 2)
    p = subprocess.run([sys.executable, ASM, "/nonexistent/x.asm",
                        "-o", tmp_bin("nope")], capture_output=True)
    err = p.stderr.decode("utf-8", "replace")
    check("cli: missing file exit 2", p.returncode == 2)
    check("cli: missing file no traceback", "Traceback" not in err)
    p = subprocess.run([sys.executable, ASM, "--bogus"], capture_output=True)
    check("cli: bad option exit 2", p.returncode == 2)


def main():
    if not os.path.isfile(ASM):
        print("assembler not found: %s" % ASM)
        return 1
    if not os.path.isfile(VM):
        print("VM not built: %s (run make first)" % VM)
        return 1
    test_cli()
    test_all_opcodes()
    test_rclass_exact()
    test_valid_roundtrip()
    test_golden()
    test_roundtrip()
    test_negative()
    test_determinism()
    print("asm tests: %d passed, %d failed" % (PASS, FAIL))
    for f in FAILURES:
        print("  FAIL:", f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
