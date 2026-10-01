#!/usr/bin/env python3
"""Phase 3 L4: CPU execution tests — example programs, runtime errors,
flag semantics via Jcc, --max-steps, determinism, fib(30).

Every program is encoded by the minimal test-local builder below
(straight from docs/ISA.md §6); no product assembler is used or needed.
Each test asserts the full observable triple: (stdout, exit_code, stderr).
"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
AURORA = os.path.join(REPO, "build", "aurora")

PASS = 0
FAIL = 0
FAILED = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        # print("PASS: " + name)
    else:
        FAIL += 1
        FAILED.append(name)
        print("FAIL: %s %s" % (name, detail))


class B:
    """Minimal test-local bytecode builder with labels (not an assembler)."""

    def __init__(self):
        self.code = bytearray()
        self.labels = {}
        self.fixups = []

    def L(self, name):
        assert name not in self.labels
        self.labels[name] = len(self.code)

    def emit(self, op, dst=0xFF, src=0xFF, cls=0, imm=0):
        self.code += bytes([op, dst, src, cls]) + struct.pack("<I", imm & 0xFFFFFFFF)

    def j(self, op, name):
        """CALL/JMP/Jcc to a label (absolute u32, patched at build)."""
        pos = len(self.code)
        self.emit(op, cls=5, imm=0)
        self.fixups.append((pos, name))

    def build(self, entry=0, data=b""):
        for pos, name in self.fixups:
            struct.pack_into("<I", self.code, pos + 4, self.labels[name])
        hdr = (bytes.fromhex("4155524f52410100") + struct.pack("<H", 1)
               + struct.pack("<I", len(self.code)) + struct.pack("<I", entry)
               + struct.pack("<I", len(data)) + struct.pack("<I", 0))
        return hdr + bytes(self.code) + data


# Shorthand emitters (opcode, class, field placement per ISA.md §6).
def NOP(b): b.emit(0x00)
def HALT(b): b.emit(0x01)
def MOVrr(b, d, s): b.emit(0x02, dst=d, src=s, cls=1)
def MOVri(b, d, i): b.emit(0x03, dst=d, cls=2, imm=i)
def ADDrr(b, d, s): b.emit(0x04, dst=d, src=s, cls=1)
def ADDri(b, d, i): b.emit(0x05, dst=d, cls=2, imm=i)
def SUBrr(b, d, s): b.emit(0x06, dst=d, src=s, cls=1)
def SUBri(b, d, i): b.emit(0x07, dst=d, cls=2, imm=i)
def MULrr(b, d, s): b.emit(0x08, dst=d, src=s, cls=1)
def MULri(b, d, i): b.emit(0x09, dst=d, cls=2, imm=i)
def DIVrr(b, d, s): b.emit(0x0A, dst=d, src=s, cls=1)
def DIVri(b, d, i): b.emit(0x0B, dst=d, cls=2, imm=i)
def INC(b, d): b.emit(0x0C, dst=d, cls=3)
def DEC(b, d): b.emit(0x0D, dst=d, cls=3)
def ANDrr(b, d, s): b.emit(0x0E, dst=d, src=s, cls=1)
def ANDri(b, d, i): b.emit(0x0F, dst=d, cls=2, imm=i)
def ORrr(b, d, s): b.emit(0x10, dst=d, src=s, cls=1)
def ORri(b, d, i): b.emit(0x11, dst=d, cls=2, imm=i)
def XORrr(b, d, s): b.emit(0x12, dst=d, src=s, cls=1)
def XORri(b, d, i): b.emit(0x13, dst=d, cls=2, imm=i)
def NOT(b, d): b.emit(0x14, dst=d, cls=3)
def CMPr(b, d, s): b.emit(0x15, dst=d, src=s, cls=1)
def CMPri(b, d, i): b.emit(0x16, dst=d, cls=2, imm=i)
def LOADm(b, d, a): b.emit(0x17, dst=d, cls=4, imm=a)
def LOADr(b, d, s): b.emit(0x18, dst=d, src=s, cls=1)
def STOREm(b, a, s): b.emit(0x19, src=s, cls=4, imm=a)
def STOREr(b, d, s): b.emit(0x1A, dst=d, src=s, cls=1)
def LOADBr(b, d, s): b.emit(0x1B, dst=d, src=s, cls=1)
def STOREBr(b, d, s): b.emit(0x1C, dst=d, src=s, cls=1)
def PUSH(b, s): b.emit(0x1D, src=s, cls=3)
def POP(b, d): b.emit(0x1E, dst=d, cls=3)
def CALL(b, name): b.j(0x1F, name)
def RET(b): b.emit(0x20)
def JMP(b, name): b.j(0x21, name)
def JE(b, name): b.j(0x22, name)
def JNE(b, name): b.j(0x23, name)
def JG(b, name): b.j(0x24, name)
def JL(b, name): b.j(0x25, name)
def JGE(b, name): b.j(0x26, name)
def JLE(b, name): b.j(0x27, name)
def OUT(b, s): b.emit(0x28, src=s, cls=3)
def OUTC(b, s): b.emit(0x29, src=s, cls=3)
def IN(b, d): b.emit(0x2A, dst=d, cls=3)


def run(blob, args=(), stdin_data=None, stdout_to=None):
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(blob)
        path = f.name
    try:
        kw = dict(capture_output=True, timeout=120)
        if stdin_data is not None:
            kw["input"] = stdin_data
        if stdout_to is not None:
            kw["stdout"] = stdout_to
            del kw["capture_output"]
            kw["stderr"] = subprocess.PIPE
        p = subprocess.run([AURORA, "run", path] + list(args), **kw)
        return p.returncode, p.stdout or b"", p.stderr or b""
    finally:
        os.unlink(path)


def expect(name, blob, want_out, want_exit, want_err=b"", args=(),
           stdin_data=None):
    rc, out, err = run(blob, args=args, stdin_data=stdin_data)
    ok = (out == want_out and rc == want_exit
          and (want_err in err if want_err else err == b""))
    check(name, ok, "rc=%d out=%r err=%r" % (rc, out, err[:80]))


def expect_fatal(name, blob, err_name, exit_code, args=()):
    rc, out, err = run(blob, args=args)
    ok = (rc == exit_code and ("aurora: error: " + err_name).encode() in err
          and out == b"")
    check(name, ok, "rc=%d out=%r err=%r" % (rc, out, err[:80]))


I64MIN = 0x8000000000000000
I64MAX = 0x7FFFFFFFFFFFFFFF


def load_i64min(b, reg):
    """MOV Rd, imm32 cannot encode INT64_MIN; build it by doubling."""
    MOVri(b, reg, 1)
    for _ in range(63):
        ADDrr(b, reg, reg)


def main():
    # ---------------- A. example programs ----------------
    # hello world (R0 = '\n' = 10 at HALT -> exit 10)
    b = B()
    for ch in b"Hello\n":
        MOVri(b, 0, ch)
        OUTC(b, 0)
    HALT(b)
    expect("hello", b.build(), b"Hello\n", 10)

    # arithmetic: ((10+20)*3-5) = 85
    b = B()
    MOVri(b, 0, 10); ADDri(b, 0, 20); MULri(b, 0, 3); SUBri(b, 0, 5)
    OUT(b, 0); HALT(b)
    expect("arithmetic", b.build(), b"85\n", 85)

    # branching: Z=1 -> JE taken
    b = B()
    MOVri(b, 1, 7); MOVri(b, 2, 7); CMPr(b, 1, 2)
    JE(b, "yes"); MOVri(b, 0, 222); JMP(b, "end")
    b.L("yes"); MOVri(b, 0, 111)
    b.L("end"); OUT(b, 0); HALT(b)
    expect("branch", b.build(), b"111\n", 111)

    # loop: sum 1..10 = 55
    b = B()
    MOVri(b, 0, 0); MOVri(b, 1, 1); MOVri(b, 2, 11)
    b.L("loop"); ADDrr(b, 0, 1); INC(b, 1); CMPr(b, 1, 2); JNE(b, "loop")
    OUT(b, 0); HALT(b)
    expect("loop_sum", b.build(), b"55\n", 55)

    # factorial(5) = 120, iterative (DEC sets Z when R1 hits 0)
    b = B()
    MOVri(b, 0, 1); MOVri(b, 1, 5)
    b.L("loop"); MULrr(b, 0, 1); DEC(b, 1); JNE(b, "loop")
    OUT(b, 0); HALT(b)
    expect("factorial", b.build(), b"120\n", 120)

    # fibonacci(10) = 55, iterative (R3 = R0 + R1 fresh each iteration)
    b = B()
    MOVri(b, 0, 0); MOVri(b, 1, 1); MOVri(b, 2, 10)
    b.L("loop"); MOVrr(b, 3, 0); ADDrr(b, 3, 1)
    MOVrr(b, 0, 1); MOVrr(b, 1, 3)
    DEC(b, 2); JNE(b, "loop")
    OUT(b, 0); HALT(b)
    expect("fib_iter10", b.build(), b"55\n", 55)

    # stack LIFO
    b = B()
    MOVri(b, 4, 1); PUSH(b, 4); MOVri(b, 4, 2); PUSH(b, 4)
    MOVri(b, 4, 3); PUSH(b, 4)
    POP(b, 1); POP(b, 2); POP(b, 3)
    OUT(b, 1); OUT(b, 2); OUT(b, 3); HALT(b)
    expect("stack_lifo", b.build(), b"3\n2\n1\n", 0)

    # memory roundtrip: 64-bit and byte
    # (imm32 0xF0F0F0F0 sign-extends -> 0xFFFFFFFFF0F0F0F0 = -252645136)
    b = B()
    MOVri(b, 5, 0xF0F0F0F0)
    STOREm(b, 0x1000, 5); LOADm(b, 6, 0x1000)
    OUT(b, 6)                       # -252645136
    MOVri(b, 5, 0x41); MOVri(b, 7, 0x2000)
    STOREBr(b, 7, 5); LOADBr(b, 6, 7)
    OUT(b, 6)                       # 65
    HALT(b)
    expect("memory", b.build(), b"-252645136\n65\n", 0)

    # ---------------- B. I/O edge cases ----------------
    b = B(); MOVri(b, 0, -5); OUT(b, 0); HALT(b)
    expect("out_negative", b.build(), b"-5\n", 251)

    b = B(); MOVri(b, 0, 0x80000000); OUT(b, 0); HALT(b)
    # imm32 0x80000000 sign-extends to 64 bits -> R0 = -2147483648
    expect("out_imm_signextend", b.build(), b"-2147483648\n", 0)

    b = B(); MOVri(b, 0, 65); OUTC(b, 0); MOVri(b, 0, 66); OUTC(b, 0); HALT(b)
    expect("outc", b.build(), b"AB", 66)      # R0 = 'B' = 66 at HALT

    b = B(); IN(b, 0); OUTC(b, 0); HALT(b)
    expect("in_echo", b.build(), b"Z", 90, stdin_data=b"Z")  # R0 = 'Z' = 90

    b = B(); IN(b, 0); OUT(b, 0); HALT(b)
    expect("in_eof", b.build(), b"-1\n", 255, stdin_data=b"")

    # ---------------- C. flags via Jcc ----------------
    # ADD overflow: 0x7FFF..F + 1 -> V=1,N=1,Z=0 -> JG taken
    # (imm32 cannot encode 0x7FFF..F; build it as NOT(INT64_MIN))
    b = B()
    load_i64min(b, 0)
    NOT(b, 0)                       # R0 = 0x7FFFFFFFFFFFFFFF
    ADDri(b, 0, 1)                  # R0 = 0x8000000000000000, V=1 N=1
    JG(b, "yes"); MOVri(b, 1, 0); JMP(b, "end")
    b.L("yes"); MOVri(b, 1, 1)
    b.L("end"); OUT(b, 1); HALT(b)
    expect("flag_add_overflow", b.build(), b"1\n", 0)

    # ADD to zero: 0xFFFF..F + 1 -> Z=1 -> JE taken
    # (imm32 0xFFFFFFFF sign-extends to 0xFFFF..F, which is what we want here)
    b = B()
    MOVri(b, 0, 0xFFFFFFFFFFFFFFFF); ADDri(b, 0, 1)
    JE(b, "yes"); MOVri(b, 1, 0); JMP(b, "end")
    b.L("yes"); MOVri(b, 1, 1)
    b.L("end"); OUT(b, 1); HALT(b)
    expect("flag_add_zero", b.build(), b"1\n", 0)

    # CMP signed: 3 < 5 -> JL taken (R0=3 -> HALT exits 3)
    b = B()
    MOVri(b, 0, 3); MOVri(b, 1, 5); CMPr(b, 0, 1)
    JL(b, "yes"); MOVri(b, 2, 0); JMP(b, "end")
    b.L("yes"); MOVri(b, 2, 1)
    b.L("end"); OUT(b, 2); HALT(b)
    expect("flag_cmp_jl", b.build(), b"1\n", 3)

    # MUL overflow: 2^32 * 2^32 -> low=0, V=1 -> JE taken (Z=1)
    b = B()
    MOVri(b, 0, 0); MOVri(b, 1, 1)
    # build 2^32 via shifts? no SHL; use ADD doubling 32 times — simpler:
    # R0 = 0x100000000 via MUL loop is circular; do it directly:
    b = B()
    MOVri(b, 0, 1)
    for _ in range(32):
        ADDrr(b, 0, 0)              # R0 *= 2  -> 2^32
    MULrr(b, 0, 0)                  # low 64 = 0, high != 0 -> V=1, Z=1
    JE(b, "yes"); MOVri(b, 1, 0); JMP(b, "end")
    b.L("yes"); MOVri(b, 1, 1)
    b.L("end"); OUT(b, 1); HALT(b)
    expect("flag_mul_overflow", b.build(), b"1\n", 0)

    # DIV INT64_MIN / -1 -> result INT64_MIN, V=1,N=1 -> JGE taken; OUT prints min
    b = B()
    load_i64min(b, 0); MOVri(b, 1, 0xFFFFFFFFFFFFFFFF)  # -1
    DIVrr(b, 0, 1)
    JGE(b, "yes"); MOVri(b, 2, 0); JMP(b, "end")
    b.L("yes"); MOVri(b, 2, 1)
    b.L("end"); OUT(b, 2); OUT(b, 0); HALT(b)
    expect("flag_div_min", b.build(), b"1\n-9223372036854775808\n", 0)

    # Jcc battery: each conditional, taken and not-taken
    def jcc_case(op, setup):
        bb = B()
        setup(bb)
        op(bb, "yes"); MOVri(bb, 3, 0); JMP(bb, "end")
        bb.L("yes"); MOVri(bb, 3, 1)
        bb.L("end"); OUT(bb, 3); HALT(bb)
        return bb.build()
    def eq(bb): MOVri(bb, 0, 5); MOVri(bb, 1, 5); CMPr(bb, 0, 1)   # R0=5
    def ne(bb): MOVri(bb, 0, 5); MOVri(bb, 1, 6); CMPr(bb, 0, 1)   # R0=5
    def gt(bb): MOVri(bb, 0, 6); MOVri(bb, 1, 5); CMPr(bb, 0, 1)   # R0=6
    def lt(bb): MOVri(bb, 0, 5); MOVri(bb, 1, 6); CMPr(bb, 0, 1)   # R0=5
    cases = [
        # name, jump, setup, want_out, want_exit (R0 at HALT)
        ("je_t", JE, eq, b"1\n", 5), ("je_nt", JE, ne, b"0\n", 5),
        ("jne_t", JNE, ne, b"1\n", 5), ("jne_nt", JNE, eq, b"0\n", 5),
        ("jg_t", JG, gt, b"1\n", 6), ("jg_nt", JG, lt, b"0\n", 5),
        ("jl_t", JL, lt, b"1\n", 5), ("jl_nt", JL, gt, b"0\n", 6),
        ("jge_t", JGE, eq, b"1\n", 5), ("jge_nt", JGE, lt, b"0\n", 5),
        ("jle_t", JLE, eq, b"1\n", 5), ("jle_nt", JLE, gt, b"0\n", 6),
    ]
    for name, op, setup, want, want_exit in cases:
        # R0 is 5 (eq/ne/lt) or 6 (gt) in every setup -> HALT exits R0
        expect("jcc_" + name, jcc_case(op, setup), want, want_exit)

    # ---------------- D. runtime errors ----------------
    b = B(); DIVrr(b, 0, 1); HALT(b)          # R1 = 0
    expect_fatal("err_div_zero_rr", b.build(), "DIVISION_BY_ZERO", 106)
    b = B(); MOVri(b, 0, 10); DIVri(b, 0, 0); HALT(b)
    expect_fatal("err_div_zero_ri", b.build(), "DIVISION_BY_ZERO", 106)

    b = B()
    MOVri(b, 0, 0)
    for _ in range(600):
        PUSH(b, 0)
    HALT(b)
    expect_fatal("err_stack_overflow", b.build(), "STACK_OVERFLOW", 104)

    b = B(); POP(b, 0); HALT(b)
    expect_fatal("err_stack_underflow", b.build(), "STACK_UNDERFLOW", 105)

    b = B(); MOVri(b, 1, 0); STOREm(b, 0, 1); HALT(b)
    expect_fatal("err_write_to_code_m", b.build(), "WRITE_TO_CODE", 111)
    b = B(); MOVri(b, 0, 8); STOREr(b, 0, 1); HALT(b)
    expect_fatal("err_write_to_code_r", b.build(), "WRITE_TO_CODE", 111)
    b = B(); MOVri(b, 0, 8); STOREBr(b, 0, 1); HALT(b)
    expect_fatal("err_write_to_code_b", b.build(), "WRITE_TO_CODE", 111)

    b = B(); MOVri(b, 0, 0xFFFFFFFFFFFFFFFF); LOADr(b, 1, 0); HALT(b)
    expect_fatal("err_invalid_mem_load", b.build(), "INVALID_MEMORY_ACCESS", 103)
    b = B(); MOVri(b, 0, 0xFFF9); STOREr(b, 0, 1); HALT(b)
    expect_fatal("err_invalid_mem_store8", b.build(), "INVALID_MEMORY_ACCESS", 103)
    b = B(); MOVri(b, 0, 0x10000); LOADBr(b, 1, 0); HALT(b)
    expect_fatal("err_invalid_mem_byte", b.build(), "INVALID_MEMORY_ACCESS", 103)

    # INVALID_PC via RET with corrupted saved return address
    b = B()
    CALL(b, "func"); HALT(b)
    b.L("func")
    MOVri(b, 0, 0x1235)          # bad PC: unaligned and >= code_size
    STOREm(b, 0xFFF8, 0)         # overwrite saved return address (FP+8)
    RET(b)
    expect_fatal("err_invalid_pc_ret", b.build(), "INVALID_PC", 107)

    # MAX_STEPS_EXCEEDED
    b = B(); b.L("top"); JMP(b, "top")
    expect_fatal("err_max_steps", b.build(), "MAX_STEPS_EXCEEDED", 110,
                 args=("--max-steps", "1000"))

    # max-steps exact boundary: 3-step program
    b = B(); MOVri(b, 1, 1); MOVri(b, 2, 2); HALT(b)
    blob = b.build()
    expect("maxsteps_exact_ok", blob, b"", 0, args=("--max-steps", "3"))
    expect_fatal("maxsteps_exact_cut", blob, "MAX_STEPS_EXCEEDED", 110,
                 args=("--max-steps", "2"))

    # IO_ERROR: stdout opened read-only -> write fails with EBADF
    b = B(); MOVri(b, 0, 42); OUT(b, 0); HALT(b)
    blob = b.build()
    with tempfile.NamedTemporaryFile() as tf:
        ro = os.open(tf.name, os.O_RDONLY)
        try:
            with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
                f.write(blob)
                path = f.name
            try:
                p = subprocess.run([AURORA, "run", path], stdout=ro,
                                   stderr=subprocess.PIPE, timeout=30)
                ok = (p.returncode == 112
                      and b"aurora: error: IO_ERROR" in p.stderr)
                check("err_io_error", ok,
                      "rc=%d err=%r" % (p.returncode, p.stderr[:80]))
            finally:
                os.unlink(path)
        finally:
            os.close(ro)

    # ---------------- F. extra edge cases ----------------
    # RET with no active call -> STACK_UNDERFLOW (SP=FP=0x10000)
    b = B(); RET(b)
    expect_fatal("ret_no_call", b.build(), "STACK_UNDERFLOW", 105)

    # falling off the end of code -> INVALID_PC
    b = B(); NOP(b)
    expect_fatal("fall_off_end", b.build(), "INVALID_PC", 107)

    # byte at the very last address 0xFFFF
    b = B()
    MOVri(b, 0, 0xFFFF); MOVri(b, 1, 0x7A)
    STOREBr(b, 0, 1); LOADBr(b, 2, 0)
    OUT(b, 2); HALT(b)
    expect("byte_last_addr", b.build(), b"122\n", 255)  # R0=0xFFFF -> exit 255

    # simple CALL/RET (not just fib)
    b = B()
    CALL(b, "func"); OUT(b, 0); HALT(b)
    b.L("func"); MOVri(b, 0, 42); RET(b)
    expect("call_ret_simple", b.build(), b"42\n", 42)

    # INC sets Z; DEC sets Z; NOT preserves flags (Z stays 1 from CMP)
    b = B()
    MOVri(b, 0, 0xFFFFFFFFFFFFFFFF)  # -1
    INC(b, 0)                        # -> 0, Z=1
    JE(b, "ok1"); MOVri(b, 1, 0); JMP(b, "end")
    b.L("ok1"); MOVri(b, 1, 1)
    b.L("end"); OUT(b, 1); HALT(b)
    expect("inc_sets_z", b.build(), b"1\n", 0)

    b = B()
    MOVri(b, 0, 1)
    DEC(b, 0)                        # -> 0, Z=1
    JE(b, "ok1"); MOVri(b, 1, 0); JMP(b, "end")
    b.L("ok1"); MOVri(b, 1, 1)
    b.L("end"); OUT(b, 1); HALT(b)
    expect("dec_sets_z", b.build(), b"1\n", 0)

    b = B()
    MOVri(b, 0, 5); MOVri(b, 1, 5); CMPr(b, 0, 1)  # Z=1
    NOT(b, 2)                        # must not touch flags
    JE(b, "ok1"); MOVri(b, 3, 0); JMP(b, "end")
    b.L("ok1"); MOVri(b, 3, 1)
    b.L("end"); OUT(b, 3); HALT(b)
    expect("not_preserves_flags", b.build(), b"1\n", 5)

    # ---------------- G. fib(30) + determinism ----------------
    def fib_rec_blob():
        b = B()
        CALL(b, "main")
        HALT(b)
        b.L("fib")
        CMPri(b, 0, 2)
        JL(b, "base")
        PUSH(b, 0)              # save n
        SUBri(b, 0, 1)
        CALL(b, "fib")          # fib(n-1)
        POP(b, 1)               # R1 = n
        PUSH(b, 0)              # save fib(n-1)
        MOVrr(b, 0, 1)
        SUBri(b, 0, 2)
        CALL(b, "fib")          # fib(n-2)
        POP(b, 1)               # R1 = fib(n-1)
        ADDrr(b, 0, 1)
        RET(b)
        b.L("base")
        RET(b)
        b.L("main")
        MOVri(b, 0, 30)
        CALL(b, "fib")
        OUT(b, 0)
        HALT(b)
        return b.build()

    blob30 = fib_rec_blob()
    rc, out, err = run(blob30)
    check("fib30", rc == 40 and out == b"832040\n" and err == b"",
          "rc=%d out=%r err=%r" % (rc, out, err[:80]))

    # fib(30) with --max-steps 1000000 -> must not finish
    rc, out, err = run(blob30, args=("--max-steps", "1000000"))
    check("fib30_maxsteps", rc == 110 and b"MAX_STEPS_EXCEEDED" in err,
          "rc=%d err=%r" % (rc, err[:80]))

    # determinism: fib(20) = 6765 three times
    def fib20_blob():
        b = B()
        MOVri(b, 0, 0); MOVri(b, 1, 1); MOVri(b, 2, 20)
        b.L("loop"); MOVrr(b, 3, 0); ADDrr(b, 3, 1)
        MOVrr(b, 0, 1); MOVrr(b, 1, 3)
        DEC(b, 2); JNE(b, "loop")
        OUT(b, 0); HALT(b)
        return b.build()
    results = [run(fib20_blob()) for _ in range(3)]
    # R0 = 6765 at HALT -> exit 6765 & 0xFF = 109
    check("determinism", all(r == results[0] for r in results)
          and results[0][0] == 109 and results[0][1] == b"6765\n",
          "%r" % (results,))

    print("PASS: %d  FAIL: %d" % (PASS, FAIL))
    for n in FAILED:
        print("FAILED:", n)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
