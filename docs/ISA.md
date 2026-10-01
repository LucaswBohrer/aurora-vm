# AURORA VM — Instruction Set Architecture (ISA) Reference

**Version:** 1.0 (matches bytecode format version `0x0001`)
**Status:** ❄️ FROZEN — normative source of the ISA.

This ISA is frozen at exactly **43 opcodes** (`0x00`–`0x2A`) with the
numeric values, formats, operands, semantics, affected flags and possible
errors defined below. After this revision, no implementation may silently
create, remove or alter any instruction.

**Change protocol (normative).** See §0 below.

This document is written so that an independent developer can implement a
compatible AURORA VM without reading the reference implementation.

## 0. Freeze and change protocol (normative)

1. This ISA is frozen at exactly 43 opcodes (`0x00`–`0x2A`).
2. No implementation may silently create, remove or alter any
   instruction — its number, format, operands, semantics, flags or
   errors.
3. If a change becomes necessary during implementation: (a) stop
   implementing the affected part; (b) document the problem; (c) update
   this specification; (d) record the decision in `docs/DECISIONS.md`;
   (e) only then continue.
4. Any frozen-spec change also freezes a new revision: bump the ISA
   version marker in this header and, if the encoding changes, the
   bytecode version in `BYTECODE.md`.

---

## 1. Two levels of the ISA

**Assembly level** — what programmers write. Clean mnemonics as required by
the challenge specification: `MOV`, `ADD`, `JMP`, … One mnemonic may accept
several operand shapes.

**Encoding level** — what the loader and CPU see. Each operand shape has its
own opcode byte (43 opcodes). The assembler translates mnemonic + operand
shapes to the correct opcode; the CPU dispatches purely on the opcode byte.

Example:

```asm
MOV R0, R1    ;  → opcode 0x02 (MOV_RR)
MOV R0, 10    ;  → opcode 0x03 (MOV_RI)
MOV R0, msg   ;  → opcode 0x03 (MOV_RI), imm32 = address of msg
```

---

## 2. Registers

### 2.1 General-purpose registers

16 registers, `R0`–`R15`, each 64 bits wide. No dedicated roles — the
assembler and calling convention assign none. Initial value: `0`.

### 2.2 Special registers

| Register | Width | Init | Meaning |
|----------|-------|------|---------|
| `PC` | 64 | `entry` | Program counter: **byte offset** from the code-segment base of the next instruction to fetch. Always 8-aligned while running. |
| `SP` | 64 | `0x10000` | Stack pointer: byte address of the top of stack. `0x10000` is the empty-stack sentinel (one past the top of memory). |
| `FP` | 64 | `0x10000` | Frame pointer: byte address of the current frame base (see §8). |
| `FLAGS` | 64 | `0` | Status flags, bits 3–0 used (see §3). |

`PC` is the only instruction pointer; there is no separate IP register.

### 2.3 Register encoding in bytecode

One byte per register operand: `0x00`–`0x0F` = `R0`–`R15`,
`0xFF` = "operand unused". Any other value is `INVALID_REGISTER` /
`INVALID_INSTRUCTION`.

---

## 3. Flags

`FLAGS` bits:

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | `ZERO` (Z) | last flag-setting result was zero |
| 1 | `CARRY` (C) | unsigned carry out (ADD/MUL) or borrow (SUB/CMP) |
| 2 | `NEGATIVE` (N) | bit 63 of the last flag-setting result |
| 3 | `OVERFLOW` (V) | signed overflow occurred |

Bits 63–4 are reserved and always read as 0.

### 3.1 Precise flag semantics

`a`, `b` are the u64 operands; `r` is the u64 result (arithmetic mod 2⁶⁴).
`s(x)` denotes `x` interpreted as signed 64-bit.

- **ADD** (`r = a + b`):
  `C = (r < a)` — carry out of bit 63.
  `V = ((a ^ r) & (b ^ r)) >> 63` — signed overflow.
  `Z = (r == 0)`. `N = r >> 63`.
- **SUB / CMP** (`r = a - b`):
  `C = (a < b)` — borrow (x86 CF convention: set when unsigned underflow).
  `V = ((a ^ b) & (a ^ r)) >> 63`.
  `Z = (r == 0)`. `N = r >> 63`.
- **MUL** (unsigned 128-bit product `p = a · b`, `r = low₆₄(p)`):
  `C = V = (high₆₄(p) != 0)` — set iff the true product does not fit in
  64 bits. `Z = (r == 0)`. `N = r >> 63`.
- **DIV** (signed: `r = s(a) / s(b)`, remainder discarded):
  `C = 0`. `V = 1` only when `a = 0x8000000000000000` and `s(b) = -1`
  (result defined as `0x8000000000000000`); otherwise `V = 0`.
  `Z = (r == 0)`. `N = r >> 63`.
  Division by zero is **not** a flag case — it is the fatal error
  `DIVISION_BY_ZERO`.
- **INC** (`r = a + 1`): **C unchanged**. `V = (a = 0x7FFFFFFFFFFFFFFF)`.
  `Z = (r == 0)`. `N = r >> 63`.
- **DEC** (`r = a - 1`): **C unchanged**. `V = (a = 0x8000000000000000)`.
  `Z`, `N` as above.
- **AND / OR / XOR**: `Z = (r == 0)`. `N = r >> 63`. `C = 0`. `V = 0`.
- **NOT**: flags **unchanged**.
- **All other instructions** (`MOV`, `LOAD`, `STORE`, `LOADB`, `STOREB`,
  `PUSH`, `POP`, `CALL`, `RET`, `JMP`, `Jcc`, `NOP`, `HALT`, `IN`, `OUT`,
  `OUTC`): flags **unchanged**.

### 3.2 Conditional jumps (signed)

`CMP Ra, Rb` sets flags from `Ra - Rb` and discards the result.

| Jump | Condition (on flags after CMP) |
|------|-------------------------------|
| `JE`  | `Z = 1` |
| `JNE` | `Z = 0` |
| `JG`  | `Z = 0 ∧ N = V` |
| `JL`  | `N ≠ V` |
| `JGE` | `N = V` |
| `JLE` | `Z = 1 ∨ N ≠ V` |

These are the x86 signed-comparison semantics.

---

## 4. Instruction encoding (8 bytes, fixed width)

```
Byte:   0        1        2        3        4..7
Field:  opcode   dst      src      class    imm32 (little-endian)
```

- `opcode`: `0x00`–`0x2A` (see §6). Anything else: `INVALID_OPCODE`
  (at runtime) / `INVALID_INSTRUCTION` (loader scan).
- `dst`, `src`: register encoding per §2.3.
- `class`: redundant format tag, emitted by the assembler, **validated by
  the loader** (must equal the class the opcode requires):
  `0x00` = N (none) · `0x01` = R (dst+src regs) · `0x02` = I (dst reg +
  imm32) · `0x03` = r (single reg) · `0x04` = M (absolute address + reg) ·
  `0x05` = J (absolute code address).
- `imm32`: for class I, sign-extended to 64 bits when used as an integer;
  for classes M/J, an unsigned byte offset/address. For classes N/R/r it
  **must be 0** (loader-enforced).

---

## 5. Memory model (summary; full detail in `docs/MEMORY.md`)

64 KiB, byte-addressable, `0x0000`–`0xFFFF`.

```
0x0000: CODE  (code_size bytes, read-only)
        DATA  (data_size bytes, read-write, base address = code_size)
        …free…
0xF000: STACK (0xF000–0xFFFF, 4 KiB, grows toward 0xF000)
```

- 64-bit loads/stores may be unaligned; only bounds are checked.
- Read/write of `[addr, addr+size)` with `addr > 0x10000 − size` →
  `INVALID_MEMORY_ACCESS`. The comparison is defined without wraparound
  (a raw `addr + size` in u64 arithmetic could wrap for huge register
  values; implementations must compare as `addr > 0x10000 − size`).
- Any write with `addr < code_size` (i.e. intersecting the code segment) →
  `WRITE_TO_CODE`. Reads from the code segment are allowed.

---

## 6. Opcode reference

Notation: `Rd`/`Rs`/`Ra`/`Rb` = registers; `sext(x)` = sign-extend imm32
to 64 bits; `mem64[a]` / `mem8[a]` = checked memory access.

### 6.1 System

| Op | Asm | Cls | Encoding | Semantics | Flags | Errors |
|----|-----|-----|----------|-----------|-------|--------|
| 0x00 | `NOP` | N | — | No operation. `PC += 8`. | — | — |
| 0x01 | `HALT` | N | — | Normal termination (see §6.1.1). Process exit code = `R0 & 0xFF`. | — | — |

#### 6.1.1 HALT vs. fatal error (normative)

`HALT` and fatal errors are **disjoint, machine-checkable categories**:

```
HALT         → normal termination, exit code = R0 & 0xFF   (0–255)
fatal error  → abnormal termination, exit code = 100 + id  (101–112)
```

- `HALT ≠ runtime error`, in all cases. A program ending in `HALT` with
  `R0 = 0` exits `0` — that is success, not an error.
- The VM **never** continues after a fatal error; it prints
  `aurora: error: <NAME>: <detail>` to stderr and exits `100 + id`.
- The debugger must distinguish the two states with different status
  lines (see `docs/DEBUGGER.md`): `halted (exit code N)` vs.
  `fatal error: <NAME>`.
- Tests assert the category by exit code **and** by the error name on
  stderr (see `docs/TESTING.md` §9).

### 6.2 Data movement

| Op | Asm | Cls | Encoding | Semantics | Flags | Errors |
|----|-----|-----|----------|-----------|-------|--------|
| 0x02 | `MOV Rd, Rs` | R | dst=Rd src=Rs | `Rd = Rs` | — | — |
| 0x03 | `MOV Rd, imm32` | I | dst=Rd imm=imm32 | `Rd = sext(imm32)` | — | — |

`MOV Rd, label` assembles to `0x03` with imm32 = label address.

### 6.3 Arithmetic

| Op | Asm | Cls | Semantics | Flags |
|----|-----|-----|-----------|-------|
| 0x04 | `ADD Rd, Rs` | R | `Rd = Rd + Rs` (mod 2⁶⁴) | §3.1 ADD |
| 0x05 | `ADD Rd, imm32` | I | `Rd = Rd + sext(imm32)` | §3.1 ADD |
| 0x06 | `SUB Rd, Rs` | R | `Rd = Rd - Rs` | §3.1 SUB |
| 0x07 | `SUB Rd, imm32` | I | `Rd = Rd - sext(imm32)` | §3.1 SUB |
| 0x08 | `MUL Rd, Rs` | R | `Rd = low₆₄(Rd · Rs)` unsigned | §3.1 MUL |
| 0x09 | `MUL Rd, imm32` | I | `Rd = low₆₄(Rd · sext(imm32))` unsigned | §3.1 MUL |
| 0x0A | `DIV Rd, Rs` | R | `Rd = sdiv(Rd, Rs)` | §3.1 DIV |
| 0x0B | `DIV Rd, imm32` | I | `Rd = sdiv(Rd, sext(imm32))` | §3.1 DIV |
| 0x0C | `INC Rd` | r | `Rd = Rd + 1` | §3.1 INC (C preserved) |
| 0x0D | `DEC Rd` | r | `Rd = Rd - 1` | §3.1 DEC (C preserved) |

`DIV` with divisor 0 → `DIVISION_BY_ZERO` (fatal, no flags updated).

### 6.4 Logic

| Op | Asm | Cls | Semantics | Flags |
|----|-----|-----|-----------|-------|
| 0x0E | `AND Rd, Rs` | R | `Rd = Rd & Rs` | Z,N; C=V=0 |
| 0x0F | `AND Rd, imm32` | I | `Rd = Rd & sext(imm32)` | Z,N; C=V=0 |
| 0x10 | `OR Rd, Rs` | R | `Rd = Rd \| Rs` | Z,N; C=V=0 |
| 0x11 | `OR Rd, imm32` | I | `Rd = Rd \| sext(imm32)` | Z,N; C=V=0 |
| 0x12 | `XOR Rd, Rs` | R | `Rd = Rd ^ Rs` | Z,N; C=V=0 |
| 0x13 | `XOR Rd, imm32` | I | `Rd = Rd ^ sext(imm32)` | Z,N; C=V=0 |
| 0x14 | `NOT Rd` | r | `Rd = ~Rd` | unchanged |

### 6.5 Comparison

| Op | Asm | Cls | Semantics | Flags |
|----|-----|-----|-----------|-------|
| 0x15 | `CMP Ra, Rb` | R | compute `Ra - Rb`, discard | §3.1 SUB |
| 0x16 | `CMP Ra, imm32` | I | compute `Ra - sext(imm32)`, discard | §3.1 SUB |

### 6.6 Memory

| Op | Asm | Cls | Encoding | Semantics | Errors |
|----|-----|-----|----------|-----------|--------|
| 0x17 | `LOAD Rd, [a32]` | M | dst=Rd imm=a32 | `Rd = mem64[a32]` | `INVALID_MEMORY_ACCESS` |
| 0x18 | `LOAD Rd, [Rs]` | R | dst=Rd src=Rs | `Rd = mem64[Rs]` | `INVALID_MEMORY_ACCESS` |
| 0x19 | `STORE [a32], Rs` | M | src=Rs imm=a32 | `mem64[a32] = Rs` | `INVALID_MEMORY_ACCESS`, `WRITE_TO_CODE` |
| 0x1A | `STORE [Rd], Rs` | R | dst=Rd src=Rs | `mem64[Rd] = Rs` | `INVALID_MEMORY_ACCESS`, `WRITE_TO_CODE` |
| 0x1B | `LOADB Rd, [Rs]` | R | dst=Rd src=Rs | `Rd = zero_extend(mem8[Rs])` | `INVALID_MEMORY_ACCESS` |
| 0x1C | `STOREB [Rd], Rs` | R | dst=Rd src=Rs | `mem8[Rd] = Rs[7:0]` | `INVALID_MEMORY_ACCESS`, `WRITE_TO_CODE` |

`LOADB`/`STOREB` exist for byte strings (null-terminated text). Address
checks (wraparound-safe): 64-bit ops require `addr ≤ 0x10000 − 8`; byte
ops require `addr ≤ 0x10000 − 1`. Check order inside a handler: memory
bounds first, then the code-segment write protection — either violation
is fatal, so the order is unobservable except through which error name
is reported.

### 6.7 Stack

| Op | Asm | Cls | Semantics | Errors |
|----|-----|-----|-----------|--------|
| 0x1D | `PUSH Rs` | r | `SP -= 8`; require `SP ≥ 0xF000`; `mem64[SP] = Rs` | `STACK_OVERFLOW` |
| 0x1E | `POP Rd` | r | require `SP < 0x10000`; `Rd = mem64[SP]`; `SP += 8` | `STACK_UNDERFLOW` |

Push order: the bound is checked **before** `SP` is modified, so a failed
`PUSH` leaves `SP` unchanged.

### 6.8 Functions

| Op | Asm | Cls | Semantics | Errors |
|----|-----|-----|-----------|--------|
| 0x1F | `CALL a32` | J | `push(PC+8)`; `push(FP)`; `FP = SP`; `PC = a32` | `STACK_OVERFLOW`, `INVALID_PC` |
| 0x20 | `RET` | N | `SP = FP`; `FP = pop()`; `PC = pop()`; validate `PC` | `STACK_UNDERFLOW`, `INVALID_PC` |

`push(x)` is the §6.7 PUSH primitive (including its overflow check);
`pop()` the POP primitive (including underflow check). The target/return
address must satisfy `addr < code_size ∧ addr % 8 = 0`, else `INVALID_PC`.
The loader pre-validates every static `CALL` target, so `INVALID_PC` from
`CALL` is defense-in-depth; from `RET` it guards against corrupted stacks.

### 6.9 Control flow

| Op | Asm | Cls | Semantics |
|----|-----|-----|-----------|
| 0x21 | `JMP a32` | J | `PC = a32` |
| 0x22 | `JE a32` | J | `if Z: PC = a32 else PC += 8` |
| 0x23 | `JNE a32` | J | `if ¬Z: PC = a32 else PC += 8` |
| 0x24 | `JG a32` | J | `if ¬Z ∧ N=V: PC = a32 else PC += 8` |
| 0x25 | `JL a32` | J | `if N≠V: PC = a32 else PC += 8` |
| 0x26 | `JGE a32` | J | `if N=V: PC = a32 else PC += 8` |
| 0x27 | `JLE a32` | J | `if Z ∨ N≠V: PC = a32 else PC += 8` |

`a32` is an absolute byte offset from the code-segment base. The loader
verifies `a32 < code_size ∧ a32 % 8 = 0` for every jump in the program.

### 6.10 I/O

| Op | Asm | Cls | Semantics | Errors |
|----|-----|-----|-----------|--------|
| 0x28 | `OUT Rs` | r | Write `Rs` as signed decimal ASCII followed by `\n` to stdout | `IO_ERROR` |
| 0x29 | `OUTC Rs` | r | Write low byte of `Rs` to stdout | `IO_ERROR` |
| 0x2A | `IN Rd` | r | Blocking read of 1 byte from stdin: `Rd` = zero-extended byte; on EOF `Rd = 0xFFFFFFFFFFFFFFFF` | `IO_ERROR` |

`OUT` of `0x8000000000000000` prints `-9223372036854775808` (no negation
overflow in the conversion routine — implement it carefully).

---

## 7. Instruction fetch / decode / execute (normative pseudocode)

```
state: R[16], PC, SP, FP, FLAGS, MEM[65536], code_size
initial: R[*]=0, PC=entry, SP=FP=0x10000, FLAGS=0, MEM zeroed,
         MEM[0:code_size] = code, MEM[code_size:code_size+data_size] = data

steps = 0
loop forever:
    if steps >= max_steps and max_steps != 0: die(MAX_STEPS_EXCEEDED)
    steps += 1
    if PC >= code_size or PC % 8 != 0: die(INVALID_PC)
    instr = MEM[PC .. PC+8)                    # fetch
    op = instr[0]
    if op > 0x2A: die(INVALID_OPCODE)          # defense in depth
    dispatch(op, instr)                        # execute §6 handler
    # each handler either sets PC = target or falls through with PC += 8
```

Notes for an independent implementation:

- Dispatch may be a jump table, a switch, or chained conditionals — the
  observable behavior must match §6 exactly, including flag updates and
  the order of error checks within each handler.
- Within a handler, when several error conditions could trigger, check in
  this order: (1) operand validity, (2) stack bounds, (3) memory bounds,
  (4) code-segment write protection, (5) arithmetic faults. Any fatal
  error aborts the VM immediately; partial state updates before the error
  are unobservable (the process exits).
- `FLAGS` bits 63–4 must read 0 at all times; handlers only set bits 3–0.

---

## 8. Calling convention (normative)

```
caller:                    callee:
  ...                        ; FP -> [saved FP][ret addr]...
  CALL func                  ; on entry: FP points at saved-FP slot
  ...                        ; locals (if any) live BELOW FP (lower addr)
                             RET
```

Stack frame layout after `CALL` (addresses grow down):

```
higher addresses
  [return address]   <- SP before CALL
  [saved FP]         <- SP == FP after CALL
lower addresses      <- PUSHed locals go here
```

`RET` sequence: `SP = FP` (drops the whole frame including locals),
`FP = pop()`, `PC = pop()`. After `RET`, `SP`/`FP` are exactly as before
the `CALL`. Recursion and arbitrary nesting follow from this.

Leaf functions that need no frame still pay the two pushes — uniformity
over micro-optimization, and it makes `backtrace` (debugger) a simple FP
chain walk: `FP -> saved FP -> saved FP …` until `FP = 0x10000`.

---

## 9. Determinism (normative)

The VM **MUST** be deterministic:

```
same bytecode + same initial state + same configuration
        ⇒ same registers, same memory, same stack,
          same flags, same output, same exit code
```

- "Initial state" is defined by `BYTECODE.md` §5 (registers zeroed,
  `PC = entry`, `SP = FP = 0x10000`, `FLAGS = 0`, memory zeroed except
  loaded code/data).
- "Configuration" is the CLI configuration (`--max-steps`, run vs.
  debug mode — debug mode may pause for user input but must not alter
  guest state).
- The **only** legitimate source of nondeterminism is stdin bytes
  consumed by `IN`. It is documented, not hidden: two runs with
  different stdin are *expected* to differ; two runs with identical
  stdin must be bit-identical.
- There is no RNG, no wall-clock, no host-address-dependent behavior;
  all addresses are virtual.

Conformance is tested per `docs/TESTING.md` §7 (every program and every
golden vector runs twice; outputs are byte-compared).

---

## 10. Reserved opcodes

`0x2B`–`0xFF` are reserved. The loader rejects them (`INVALID_INSTRUCTION`);
the CPU rejects them (`INVALID_OPCODE`). Future ISA revisions may assign
them (e.g. unsigned jumps `JA/JB`, shifts) with a bytecode version bump.

---

## 11. Worked example

```asm
; (20 + 10) * 3 = 90
    MOV R0, 20
    MOV R1, 10
    ADD R0, R1        ; R0 = 30, Z=0 C=0 N=0 V=0
    MOV R2, 3
    MUL R0, R2        ; R0 = 90
    OUT R0            ; prints "90\n"
    HALT              ; exit code = 90 & 0xFF = 90
```

Bytecode (offsets are code-relative; `class` bytes shown):

```
0x00: 03 00 FF 02 14 00 00 00   MOV_RI R0, 20
0x08: 03 01 FF 02 0A 00 00 00   MOV_RI R1, 10
0x10: 04 00 01 01 00 00 00 00   ADD_RR R0, R1
0x18: 03 02 FF 02 03 00 00 00   MOV_RI R2, 3
0x20: 08 00 02 01 00 00 00 00   MUL_RR R0, R2
0x28: 28 FF 00 03 00 00 00 00   OUT_R R0
0x30: 01 FF FF 00 00 00 00 00   HALT
```

Expected observable behavior: stdout = `90\n`, exit code = 90.

---

## 12. Golden test vectors (normative)

These vectors are the **executable definition** of the ISA. They exist so
the VM can be validated **without the assembler**: every vector gives the
exact expected bytecode, so a test may feed hand-written bytes to the VM
and compare the resulting state bit-for-bit. If the implementation
disagrees with a vector, the implementation is wrong.

**File layout for every vector.** 26-byte header + code bytes:

```
header: 41 55 52 4F 52 41 01 00      ; magic "AURORA" + 01 00
        01 00                        ; version 0x0001
        <code_size: u32 LE>          ; per vector
        00 00 00 00                  ; entry = 0
        00 00 00 00                  ; data_size = 0
        00 00 00 00                  ; reserved = 0
code:   <per vector, 8 bytes per instruction>
```

**Initial state for every vector** (per `BYTECODE.md` §5): `R0–R15 = 0`,
`PC = 0`, `SP = FP = 0x10000`, `FLAGS = 0`, memory zeroed except the
loaded code. Stdin: empty. `--max-steps`: default.

**Notation:** only non-zero registers / non-default state are listed.
`FLAGS` is given as a number (bit0=Z, bit1=C, bit2=N, bit3=V).
"Stack residue" = bytes the VM is *expected* to leave in the stack
region (PUSH/POP/CALL/RET do not erase memory).

The conformance harness is specified in `docs/TESTING.md` §2:
hand-written `.bin` fixtures + `aurora run` (stdout/exit) + scripted
`aurora debug` sessions (registers/flags/memory/stack).

### V1 — MOV register/register

```asm
MOV R1, 10
MOV R0, R1
HALT
```

code_size = 24 (`18 00 00 00`):

```
03 01 FF 02 0A 00 00 00    ; MOV_RI R1, 10
02 00 01 01 00 00 00 00    ; MOV_RR R0, R1
01 FF FF 00 00 00 00 00    ; HALT
```

- Registers: `R0 = 10`, `R1 = 10`.
- Flags: `FLAGS = 0` (MOV does not touch flags).
- Stack: `SP = FP = 0x10000`.
- Output: none. Exit code: `10`.

### V2 — MOV immediate (negative, sign extension)

```asm
MOV R5, -1
HALT
```

code_size = 16 (`10 00 00 00`):

```
03 05 FF 02 FF FF FF FF    ; MOV_RI R5, 0xFFFFFFFF → sign-extended
01 FF FF 00 00 00 00 00    ; HALT
```

- Registers: `R5 = 0xFFFFFFFFFFFFFFFF`.
- Flags: `FLAGS = 0`.
- Output: none. Exit code: `0` (`R0 & 0xFF`; `R0` was never written).

### V3 — ADD with carry and zero flags

```asm
MOV R0, -1
MOV R1, 1
ADD R0, R1
HALT
```

code_size = 32 (`20 00 00 00`):

```
03 00 FF 02 FF FF FF FF    ; MOV_RI R0, -1   → R0 = 0xFFFF…FF
03 01 FF 02 01 00 00 00    ; MOV_RI R1, 1
04 00 01 01 00 00 00 00    ; ADD_RR R0, R1   → 0xFFFF…FF + 1 = 0
01 FF FF 00 00 00 00 00    ; HALT
```

- Registers: `R0 = 0`, `R1 = 1`.
- Flags: `Z = 1` (result zero), `C = 1` (carry out), `N = 0`, `V = 0`
  → `FLAGS = 3`.
- Output: none. Exit code: `0`.

### V4 — SUB with borrow and negative flags

```asm
MOV R0, 10
MOV R1, 20
SUB R0, R1
HALT
```

code_size = 32 (`20 00 00 00`):

```
03 00 FF 02 0A 00 00 00    ; MOV_RI R0, 10
03 01 FF 02 14 00 00 00    ; MOV_RI R1, 20
06 00 01 01 00 00 00 00    ; SUB_RR R0, R1   → 10 − 20 = −10
01 FF FF 00 00 00 00 00    ; HALT
```

- Registers: `R0 = 0xFFFFFFFFFFFFFFF6` (−10), `R1 = 20`.
- Flags: `Z = 0`, `C = 1` (borrow: 10 < 20), `N = 1`, `V = 0`
  → `FLAGS = 6`.
- Output: none. Exit code: `246` (`0xF6`).

### V5 — CMP + conditional jump (taken)

```asm
    MOV R0, 5
    MOV R1, 5
    CMP R0, R1
    JE equal
    MOV R2, 0
    HALT
equal:
    MOV R2, 1
    HALT
```

code_size = 64 (`40 00 00 00`):

```
03 00 FF 02 05 00 00 00    ; 0x00  MOV_RI R0, 5
03 01 FF 02 05 00 00 00    ; 0x08  MOV_RI R1, 5
15 00 01 01 00 00 00 00    ; 0x10  CMP_RR R0, R1   → Z=1
22 FF FF 05 30 00 00 00    ; 0x18  JE 0x30
03 02 FF 02 00 00 00 00    ; 0x20  MOV_RI R2, 0    (skipped)
01 FF FF 00 00 00 00 00    ; 0x28  HALT           (skipped)
03 02 FF 02 01 00 00 00    ; 0x30  equal: MOV_RI R2, 1
01 FF FF 00 00 00 00 00    ; 0x38  HALT
```

- PC trace: `0x00 → 0x08 → 0x10 → 0x18 → 0x30 → 0x38` (halt).
- Registers: `R0 = 5`, `R1 = 5`, `R2 = 1`.
- Flags: `Z = 1` (set by CMP; MOV/JE/HALT preserve flags) → `FLAGS = 1`.
- Output: none. Exit code: `5`.

### V6 — PUSH/POP (LIFO + stack residue)

```asm
MOV R0, 42
PUSH R0
MOV R0, 0
POP R1
HALT
```

code_size = 40 (`28 00 00 00`):

```
03 00 FF 02 2A 00 00 00    ; MOV_RI R0, 42
1D FF 00 03 00 00 00 00    ; PUSH_R R0        → SP = 0xFFF8
03 00 FF 02 00 00 00 00    ; MOV_RI R0, 0
1E 01 FF 03 00 00 00 00    ; POP_R R1         → SP = 0x10000
01 FF FF 00 00 00 00 00    ; HALT
```

- Registers: `R0 = 0`, `R1 = 42`.
- Stack: `SP = 0x10000`, `FP = 0x10000` (fully unwound).
- Memory: `MEM[0xFFF8..0x10000)` = `2A 00 00 00 00 00 00 00`
  (POP restores SP but does not erase the slot — specified residue).
- Output: none. Exit code: `0`.

### V7 — CALL/RET (frame layout)

```asm
    CALL func
    HALT
func:
    MOV R0, 7
    RET
```

code_size = 32 (`20 00 00 00`):

```
1F FF FF 05 10 00 00 00    ; 0x00  CALL 0x10
01 FF FF 00 00 00 00 00    ; 0x08  HALT
03 00 FF 02 07 00 00 00    ; 0x10  func: MOV_RI R0, 7
20 FF FF 00 00 00 00 00    ; 0x18  RET
```

- After CALL: `SP = 0xFFF0`, `FP = 0xFFF0`, `PC = 0x10`.
- After RET: `SP = 0x10000`, `FP = 0x10000`, `PC = 0x08` → HALT.
- Registers: `R0 = 7`.
- Stack residue: `MEM[0xFFF0..0xFFF8)` =
  `00 00 01 00 00 00 00 00` (saved FP = 0x10000),
  `MEM[0xFFF8..0x10000)` = `08 00 00 00 00 00 00 00`
  (return address 8).
- Output: none. Exit code: `7`.

### V8 — LOAD/STORE (absolute + indirect)

```asm
MOV R0, 0x1000
MOV R1, 0x5A5A
STORE [R0], R1
MOV R2, 0
LOAD R2, [0x1000]
HALT
```

code_size = 48 (`30 00 00 00`):

```
03 00 FF 02 00 10 00 00    ; MOV_RI R0, 0x1000
03 01 FF 02 5A 5A 00 00    ; MOV_RI R1, 0x5A5A
1A 00 01 01 00 00 00 00    ; STORE_R [R0], R1
03 02 FF 02 00 00 00 00    ; MOV_RI R2, 0
17 02 FF 04 00 10 00 00    ; LOAD_M R2, [0x1000]
01 FF FF 00 00 00 00 00    ; HALT
```

- Registers: `R0 = 0x1000`, `R1 = 0x5A5A`, `R2 = 0x5A5A`.
- Memory: `MEM[0x1000..0x1008)` = `5A 5A 00 00 00 00 00 00`
  (little-endian).
- Output: none. Exit code: `0`.

### V9 — HALT (normal termination category)

```asm
MOV R0, 200
HALT
```

code_size = 16 (`10 00 00 00`):

```
03 00 FF 02 C8 00 00 00    ; MOV_RI R0, 200
01 FF FF 00 00 00 00 00    ; HALT
```

- Registers: `R0 = 200`.
- Output: none. Exit code: `200`.
- This vector pins the **normal-termination** category: exit `200`,
  no stderr error, no `100 + id` code. Contrast with any fatal-error
  test, which must exit `≥ 100` with `aurora: error: <NAME>` on stderr
  (§6.1.1).
