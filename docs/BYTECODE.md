# AURORA VM — Bytecode Format

**Version:** `0x0001`
**Status:** ❄️ FROZEN — normative source of the bytecode container format,
frozen together with ISA v1.0.

The change protocol in `ISA.md` §0 applies here as well: no silent changes
to the header layout, field semantics, validation rules or version policy.
Decisions are recorded in `docs/DECISIONS.md` (D14).

Companion documents: `ISA.md` (instruction encoding), `ARCHITECTURE.md`
(design rationale).

---

## 1. File layout

```
offset   size   field            value / constraints
─────────────────────────────────────────────────────────────
0x00     8      magic            41 55 52 4F 52 41 01 00
                                     ("AURORA" + 0x01, 0x00)
0x08     2      version          0x0001, little-endian
0x0A     4      code_size        LE u32; > 0; multiple of 8
0x0E     4      entry            LE u32; < code_size; multiple of 8
0x12     4      data_size        LE u32; may be 0
0x16     4      reserved         must be 0
0x1A     …      code             exactly code_size bytes
…        …      data             exactly data_size bytes
```

Header size = `0x1A` (26) bytes.

### 1.1 Size equation (normative)

A file is well-formed only if:

```
file_size == 0x1A + code_size + data_size
```

Longer (trailing garbage) or shorter (truncated) files are rejected with
`INVALID_PROGRAM`. There is no "ignore extra bytes" leniency.

### 1.2 Magic

The 8-byte magic is `41 55 52 4F 52 41 01 00`. The last two bytes (`01 00`)
are a magic-level format tag distinguishing this container from any future
incompatible container; they are **not** the version field. Rationale: a
wrong-file-type error (`INVALID_PROGRAM`) is reported before any version
logic runs.

### 1.3 Version policy

- The loader accepts **only** version `0x0001`. Any other value →
  `INVALID_PROGRAM` ("unsupported version").
- A future ISA revision that adds opcodes or changes semantics **must**
  bump the version to `0x0002` and keep the v1 loader rejecting it. v1
  programs must run identically forever (see `ISA.md` §9 determinism).

---

## 2. Code section

`code_size / 8` instructions, each exactly as specified in `ISA.md` §4:

```
byte 0: opcode   (0x00–0x2A)
byte 1: dst      (0x00–0x0F register, or 0xFF unused)
byte 2: src      (0x00–0x0F register, or 0xFF unused)
byte 3: class    (0x00 N, 0x01 R, 0x02 I, 0x03 r, 0x04 M, 0x05 J)
bytes 4–7: imm32 (little-endian)
```

Per-opcode field requirements (class, which of dst/src are registers vs
`0xFF`, whether imm32 is used) are defined by the opcode table in
`ISA.md` §6. Summary of the validation rules the loader enforces for every
8-byte slot:

| Check | Rule | Violation |
|-------|------|-----------|
| opcode known | `opcode ≤ 0x2A` | `INVALID_INSTRUCTION` |
| class matches | `class == class_required_by(opcode)` | `INVALID_INSTRUCTION` |
| dst valid | `dst = 0xFF`, or `0x00–0x0F` where the opcode takes a dst register | `INVALID_INSTRUCTION` |
| src valid | same for src | `INVALID_INSTRUCTION` |
| imm32 zero | classes N, R, r: `imm32 == 0` | `INVALID_INSTRUCTION` |
| imm32 target | class J: `imm32 < code_size ∧ imm32 % 8 == 0` | `INVALID_INSTRUCTION` |
| imm32 address | class M: `imm32 ≤ 0x10000 − 8` (LOAD/STORE) | `INVALID_INSTRUCTION` |

Notes:

- Class I immediates accept **any** 32-bit pattern (they are integers, not
  addresses).
- Class M with a byte op (`LOADB`/`STOREB` are class R, not M — no M-class
  byte ops exist).
- Because every slot is validated, a program that passes the loader can
  never raise `INVALID_OPCODE`, `INVALID_REGISTER` or `INVALID_PC` from a
  *static* jump at runtime. The CPU still checks (defense in depth), and
  `RET` targets are dynamic so the CPU check is load-bearing there.

---

## 3. Data section

`data_size` raw bytes, loaded verbatim at virtual address `code_size`
(i.e. `MEM[code_size .. code_size+data_size)`). The assembler places
`DB`/`DW`/`DD`/`DQ` directives and string literals here and resolves data
labels to these addresses.

Constraints (checked by the loader):

```
code_size + data_size ≤ 0xF000        (data must not collide with the stack)
```

Violation → `INVALID_PROGRAM` ("invalid memory layout").

There is no separate "BSS": zero-initialized data is simply not stored
(the whole 64 KiB starts zeroed).

---

## 4. Loader validation algorithm (normative order)

The loader performs these checks **in order**, aborting with
`INVALID_PROGRAM` or `INVALID_INSTRUCTION` at the first failure, before
any instruction executes:

```
1. file_size ≥ 0x1A, else INVALID_PROGRAM ("truncated header")
2. magic bytes == 41 55 52 4F 52 41 01 00, else INVALID_PROGRAM ("bad magic")
3. version == 0x0001, else INVALID_PROGRAM ("unsupported version")
4. reserved == 0, else INVALID_PROGRAM ("reserved field nonzero")
5. code_size > 0 and code_size % 8 == 0, else INVALID_PROGRAM
6. file_size == 0x1A + code_size + data_size, else INVALID_PROGRAM
      ("truncated program" if short, "trailing data" if long)
7. entry < code_size and entry % 8 == 0, else INVALID_PROGRAM
      ("invalid entry point")
8. code_size + data_size ≤ 0xF000, else INVALID_PROGRAM
      ("invalid memory layout")
9. for each 8-byte slot in code: the per-slot checks from §2's table,
   else INVALID_INSTRUCTION (report the code-relative offset)
```

Only after all 9 steps pass does the loader copy code/data into virtual
memory, zero the rest, initialize registers (`PC = entry`, `SP = FP =
0x10000`, `FLAGS = 0`, `R[*] = 0`), and transfer control to the CPU loop.

Error reporting must include the *reason* (e.g. `bad magic`, `truncated
program`, `invalid jump target at code offset 0x38`) — "invalid program"
alone is not an acceptable diagnostic.

---

## 5. Initial virtual-machine state after loading

| Item | Value |
|------|-------|
| `MEM[0 .. code_size)` | code section bytes (read-only) |
| `MEM[code_size .. code_size+data_size)` | data section bytes |
| `MEM` elsewhere | `0x00` |
| `R0`–`R15` | `0` |
| `PC` | `entry` |
| `SP`, `FP` | `0x10000` |
| `FLAGS` | `0` |

---

## 6. Reference: minimal valid file

A program consisting of a single `HALT` (`01 FF FF 00 00 00 00 00`):

```
0000: 41 55 52 4F 52 41 01 00  01 00 08 00 00 00 00 00
0010: 00 00 00 00 00 00 00 00  00 00 01 FF FF 00 00 00
0020: 00 00
```

- magic ✓, version `0x0001` ✓, code_size `8` ✓, entry `0` ✓,
  data_size `0` ✓, reserved `0` ✓, total `0x1A + 8 = 34` bytes ✓.
- Observable behavior: exits immediately with code `R0 & 0xFF = 0`.

---

## 7. Assembler output contract

`tools/aurora-asm` must emit files satisfying every rule above, with:

- code labels resolved to code-relative byte offsets (multiples of 8);
- data labels resolved to absolute virtual addresses (`≥ code_size`);
- `class` bytes set per the opcode table;
- unused register fields set to `0xFF`, unused imm32 set to `0`;
- `entry` = offset of the first instruction (or of the label given by
  an entry directive, if the assembler supports one).

A test in `tests/byte/` re-validates assembler output with an independent
Python checker (not the assembler's own code path) to catch encoder bugs.
