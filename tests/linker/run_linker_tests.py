#!/usr/bin/env python3
"""AURORA linker tests (Phase 7, L9).

Covers: object creation/parsing/validation, local/global/undefined
symbols, duplicate globals, relocations (all three types + range
checks), code/data layout, entry policy, real runtime linking, real
multi-module execution on the VM, malformed objects, CLI behavior,
determinism (sha256 equality), link-order significance, and the phase-5
debugger driving a linked binary.

Golden .o files are built by hand with struct -- independent of both
tools/aurora-asm and tools/aurora-ld (docs/OBJECT_FORMAT.md section 10).

Exit 0 = all pass, 1 = failures.
"""
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
from importlib.machinery import SourceFileLoader

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(REPO, "build", "aurora")
ASM = os.path.join(REPO, "tools", "aurora-asm")
LD = os.path.join(REPO, "tools", "aurora-ld")

from importlib.machinery import SourceFileLoader
ldmod = SourceFileLoader("aurora_ld", LD).load_module()

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

def fresh_dir(prefix="ldtest_"):
    return tempfile.mkdtemp(prefix=prefix)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def asm_c(name, src, d=None, extra=()):
    """Assemble src text with -c -> .o path. Returns (rc, stderr, path)."""
    d = d or fresh_dir()
    ap = os.path.join(d, name + ".asm")
    op = os.path.join(d, name + ".o")
    with open(ap, "w") as f:
        f.write(src)
    r = subprocess.run([sys.executable, ASM, "-c", ap, "-o", op, *extra],
                       capture_output=True, text=True)
    return r.returncode, r.stderr, op

def asm_bin(name, src, d=None):
    d = d or fresh_dir()
    ap = os.path.join(d, name + ".asm")
    bp = os.path.join(d, name + ".bin")
    with open(ap, "w") as f:
        f.write(src)
    r = subprocess.run([sys.executable, ASM, ap, "-o", bp],
                       capture_output=True, text=True)
    assert r.returncode == 0, f"asm failed for {name}: {r.stderr}"
    return bp

def ld_link(name, objs, d=None, extra=()):
    """Link objs -> .bin. Returns (rc, stdout, stderr, outpath)."""
    d = d or fresh_dir()
    out = os.path.join(d, name + ".bin")
    r = subprocess.run([sys.executable, LD, *objs, "-o", out, *extra],
                       capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr, out

def run_bin(binpath, stdin_bytes=b"", timeout=10):
    r = subprocess.run([BIN, "run", binpath], input=stdin_bytes,
                       capture_output=True, timeout=timeout)
    return r.stdout, r.stderr, r.returncode

def dbg(binpath, commands, timeout=10):
    inp = "\n".join(commands) + "\n"
    r = subprocess.run([BIN, "debug", binpath], input=inp,
                       capture_output=True, text=True, timeout=timeout)
    return r.stdout, r.stderr, r.returncode

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()

# ---------------------------------------------------------------------------
# Independent .o builder and parser (struct only; not the assembler/linker)
# ---------------------------------------------------------------------------

def build_object(code, data, symbols, relocs):
    """symbols: [(name, bind, sect, offset)]; relocs: [(type, offset, sym)].
    bind: 0 LOCAL, 1 GLOBAL, 2 UNDEFINED. sect: 0 CODE, 1 DATA, 0xFF NONE."""
    co, doff = 48, 48 + len(code)
    so = doff + len(data)
    ro = so + len(symbols) * 76
    hdr = struct.pack("<8sHHI8I", b"AURORAO1", 1, 48, 0,
                      len(code), co, len(data), doff,
                      len(symbols), so, len(relocs), ro)
    out = bytearray(hdr) + bytes(code) + bytes(data)
    for (name, bind, sect, off) in symbols:
        raw = name.encode("ascii")
        out += raw + b"\x00" * (64 - len(raw))
        out += struct.pack("<BBHII", bind, sect, 0, off, 0)
    for (t, off, s) in relocs:
        out += struct.pack("<BBHII", t, 0, 0, off, s)
    return bytes(out)

def parse_o(data):
    """Independent .o parser. Returns header/symbols/relocs/code/data."""
    (magic, ver, hsz, flags, cs, co, ds, doff,
     sc, so, rc, ro) = struct.unpack("<8sHHI8I", data[:48])
    syms = []
    for i in range(sc):
        base = so + i * 76
        name = data[base:base + 64].split(b"\x00")[0].decode("ascii")
        bind, sect, _, off, _ = struct.unpack("<BBHII", data[base + 64:base + 76])
        syms.append((name, bind, sect, off))
    relocs = []
    for i in range(rc):
        base = ro + i * 12
        t, _, _, off, s = struct.unpack("<BBHII", data[base:base + 12])
        relocs.append((t, off, s))
    return {"magic": magic, "ver": ver, "hsz": hsz, "flags": flags,
            "cs": cs, "co": co, "ds": ds, "doff": doff,
            "syms": syms, "relocs": relocs,
            "code": data[co:co + cs], "data_seg": data[doff:doff + ds]}

def mutate(base, patches):
    """Return base bytes with (offset, new_bytes) patches applied."""
    b = bytearray(base)
    for off, new in patches:
        b[off:off + len(new)] = new
    return bytes(b)

# ===========================================================================
print("== A. assembler -c: object creation ==")

rc, err, op = asm_c("basic",
    "    CALL helper\n"
    "    MOV R0, msg\n"
    "    LOAD R1, [msg]\n"
    "    JMP start\n"
    "helper:\n"
    "    RET\n"
    "start:\n"
    "    HALT\n"
    "msg: DB 65\n")
check("basic -c exits 0", rc == 0, err)
o = parse_o(open(op, "rb").read())
check("magic", o["magic"] == b"AURORAO1", repr(o["magic"]))
check("version == 1", o["ver"] == 1)
check("header_size == 48", o["hsz"] == 48)
check("flags == 0", o["flags"] == 0)
check("code 6 instr = 48 bytes", o["cs"] == 48, o["cs"])
check("data 1 byte", o["ds"] == 1)
names = [s[0] for s in o["syms"]]
check("symbols in definition order", names == ["helper", "start", "msg"],
      names)
check("all LOCAL by default", all(s[1] == 0 for s in o["syms"]))
check("helper is CODE@8", ("helper", 0, 0, 32) in o["syms"], o["syms"])
check("msg is DATA@0", ("msg", 0, 1, 0) in o["syms"], o["syms"])
check("4 relocations", len(o["relocs"]) == 4, o["relocs"])
check("reloc types/order",
      o["relocs"] == [(1, 4, 0), (2, 12, 2), (3, 20, 2), (1, 28, 1)],
      o["relocs"])
check("relocation sites hold zero",
      all(int.from_bytes(o["code"][off:off + 4], "little") == 0
          for (_t, off, _s) in o["relocs"]))

rc, err, op = asm_c("glob",
    "    .global api_fn\n"
    "    .global api_data\n"
    "    CALL api_fn\n"
    "    HALT\n"
    "api_fn:\n"
    "    RET\n"
    "api_data: DQ 123\n")
check("global -c exits 0", rc == 0, err)
o = parse_o(open(op, "rb").read())
binds = {s[0]: s[1] for s in o["syms"]}
check(".global marks GLOBAL", binds.get("api_fn") == 1 and binds.get("api_data") == 1, binds)

rc, err, op = asm_c("undef", "    CALL ext_fn\n    HALT\n")
check("undefined label ok with -c", rc == 0, err)
o = parse_o(open(op, "rb").read())
check("UNDEFINED symbol emitted",
      ("ext_fn", 2, 0xFF, 0) in o["syms"], o["syms"])
check("relocation against UNDEFINED", o["relocs"] == [(1, 4, 0)], o["relocs"])

rc, err, _op = asm_c("globundef", "    .global nope\n    HALT\n")
check(".global undefined -> error", rc == 1 and "undefined global" in err, err)
check("no traceback", "Traceback" not in err)

rc, err, _op = asm_c("globdup", "    .global f\n    .global f\nf:\n    RET\n")
check("duplicate .global -> error", rc == 1 and ".global" in err, err)

rc, err, _op = asm_c("globbad", "    .global 1bad\n    HALT\n")
check(".global bad name -> error", rc == 1, err)

rc, err, _op = asm_c("longname", "    CALL " + "a" * 64 + "\n    HALT\n")
check("symbol name > 63 chars -> error", rc == 1 and "too long" in err, err)

rc, err, op = asm_c("rlabel", "read_loop:\n    MOV R0, 1\n    JMP read_loop\n    HALT\n")
check("R-prefixed label works with -c", rc == 0, err)
bp = asm_bin("rlabel_bin", "read_loop:\n    MOV R0, 1\n    JMP read_loop\n    HALT\n")
out, errb, rcx = run_bin(bp, timeout=5)
check("R-prefixed label works in bin mode too", "MAX_STEPS" in errb.decode(), errb[:80])

rc, err, op = asm_c("dataonly", "buf: DB 1, 2, 3\n")
check("data-only module ok with -c", rc == 0, err)
o = parse_o(open(op, "rb").read())
check("data-only: code_size 0", o["cs"] == 0 and o["ds"] == 3, (o["cs"], o["ds"]))

rc, err, _op = asm_c("jmpdata", "    JMP d\n    HALT\nd: DB 9\n")
check("jump to data label still error with -c", rc == 1 and "jump to data label" in err, err)

rc, err, op = asm_c("numjump", "    JMP 0x1000\n    HALT\n")
check("numeric jump beyond code size ok with -c", rc == 0, err)

d = fresh_dir()
rc, err, op2 = asm_c("defname", "    HALT\n", d=d, extra=())
check("-c default output is .o", rc == 0 and op2.endswith(".o") and os.path.exists(op2), op2)

b1 = asm_bin("gcheck1", "    .global f\nf:\n    RET\n")
b2 = asm_bin("gcheck2", "f:\n    RET\n")
check(".global is byte-neutral in bin mode",
      open(b1, "rb").read() == open(b2, "rb").read())

rc, err, _op = asm_c("memrlabel", "    LOAD R0, [read_loop]\n    HALT\nread_loop: DB 7\n")
check("[R-prefixed label] memory operand with -c", rc == 0, err)

# ===========================================================================
print("== B. golden objects (hand-built, assembler-independent) ==")

NOP = bytes.fromhex("00ffff0000000000")
CALL = lambda tgt: bytes((0x1F, 0xFF, 0xFF, 0x05)) + tgt.to_bytes(4, "little")
HALT = bytes.fromhex("01ffff0000000000")
MOV_R0_42 = bytes.fromhex("0300ff022a000000")
RET = bytes.fromhex("20ffff0000000000")
JMP = lambda tgt: bytes((0x21, 0xFF, 0xFF, 0x05)) + tgt.to_bytes(4, "little")

g1 = build_object(CALL(0) + HALT, b"",
                  [("ext", 2, 0xFF, 0)], [(1, 4, 0)])
g2 = build_object(MOV_R0_42 + RET, b"",
                  [("ext", 1, 0, 0)], [])
d = fresh_dir()
g1p, g2p = os.path.join(d, "g1.o"), os.path.join(d, "g2.o")
open(g1p, "wb").write(g1)
open(g2p, "wb").write(g2)
rc, so, se, outp = ld_link("golden", [g1p, g2p], d=d)
check("golden objects link", rc == 0, se)
blob = open(outp, "rb").read()
exp_code = CALL(16) + HALT + MOV_R0_42 + RET
exp = (bytes.fromhex("4155524f52410100") + struct.pack("<HIII I", 1, 32, 0, 0, 0)
       + exp_code)
check("linked bytes match hand-computed expectation", blob == exp,
      f"len {len(blob)} vs {len(exp)}")
out, errb, rcx = run_bin(outp)
check("golden program runs: exit 42", rcx == 42, f"rc={rcx}")
check("golden program: NORMAL halt, no stderr", errb == b"", errb[:80])
check("golden .o validates structurally", parse_o(g1)["magic"] == b"AURORAO1")

# golden: wrong magic must not link
bad = mutate(g1, [(0, b"BADMAGIC")])
bp_ = os.path.join(d, "bad.o")
open(bp_, "wb").write(bad)
rc, so, se, _o = ld_link("badmagic", [bp_, g2p], d=d)
check("golden bad magic rejected", rc == 1 and "magic" in se, se)

# ===========================================================================
print("== C. symbol resolution ==")

d = fresh_dir()
rc, err, a_o = asm_c("dup_a", "    .global foo\nfoo:\n    RET\n", d=d)
rc, err, b_o = asm_c("dup_b", "    .global foo\nfoo:\n    RET\n", d=d)
rc, so, se, _o = ld_link("dup", [a_o, b_o], d=d)
check("duplicate global -> link error",
      rc == 1 and "duplicate global symbol" in se and "'foo'" in se, se)
check("duplicate error names both objects",
      "dup_a.o" in se and "dup_b.o" in se, se)
check("no traceback on duplicate", "Traceback" not in se)

rc, err, c_o = asm_c("undefref", "    CALL missing\n    HALT\n", d=d)
rc, so, se, _o = ld_link("undef", [c_o], d=d)
check("undefined symbol -> link error",
      rc == 1 and "undefined symbol" in se and "'missing'" in se, se)
check("undefined error names referencing object", "undefref.o" in se, se)

rc, err, l1 = asm_c("loc1", "thing:\n    RET\n    CALL thing\n    HALT\n", d=d)
rc, err, l2 = asm_c("loc2", "thing:\n    MOV R0, 1\n    RET\n", d=d)
rc, so, se, outp = ld_link("locals", [l1, l2], d=d)
check("same-named locals coexist", rc == 0, se)

rc, err, u1 = asm_c("use1", "    CALL shared\n    HALT\n", d=d)
rc, err, u2 = asm_c("use2", "    .global shared\nshared:\n    MOV R0, 9\n    RET\n", d=d)
rc, so, se, outp = ld_link("cross", [u1, u2], d=d)
check("global satisfies cross-module reference", rc == 0, se)
out, errb, rcx = run_bin(outp)
check("cross-module call executes", rcx == 9 and errb == b"", f"rc={rcx}")

rc, err, s1 = asm_c("selfref", "    .global g\n    CALL g\n    HALT\ng:\n    RET\n", d=d)
rc, so, se, _o = ld_link("self", [s1], d=d)
check("global self-reference links", rc == 0, se)

# ===========================================================================
print("== D. relocations ==")

d = fresh_dir()
# CODE32 against a DATA symbol -> link error
rc, err, r1 = asm_c("r_call", "    CALL extd\n    HALT\n", d=d)
rc, err, r2 = asm_c("r_data", "    .global extd\nextd: DQ 1\n", d=d)
rc, so, se, _o = ld_link("codetype", [r1, r2], d=d)
check("CODE32 against data symbol -> error",
      rc == 1 and "non-code symbol" in se, se)

# MEM32 relocation patches [label] with the final data address
rc, err, m1 = asm_c("m_main", "    LOAD R0, [val]\n    HALT\n", d=d)
rc, err, m2 = asm_c("m_data", "    .global val\nval: DQ 0x1122334455667788\n", d=d)
rc, so, se, outp = ld_link("memrel", [m1, m2], d=d)
check("MEM32 links", rc == 0, se)
blob = open(outp, "rb").read()
imm = int.from_bytes(blob[26 + 4:26 + 8], "little")
check("MEM32 patched to final data address", imm == 16, hex(imm))

# ADDR32: MOV Rd,label patches the absolute address
rc, err, a1 = asm_c("a_main", "    MOV R0, val\n    HALT\n", d=d)
rc, so, se, outp = ld_link("addrrel", [a1, m2], d=d)
check("ADDR32 links", rc == 0, se)
blob = open(outp, "rb").read()
imm = int.from_bytes(blob[26 + 4:26 + 8], "little")
check("ADDR32 patched to final data address", imm == 16, hex(imm))

# numeric JMP beyond final code size -> linker rejects (L10)
jn = build_object(JMP(0x1000) + HALT, b"", [], [])
jp = os.path.join(d, "jmpnum.o")
open(jp, "wb").write(jn)
rc, so, se, _o = ld_link("jmpnum", [jp], d=d)
check("final jump target validated by linker",
      rc == 1 and "invalid jump target" in se, se)

# unit-level: MEM32 value beyond 0x10000-8 -> LinkError (no truncation)
fake = {"path": "fake.o", "code": b"\x00" * 8, "data": b"",
        "symbols": [{"name": "big", "bind": 0, "sect": 1, "offset": 0xFFF0}],
        "relocs": [{"type": 3, "offset": 4, "sym": 0}]}
img = bytearray(8 + 0x200)
try:
    ldmod.apply_relocations([fake], {}, [0], [0x100], 8, img)
    mem_ok = False
except ldmod.LinkError as e:
    mem_ok = "0x10000 - 8" in str(e)
check("MEM32 overflow -> LinkError, never truncation", mem_ok)

# unit-level: ADDR32 at exactly 0xFFFFFFFF is representable
fake2 = {"path": "fake2.o", "code": b"\x00" * 8, "data": b"",
         "symbols": [{"name": "top", "bind": 0, "sect": 1, "offset": 0}],
         "relocs": [{"type": 2, "offset": 4, "sym": 0}]}
img2 = bytearray(8)
ldmod.apply_relocations([fake2], {}, [0], [0xFFFFFFFF], 8, img2)
check("ADDR32 boundary 0xFFFFFFFF patches exactly",
      int.from_bytes(img2[4:8], "little") == 0xFFFFFFFF)

# ===========================================================================
print("== E. layout and entry ==")

d = fresh_dir()
rc, err, e1 = asm_c("e_a", "    MOV R0, 1\n    HALT\n", d=d)
rc, err, e2 = asm_c("e_b", "    MOV R0, 2\n    HALT\ndat: DB 9\n", d=d)
rc, so, se, outp = ld_link("lay", [e1, e2], d=d)
check("layout links", rc == 0, se)
blob = open(outp, "rb").read()
magic, ver, cs, entry, ds, res = struct.unpack("<8sHIII I", blob[:26])
check("executable magic/version", magic == bytes((0x41, 0x55, 0x52, 0x4F, 0x52, 0x41, 0x01, 0x00)) and ver == 1)
check("entry == 0", entry == 0, entry)
check("code concatenated in link order",
      blob[26:26 + 32] == parse_o(open(e1, "rb").read())["code"] +
                          parse_o(open(e2, "rb").read())["code"])
check("data after all code", blob[26 + 32:26 + 33] == b"\x09")
check("code_size/data_size fields", cs == 32 and ds == 1, (cs, ds))

rc, so, se, outp2 = ld_link("lay2", [e2, e1], d=d)
b1h, b2h = sha256_file(outp), sha256_file(outp2)
check("link order changes layout (order is significant)", b1h != b2h)
check("reversed entry code differs", open(outp2, "rb").read()[26:34] != blob[26:34])

# ===========================================================================
print("== F. runtime linking and multi-module execution ==")

d = fresh_dir()
rc, err, rt_o = asm_c("rt", open(os.path.join(REPO, "runtime", "aurora_rt.asm")).read(), d=d)
check("runtime assembles with -c", rc == 0, err)
o = parse_o(open(rt_o, "rb").read())
binds = {s[0]: s[1] for s in o["syms"]}
check("runtime exports svc_exit/svc_write/svc_read",
      binds.get("svc_exit") == 1 and binds.get("svc_write") == 1 and binds.get("svc_read") == 1)

rc, err, echo_o = asm_c("echo_main",
    open(os.path.join(REPO, "examples", "linker", "echo_main.asm")).read(), d=d)
rc, so, se, outp = ld_link("echo", [echo_o, rt_o], d=d)
check("echo.o + runtime.o links", rc == 0, se)
out, errb, rcx = run_bin(outp, b"hi")
check("linked echo runs: stdout", out == b"hi", out)
check("linked echo runs: exit 0", rcx == 0, f"rc={rcx}")
out, errb, rcx = run_bin(outp, b"")
check("linked echo: empty stdin -> no output, exit 0", out == b"" and rcx == 0)

rc, err, main_o = asm_c("main",
    open(os.path.join(REPO, "examples", "linker", "main.asm")).read(), d=d)
rc, err, math_o = asm_c("math",
    open(os.path.join(REPO, "examples", "linker", "math.asm")).read(), d=d)
rc, so, se, outp = ld_link("mathdemo", [main_o, math_o], d=d)
check("main.o + math.o links", rc == 0, se)
out, errb, rcx = run_bin(outp)
check("multi-module execution: stdout 50/21/5", out == b"50\n21\n5\n", out)
check("multi-module execution: exit 0, NORMAL", rcx == 0 and errb == b"")

# ===========================================================================
print("== G. malformed objects ==")

d = fresh_dir()
base_code = NOP + HALT
base = build_object(base_code, b"\x01\x02",
                    [("ok", 0, 0, 0)], [])
def bad_link(name, data, expect):
    p = os.path.join(d, name + ".o")
    open(p, "wb").write(data)
    rc, so, se, _o = ld_link(name, [p], d=d)
    ok = rc == 1 and expect in se and "Traceback" not in se
    check(f"malformed: {name}", ok, f"rc={rc} se={se[:100]!r}")

bad_link("truncated", base[:20], "truncated")
bad_link("badver", mutate(base, [(8, b"\x02\x00")]), "unsupported version")
bad_link("badhsize", mutate(base, [(10, b"\x20\x00")]), "bad header_size")
bad_link("nonzeroflags", mutate(base, [(12, b"\x01\x00\x00\x00")]), "nonzero flags")
bad_link("codemod8", mutate(base, [(16, b"\x0a\x00\x00\x00")]), "multiple of 8")
bad_link("code_oob", mutate(base, [(20, b"\xff\xff\xff\x7f")]), "out of bounds")
bad_link("overlap", mutate(base, [(28, struct.pack("<I", 48))]), "overlaps")
bad_link("sym_baddind",
         mutate(base, [(130, b"\x05")]), "bad binding")
bad_link("sym_nonul", mutate(base, [(66, b"Z" * 64)]), "NUL-terminated")
bad_link("sym_undef_off",
         mutate(build_object(base_code, b"", [("u", 2, 0xFF, 0)], []),
                [(132, struct.pack("<I", 8))]),
         "offset 0")
bad_link("sym_dup",
         mutate(build_object(base_code, b"", [("ok", 0, 0, 0), ("ok", 0, 0, 8)], []),
                []),
         "duplicate symbol")
bad_link("reloc_type",
         mutate(build_object(base_code, b"", [("ok", 0, 0, 0)], [(9, 4, 0)]),
                []),
         "unknown type")
bad_link("reloc_symidx",
         mutate(build_object(base_code, b"", [("ok", 0, 0, 0)], [(1, 4, 7)]),
                []),
         "nonexistent symbol")
bad_link("reloc_badoff",
         mutate(build_object(base_code, b"", [("ok", 0, 0, 0)], [(1, 5, 0)]),
                []),
         "bad code offset")
bad_link("reloc_dupoff",
         mutate(build_object(base_code, b"", [("ok", 0, 0, 0)],
                              [(1, 4, 0), (2, 4, 0)]), []),
         "same field")

# ===========================================================================
print("== H. linker CLI ==")

d = fresh_dir()
r = subprocess.run([sys.executable, LD], capture_output=True, text=True)
check("no inputs -> exit 2", r.returncode == 2, r.returncode)
r = subprocess.run([sys.executable, LD, "--bogus"], capture_output=True, text=True)
check("unknown option -> exit 2", r.returncode == 2 and "unknown option" in r.stderr)
r = subprocess.run([sys.executable, LD, "/nonexistent.o", "-o", os.path.join(d, "x.bin")],
                   capture_output=True, text=True)
check("missing input -> exit 2", r.returncode == 2 and "no such file" in r.stderr)
r = subprocess.run([sys.executable, LD, "-o"], capture_output=True, text=True)
check("-o without arg -> exit 2", r.returncode == 2)
r = subprocess.run([sys.executable, LD, "--help"], capture_output=True, text=True)
check("--help exits 0", r.returncode == 0 and "usage:" in r.stdout)
r = subprocess.run([sys.executable, LD, "--version"], capture_output=True, text=True)
check("--version exits 0", r.returncode == 0 and "aurora-ld" in r.stdout)
rc, err, c_o = asm_c("cliself", "    HALT\n", d=d)
r = subprocess.run([sys.executable, LD, c_o, "-o", c_o], capture_output=True, text=True)
check("input == output -> exit 2", r.returncode == 2)
r = subprocess.run([sys.executable, LD, "-o", os.path.join(d, "a.bin"), "-o",
                    os.path.join(d, "b.bin"), c_o], capture_output=True, text=True)
check("multiple -o -> exit 2", r.returncode == 2)
r = subprocess.run([sys.executable, ASM, "-c", "--bogus"], capture_output=True, text=True)
check("assembler unknown option still exit 2", r.returncode == 2)

# ===========================================================================
print("== I. determinism ==")

d = fresh_dir()
rc, err, m1 = asm_c("det_main",
    open(os.path.join(REPO, "examples", "linker", "main.asm")).read(), d=d)
rc, err, m2 = asm_c("det_math",
    open(os.path.join(REPO, "examples", "linker", "math.asm")).read(), d=d)
rc, so, se, o1 = ld_link("det1", [m1, m2], d=d)
rc, so, se, o2 = ld_link("det2", [m1, m2], d=d)
check("same link twice -> identical sha256",
      sha256_file(o1) == sha256_file(o2))
check("assembler -c is deterministic",
      sha256_file(m1) == sha256_file(asm_c("det_main2",
          open(os.path.join(REPO, "examples", "linker", "main.asm")).read(), d=d)[2]))
o = parse_o(open(m1, "rb").read())
check("no timestamps/paths leak into .o", b"det_main" not in open(m1, "rb").read())

# ===========================================================================
print("== J. debugger on a linked binary ==")

d = fresh_dir()
rc, err, j1 = asm_c("j_main",
    open(os.path.join(REPO, "examples", "linker", "main.asm")).read(), d=d)
rc, err, j2 = asm_c("j_math",
    open(os.path.join(REPO, "examples", "linker", "math.asm")).read(), d=d)
rc, so, se, linked = ld_link("dbg", [j1, j2], d=d)
assert rc == 0, se

out, errd, rcx = dbg(linked, ["disasm", "quit"])
check("debugger disassembles linked binary",
      "CALL" in out and "80" in out, out[:200])
out, errd, rcx = dbg(linked, ["break 0x0", "run", "quit"])
check("break at entry of linked binary", "stopped at breakpoint" in out, out[:200])
out, errd, rcx = dbg(linked, ["break 0x0", "run", "step", "regs", "quit"])
check("step executes first linked instruction (R0=8)",
      "0x0000000000000008" in out.lower(), out[:300])
out, errd, rcx = dbg(linked, ["break 0x50", "run", "step", "regs", "quit"])
check("break at cross-module function (add42@0x50), R0=50 after step",
      "0x0000000000000032" in out.lower(), out[:300])
out, errd, rcx = dbg(linked, ["memory 0x50 8", "quit"])
check("memory shows linked code", "0x00000050:" in out, out[:120])
out, errd, rcx = dbg(linked, ["break 0x0", "run", "reset", "regs", "quit"])
check("reset works on linked binary", "PC:" in out and rcx == 0)
out, errd, rcx = dbg(linked, ["run", "quit"])
check("run to completion: NORMAL halt, exit 0",
      "terminated: NORMAL (HALT), exit code 0" in out, out[:200])
check("debugger itself exits 0", rcx == 0, f"rc={rcx}")

# ===========================================================================
print()
print(f"linker tests: {PASS} passed, {FAIL} failed")
if FAILURES:
    print("failures:", FAILURES)
sys.exit(1 if FAIL else 0)
