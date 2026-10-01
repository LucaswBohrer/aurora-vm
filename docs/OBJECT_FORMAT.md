# AURORA VM — Object Format v1

**Status:** phase 7 (normative for `tools/aurora-asm -c` and `tools/aurora-ld`).
**Authority note:** this document specifies *tooling* file formats. The ISA
authority remains `docs/ISA.md`; the executable container authority remains
`docs/BYTECODE.md`. Nothing here changes the ISA, the bytecode v1
executable format, the loader, or the CPU.

All multi-byte integers are **little-endian** (matching bytecode v1).
There is no string table in v1: symbol names are inline, fixed-size,
NUL-padded (see §4).

---

## 1. Why this format exists

`tools/aurora-asm` historically resolved every label to a final address
in a single pass over one source file. Multi-module programs need an
intermediate representation where:

- code and data are stored **module-relative** (final addresses unknown),
- every label becomes a **symbol** (local, global, or undefined),
- every symbolic address reference becomes a **relocation** the linker
  resolves after choosing the final layout.

The object file carries exactly that information — nothing else.
There is deliberately no `.bss`, `.rodata`, TLS, debug info, dynamic
linking, or string table in v1 (see `docs/DECISIONS.md` D27).

---

## 2. File layout

```text
+------------------+
| header (48 bytes)|  offset 0
+------------------+
| .code            |  offset = code_offset,  size = code_size
+------------------+
| .data            |  offset = data_offset,  size = data_size
+------------------+
| symbol table     |  offset = symbol_offset, count = symbol_count
+------------------+
| relocation table |  offset = reloc_offset,  count = reloc_count
+------------------+
```

The four regions may appear in any file order, but they must not
overlap each other or the 48-byte header, and every
`offset + size` must lie within the file without u32/u64 overflow.

---

## 3. Header (48 bytes, byte-exact)

| offset | size | field         | endian | meaning |
|--------|------|---------------|--------|---------|
| 0      | 8    | `magic`       | —      | `41 55 52 4F 52 41 4F 31` = `"AURORAO1"` |
| 8      | 2    | `version`     | LE     | `0x0001`; only version 1 is accepted |
| 10     | 2    | `header_size` | LE     | `0x0030` (48); must equal 48 |
| 12     | 4    | `flags`       | LE     | reserved; must be `0` |
| 16     | 4    | `code_size`   | LE     | `.code` size in bytes; multiple of 8 (`0` allowed: data-only module) |
| 20     | 4    | `code_offset` | LE     | file offset of `.code` |
| 24     | 4    | `data_size`   | LE     | `.data` size in bytes |
| 28     | 4    | `data_offset` | LE     | file offset of `.data` |
| 32     | 4    | `symbol_count`| LE     | number of symbol table entries |
| 36     | 4    | `symbol_offset`| LE    | file offset of the symbol table |
| 40     | 4    | `reloc_count` | LE     | number of relocation entries |
| 44     | 4    | `reloc_offset`| LE     | file offset of the relocation table |

### Validation (all must hold, else the object is rejected)

1. `magic` is exactly `"AURORAO1"`.
2. `version == 0x0001`.
3. `header_size == 48`.
4. `flags == 0`.
5. `code_size % 8 == 0`.
6. `code_size + data_size <= 0xF000` (a module that alone exceeds the
   code+data limit can never link; the linker re-checks the *sum*).
7. Each of the four regions satisfies
   `offset + size <= file_size` computed without overflow
   (reject if `offset > file_size - size`).
8. No two regions overlap, and no region overlaps `[0, 48)`.
9. `symbol_count * 76 + symbol_offset <= file_size` (76 = symbol entry
   size); likewise `reloc_count * 12 + reloc_offset <= file_size`.
   (Covered by rule 7; stated explicitly because the counts multiply.)

There is no entry-point field: the executable entry policy is
"`entry = 0`, first object on the link line provides the entry code"
(`docs/LINKER.md` §6). No new executable-header field was created for
the linker.

---

## 4. Symbol table

Each entry is **76 bytes**:

| offset | size | field    | endian | meaning |
|--------|------|----------|--------|---------|
| 0      | 64   | `name`   | —      | NUL-terminated, NUL-padded; see name rules below |
| 64     | 1    | `bind`   | —      | `0` = LOCAL, `1` = GLOBAL, `2` = UNDEFINED |
| 65     | 1    | `sect`   | —      | `0` = CODE, `1` = DATA, `0xFF` = NONE |
| 66     | 2    | reserved | —      | must be `0` |
| 68     | 4    | `offset` | LE     | section-relative byte offset |
| 72     | 4    | reserved | —      | must be `0` |

### Bindings

- **LOCAL** — defined in this object, visible only here. Same-named
  locals in different objects never conflict.
- **GLOBAL** — defined in this object, visible to the linker for
  cross-module resolution. Declared in source with the `.global`
  directive (`docs/ASSEMBLER.md` §9).
- **UNDEFINED** — referenced by this object, defined elsewhere. The
  assembler emits one for every label that is referenced but not
  defined when assembling with `-c`; `sect` is `NONE` and `offset`
  is `0`.

### Per-entry validation

- `name`: 1–63 bytes before the first NUL; every byte matches
  `[A-Za-z0-9_]` with the first byte matching `[A-Za-z_]`
  (same alphabet as assembly labels); padding bytes after the first
  NUL are all `0`; at least one NUL exists within the 64 bytes.
  Empty names are rejected.
- `bind` ∈ `{0, 1, 2}`; `sect` ∈ `{0, 1, 0xFF}`.
- `UNDEFINED` ⇒ `sect == NONE` and `offset == 0`.
- `LOCAL`/`GLOBAL` with `sect == CODE` ⇒ `offset < code_size`
  and `offset % 8 == 0`.
- `LOCAL`/`GLOBAL` with `sect == DATA` ⇒ `offset < data_size`
  (`data_size == 0` ⇒ no DATA symbol may exist).
- `LOCAL`/`GLOBAL` with `sect == NONE` ⇒ rejected.
- Reserved bytes are `0`.
- No two entries in one object share a name (the assembler never
  emits duplicates; the validator rejects them).

### Name rules (normative)

- Case-sensitive: `Main` ≠ `main`.
- Maximum 63 significant characters (field limit); longer source
  labels are rejected by the assembler with `-c`.
- The `svc_` prefix is reserved for the runtime ABI (`docs/RUNTIME.md`;
  D26). Defining a non-runtime global `svc_*` symbol is a link error
  only if it collides — the prefix is a convention, not a validator
  rule, exactly as in phase 6.
- Deterministic: resolution never depends on hash order, filesystem
  order, or timestamps.

---

## 5. Relocation table

Each entry is **12 bytes**. In v1, relocations patch only the `.code`
section (data directives cannot reference symbols — `docs/ASSEMBLER.md`
§5 — so `.data` never needs relocation).

| offset | size | field    | endian | meaning |
|--------|------|----------|--------|---------|
| 0      | 1    | `type`   | —      | `1` = `CODE32`, `2` = `ADDR32`, `3` = `MEM32` |
| 1      | 1    | reserved | —      | must be `0` |
| 2      | 2    | reserved | —      | must be `0` |
| 4      | 4    | `offset` | LE     | byte offset of the imm32 field within `.code` |
| 8      | 4    | `sym`    | LE     | symbol table index |

### Per-entry validation

- `type` ∈ `{1, 2, 3}`; reserved bytes are `0`.
- `sym < symbol_count` (else "relocation to nonexistent symbol").
- `offset < code_size` and `offset % 8 == 4` (the imm32 field is bytes
  4–7 of an 8-byte instruction).
- At most one relocation per imm32 field (duplicate patch offsets are
  rejected — the assembler never emits them).

### Relocation types (normative)

Let `S` be the symbol's final absolute address:

```text
S = code_base[defobj] + sym.offset    if sym.sect == CODE
S = data_base[defobj] + sym.offset    if sym.sect == DATA
```

(`code_base`/`data_base` are the linker's final section bases;
`docs/LINKER.md` §4.) There is **no addend** in v1: the assembly
language has no `label+const` operand syntax, so every symbolic
reference denotes exactly the symbol's address. The patched value is:

```text
imm32 := S   (4 bytes, little-endian)
```

The `.o` stores `0` at every relocation site.

| type | name | emitted for | formula | validation (link error otherwise) |
|------|------|-------------|---------|-----------------------------------|
| 1 | `CODE32` | `CALL label`, `JMP`/`Jcc label` (class J) | `imm32 := S` | symbol must be a CODE symbol; `S < final_code_size` and `S % 8 == 0` |
| 2 | `ADDR32` | `MOV Rd, label` (class I) | `imm32 := S` | `0 ≤ S ≤ 0xFFFFFFFF` (fits the 32-bit field; always true under the v1 layout — the check is structural, never silent truncation) |
| 3 | `MEM32` | `LOAD`/`STORE [label]` (class M) | `imm32 := S` | `0 ≤ S ≤ 0x10000 - 8` (the exact loader rule for 64-bit accesses, `docs/BYTECODE.md` §2) |

Notes:

- `CODE32` against a DATA symbol (or vice versa for `MEM32` against a
  symbol whose address violates the range) is a **link error**, not a
  silent miscompile. The assembler's `-c` mode already rejects
  "jump to data label" for module-local labels; the linker enforces the
  same rule for cross-module symbols.
- `MEM32` symbols may be CODE or DATA: reads from the code segment are
  legal (D06); only the `≤ 0x10000 - 8` bound is enforced.
- Numeric (non-symbolic) operands are never relocated. In `-c` mode the
  assembler accepts numeric jump targets without the `< code_size`
  check (the final code size is unknowable); the linker validates every
  class-J target in the final image (`< final_code_size`, 8-aligned)
  and reports a link error otherwise, so the linker never emits a
  `.bin` the loader would refuse.

---

## 6. Sections

v1 has exactly two sections, mirroring how the assembler already lays
out programs (`docs/ASSEMBLER.md` §5: all code first, then all data):

- **`.code`** — 8-byte instructions (`[opcode|dst|src|class|imm32 LE]`,
  `docs/ISA.md` §4). Symbolic imm32 fields hold `0` until linked.
- **`.data`** — raw bytes from `DB`/`DW`/`DD`/`DQ`. Never relocated
  in v1.

There is no `.bss`, `.rodata`, TLS, or debug section in v1. Anything
outside `[0, code_size)` is guest-writable at run time, exactly as in
`docs/BYTECODE.md` §5; the object format adds no new memory region.

---

## 7. Limits

| item | limit | enforced by |
|------|-------|-------------|
| symbol name | 1–63 chars, `[A-Za-z_][A-Za-z0-9_]*` | assembler (`-c`), validator |
| `code_size` per object | multiple of 8 | assembler, validator |
| `code_size + data_size` per object | `≤ 0xF000` | assembler (`-c`), validator |
| `code_size + data_size` final | `≤ 0xF000` | linker |
| final `code_size` | `> 0` (loader rule) | linker |
| final addresses | `< 0x10000`, wraparound-safe checks | linker |
| relocation field | 32-bit range per type (§5) | linker (link error, never truncation) |

---

## 8. Determinism

Object emission is deterministic: same `.asm` → byte-identical `.o`
(no timestamps, no paths, no hash-order dependence). The symbol table
is emitted in first-reference order (definitions in source order, then
undefined symbols in first-reference order); the relocation table is
emitted in code order. Both orders are fully determined by the source.

---

## 9. What is deliberately NOT in v1

Weak symbols, versioned symbols, common symbols, `.bss`, string tables,
addends, PC-relative relocations, section garbage collection, debug
symbols, dynamic linking. If any of these becomes necessary: stop, use
the D19/D14 change protocol, document first.

---

## 10. Worked byte example

`hello.o` from:

```asm
    CALL greet
    HALT
greet:
    OUTC R0 ...   ; (abbreviated)
```

is out of scope for a hand trace here; see
`tests/linker/run_linker_tests.py` (`test_golden_objects`), which
constructs two `.o` files byte-by-byte with `struct` — independent of
both `tools/aurora-asm` and `tools/aurora-ld` — and documents every
byte. Those hand-built objects are the normative byte-level examples.
