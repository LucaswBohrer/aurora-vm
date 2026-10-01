# AURORA VM — Assembler Reference

**Tool:** `tools/aurora-asm` (Python 3, standard library only)
**Status:** phase 4 — the assembler is a *tool*, not the ISA authority.
The normative source remains `docs/ISA.md`; the golden vectors in
`docs/ISA.md` §12 validate the VM independently of this assembler.

---

## 1. Command line

```
aurora-asm [options] input.asm [-o output.bin]
```

| Option | Meaning |
|--------|---------|
| `-o FILE` | write bytecode to FILE (default: input path with `.bin` suffix) |
| `--help` | print help and exit (exit 0) |
| `--version` | print `aurora-asm <ver> (bytecode v1)` and exit (exit 0) |

Exit codes: `0` = success; `1` = assembly error (diagnostic on stderr,
no traceback); `2` = usage/file error (unknown option, missing input,
unreadable input, unwritable output, input == output).

Example:

```
$ python3 tools/aurora-asm examples/hello.asm -o /tmp/hello.bin
$ ./build/aurora run /tmp/hello.bin
Hello, world!
```

`tools/aurora-asm` is executable (shebang `#!/usr/bin/env python3`), so
`tools/aurora-asm in.asm -o out.bin` also works.

---

## 2. Source language

### 2.1 Lines

```
; full-line comment
label:                          ; label alone on a line
    MOV R0, 42                  ; instruction (indentation is free)
loop: JMP loop                  ; label + instruction on one line
msg: DB "Hello", 10, 0          ; label + data directive
```

- `;` starts a comment (ignored to end of line), except inside a
  double-quoted string literal.
- Blank lines are ignored.
- At most one instruction or data directive per line, optionally
  preceded by one label definition.

### 2.2 Case sensitivity

- Mnemonics, register names and directives are **case-insensitive**:
  `mov`, `MOV`, `Mov`, `r0`, `R0`, `db`, `DB` are all accepted.
- **Labels are case-sensitive**: `Loop` and `loop` are different labels.

### 2.3 Registers

Exactly `R0`–`R15`. Anything else register-shaped (`R16`, `R99`,
`R-1`, `RA`) is rejected with `invalid register`. There are no aliases.

### 2.4 Numeric literals

Decimal, hexadecimal (`0x`) and binary (`0b`), with an optional leading
`+`/`-`:

```
42  -1  0x1000  0xFF  0b101  -0x10  +7
```

Underscores, octal (`0o`), character literals (`'A'`) and floats are not
supported and are rejected.

### 2.5 Labels

- Definition: `name:` where `name` matches `[A-Za-z_][A-Za-z0-9_]*`.
- A label may precede an instruction, a data directive, or stand alone
  (it then marks the position of the *next* item).
- Labels are resolved in two passes; forward references are allowed.
- Defining the same name twice (in any section) → `duplicate label`.
- Referencing an undefined name → `undefined label`.

**Code labels** (before instructions) resolve to code-relative byte
offsets (multiples of 8). **Data labels** (before `DB`/`DW`/`DD`/`DQ`)
resolve to absolute virtual addresses (`code_size + offset`, per
`docs/BYTECODE.md` §3).

Jump and `CALL` targets must be **code labels** (or numeric addresses,
see §4). Jumping to a data label is rejected (`jump to data label`).

### 2.6 Operands

Operands are separated by **commas** (required between operands):

```
MOV R0, R1        ; ok
MOV R0 R1         ; syntax error: missing comma
```

Memory operands use square brackets, exactly as in the ISA text:

```
LOAD R0, [0x1000]     ; absolute address (class M)
LOAD R0, [R1]         ; register-indirect (class R)
STORE [0x1000], R1
STORE [R2], R1
LOADB R0, [R1]
STOREB [R2], R1
```

Inside `[...]` only a register, a numeric literal or a label is allowed
(no arithmetic: `[R1+4]` is rejected).

---

## 3. Instructions

One mnemonic, several operand shapes — the assembler selects the opcode
per `docs/ISA.md` §1. The full mapping (opcode, class, field placement):

| Assembly | Opcode | Class | Encoding |
|----------|--------|-------|----------|
| `NOP` | `0x00` | N | — |
| `HALT` | `0x01` | N | — |
| `RET` | `0x20` | N | — |
| `MOV Rd, Rs` | `0x02` | R | dst=Rd src=Rs |
| `MOV Rd, imm32` / `MOV Rd, label` | `0x03` | I | dst=Rd imm=imm32/address |
| `ADD Rd, Rs` / `SUB` / `MUL` / `DIV` / `AND` / `OR` / `XOR` | `0x04`/`0x06`/`0x08`/`0x0A`/`0x0E`/`0x10`/`0x12` | R | dst=Rd src=Rs |
| `ADD Rd, imm32` / `SUB` / `MUL` / `DIV` / `AND` / `OR` / `XOR` | `0x05`/`0x07`/`0x09`/`0x0B`/`0x0F`/`0x11`/`0x13` | I | dst=Rd imm=imm32 |
| `CMP Ra, Rb` | `0x15` | R | dst=Ra src=Rb |
| `CMP Ra, imm32` | `0x16` | I | dst=Ra imm=imm32 |
| `INC Rd` / `DEC Rd` / `NOT Rd` / `POP Rd` / `IN Rd` | `0x0C`/`0x0D`/`0x14`/`0x1E`/`0x2A` | r | **dst=Rd**, src=`0xFF` |
| `PUSH Rs` / `OUT Rs` / `OUTC Rs` | `0x1D`/`0x28`/`0x29` | r | dst=`0xFF`, **src=Rs** |
| `LOAD Rd, [a32]` | `0x17` | M | dst=Rd imm=a32 |
| `LOAD Rd, [Rs]` | `0x18` | R | dst=Rd src=Rs |
| `STORE [a32], Rs` | `0x19` | M | src=Rs imm=a32 |
| `STORE [Rd], Rs` | `0x1A` | R | dst=Rd src=Rs |
| `LOADB Rd, [Rs]` | `0x1B` | R | dst=Rd src=Rs |
| `STOREB [Rd], Rs` | `0x1C` | R | dst=Rd src=Rs |
| `CALL a32` | `0x1F` | J | imm=a32 |
| `JMP a32` / `JE` / `JNE` / `JG` / `JL` / `JGE` / `JLE` | `0x21`–`0x27` | J | imm=a32 |

Notes:

- Class-`r` field placement is per-opcode, **not** generic: `INC`,
  `DEC`, `NOT`, `POP`, `IN` put the register in `dst`; `PUSH`, `OUT`,
  `OUTC` put it in `src` (the phase-3 correction is preserved).
- Labels are accepted as the second operand of `MOV` only (→ `0x03`
  with imm32 = label address, per ISA §6.2), as `[...]` addresses, and
  as jump/`CALL` targets. A label used as an arithmetic immediate
  (`ADD R0, loop`) is rejected with `invalid operand`.
- Unused register fields are emitted as `0xFF`; unused imm32 as `0`.

---

## 4. Immediates and addresses

### 4.1 Class-I immediates (signed 32-bit pattern)

The literal's mathematical value must satisfy
`-2³¹ ≤ v ≤ 2³²−1`; it is encoded as the low 32 bits (two's complement).
Anything outside → `immediate out of range`. **No silent truncation.**

```
MOV R0, -1          ; ok → 0xFFFFFFFF (sign-extended by the CPU)
MOV R0, 0xFFFFFFFF  ; ok → same bits
MOV R0, 4294967295  ; ok → same bits
MOV R0, 4294967296  ; ERROR: immediate out of range
MOV R0, -2147483649 ; ERROR: immediate out of range
```

This mirrors the loader rule that class-I accepts any 32-bit pattern
(`docs/BYTECODE.md` §2).

### 4.2 Class-M addresses (unsigned, loader rule enforced)

`[a32]` must satisfy `0 ≤ a ≤ 0x10000 − 8` (the exact rule the loader
enforces for 64-bit accesses). Out-of-range numeric addresses are
rejected at assembly time with `address out of range` instead of
producing bytecode the loader would refuse.

### 4.3 Jump targets

A label (must be a code label) or a numeric literal. Numerics must be
`< code_size` and a multiple of 8, else `invalid jump target`. Jumps are
absolute byte offsets from the code base (`docs/ISA.md` §6.9, D07) —
there are no relative jumps.

---

## 5. Data directives

Data directives emit bytes into the **data section**, loaded at virtual
address `code_size` (`docs/BYTECODE.md` §3). Code and data lines may be
interleaved in the source; all code is laid out first, then all data,
each in source order.

```
msg:  DB "Hello, world!", 10, 0
mask: DW 0x1234, -1
val:  DD 0xDEADBEEF
big:  DQ 0x1122334455667788
```

| Directive | Item size | Accepted items |
|-----------|-----------|----------------|
| `DB` | 1 byte | numbers in `-128..255`, or `"string literals"` |
| `DW` | 2 bytes LE | numbers in `-2¹⁵..2¹⁶−1` |
| `DD` | 4 bytes LE | numbers in `-2³¹..2³²−1` |
| `DQ` | 8 bytes LE | numbers in `-2⁶³..2⁶⁴−1` |

String literals support escapes: `\n \t \r \0 \\ \" \xHH`.
A string containing any other non-printable byte must use `\xHH`.

`code_size + data_size` must stay ≤ `0xF000` (stack region), else the
assembler reports `program too large` rather than emitting a file the
loader would reject.

---

## 6. Output and entry point

The output is exactly the v1 container from `docs/BYTECODE.md`:

- 8-byte magic, version `0x0001`, `code_size` (> 0, multiple of 8),
  `entry`, `data_size`, reserved `0`, then code, then data.
- `entry` = offset of the first instruction (always `0` in the current
  layout). There is no entry-point directive.
- A source with no instructions is rejected (`empty program`); the
  assembler never emits a file the loader would refuse for size reasons.

Assembly is **deterministic**: the same `.asm` always produces
byte-identical `.bin` (no timestamps, no absolute paths, no hash-order
dependence).

---

## 7. Diagnostics

Format: `file:line:col: <category>: <detail>`. Examples:

```
prog.asm:3:9: unknown mnemonic: 'FOO'
prog.asm:5:11: invalid register: 'R16'
prog.asm:7:5: immediate out of range: 4294967296 does not fit in 32 bits
prog.asm:9:5: undefined label: 'done'
prog.asm:2:1: duplicate label: 'loop' already defined at line 1
prog.asm:12:5: jump to data label: 'msg' is a data label
prog.asm:4:12: invalid numeric literal: '0xZZ'
prog.asm:6:1: syntax error: expected instruction, got '...'
```

Categories: `unknown mnemonic`, `invalid register`, `invalid operand`,
`missing operand`, `unexpected operand`, `immediate out of range`,
`invalid numeric literal`, `invalid data operand`, `duplicate label`,
`undefined label`, `invalid label`, `jump to data label`,
`invalid jump target`, `address out of range`, `invalid directive`,
`syntax error`, `empty program`, `program too large`.

Normal input errors never produce a Python traceback (exit 1).

---

## 8. Worked example

```asm
; (20 + 10) * 3 = 90
    MOV R0, 20
    MOV R1, 10
    ADD R0, R1        ; R0 = 30
    MOV R2, 3
    MUL R0, R2        ; R0 = 90
    OUT R0            ; prints "90\n"
    HALT              ; exit code = 90
```

```
$ python3 tools/aurora-asm arith.asm -o arith.bin
$ ./build/aurora run arith.bin
90
$ echo $?
90
```

The bytes produced are exactly the ones in `docs/ISA.md` §11.
