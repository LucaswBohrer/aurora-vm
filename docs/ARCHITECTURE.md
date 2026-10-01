# AURORA VM — Architecture Proposal

**Status:** APPROVED — implementation in progress (phase 1 complete: CLI
skeleton + error reporting; see Status table in README.md)
**Date:** 2026-10-01
**Author:** Muse (senior systems engineer role)

This document is the output of phase 1 of the development process required by
the challenge specification: analyze requirements, identify ambiguities, propose
the architecture, and define the ISA, bytecode format, memory layout, execution
model, error model and test strategy — *before* writing implementation code.

---

## 1. Specification analysis

### 1.1 What is clear and uncontroversial

- 16× 64-bit GPRs (R0–R15), plus PC, SP, FP, FLAGS.
- 64 KiB byte-addressable virtual memory with bounds checking.
- Dedicated stack with PUSH/POP/CALL/RET and working recursion.
- A documented custom ISA covering data movement, arithmetic, logic, compare,
  control flow, functions, system and I/O instructions.
- A real assembler (labels, symbolic jumps, immediates, hex/decimal, data
  declarations, useful diagnostics).
- A validating bytecode loader.
- The fetch→decode→execute loop in x86-64 Assembly (NASM, ELF64, Linux
  syscalls only — no libc).
- An interactive debugger (run/step/continue/registers/memory/stack/
  break/quit).
- 7 sample programs, an automated test suite, full documentation.

### 1.2 Ambiguities found, with proposed resolutions

| # | Ambiguity | Resolution (proposed) |
|---|-----------|------------------------|
| A1 | §1 lists "program counter" *and* "instruction pointer" as separate items | They are the same register. Single `PC` (byte offset into the code segment). Documented once. |
| A2 | I/O semantics (`IN`/`OUT`) are unspecified | `OUT Rs`: print Rs as **signed decimal** + newline. `OUTC Rs`: write low byte of Rs as an **ASCII character**. `IN Rd`: read one byte from stdin into Rd (zero-extended); on EOF, Rd = `0xFFFFFFFFFFFFFFFF` (-1). Rationale: decimal output makes arithmetic programs testable; char output makes Hello World possible; both are trivially implementable with raw syscalls. |
| A3 | `DIV` signedness; `INT64_MIN / -1` | **Signed** division (x86 `idiv` semantics). Division by zero → `DIVISION_BY_ZERO` fatal error. `INT64_MIN / -1` → result `0x8000000000000000`, `OVERFLOW=1` (no trap; documented). |
| A4 | Are code bytes writable at runtime? | **No.** The code segment is read-only; a store into it raises `WRITE_TO_CODE`. This catches wild-pointer bugs instead of silently corrupting the program. |
| A5 | Instruction width: fixed or variable? | **Fixed 8-byte** instructions. Rationale in §2.2. |
| A6 | `CMP`/conditional jumps: signed or unsigned? | `CMP` sets flags for **signed** interpretation; `JG/JL/JGE/JLE` are signed (x86 semantics). Unsigned variants are a documented future extension, not v1. |
| A7 | May the assembler be written in another language? (§18 allows tooling in another language if separated) | **Yes: Python 3, stdlib only**, in `tools/`. Rationale in §2.1. The VM, loader and debugger remain 100% Assembly. |
| A8 | Memory-access alignment | **Unaligned 64-bit accesses are allowed** (x86-64 handles them); only the *bounds* are checked. Simpler, still safe. |
| A9 | Jump encoding: relative or absolute? | **Absolute byte offsets** from the code-segment base. Simpler to validate statically (loader checks every target). |
| A10 | Infinite-loop protection | Implemented as `--max-steps N` (default 100,000,000; `0` = unlimited). Exceeding it raises `MAX_STEPS_EXCEEDED`. Deterministic and testable. |
| A11 | Process exit code on `HALT` | `HALT` exits with code `R0 & 0xFF`. Lets tests assert computed values through the exit code in addition to stdout. |
| A12 | The "stack" vs the 64 KiB address space | The stack is a **reserved region of the same 64 KiB** (`0xF000–0xFFFF`, 4 KiB, growing down), not a separate memory. This keeps one coherent memory model and lets the debugger inspect the stack via the memory view. |

If any resolution above is rejected, it is a small, localized change — the
rest of the architecture does not depend on these choices.

---

## 2. Architecture decisions

### 2.1 Language split: Assembly core, Python tooling

```
src/*.asm          →  single static binary `aurora` (no libc, raw syscalls)
                        - virtual CPU execution loop
                        - bytecode loader + validator
                        - interactive debugger
tools/aurora-asm   →  assembler (Python 3, stdlib only)
```

The challenge (§18) forbids delegating the *CPU execution loop* to another
language — it does not forbid build-time tooling. Writing the assembler in
Assembly would roughly double the bug surface (two-pass symbol tables, string
parsing, diagnostics) for zero runtime benefit. The split is strict and
visible in the directory layout: `src/` is Assembly, `tools/` is Python, and
the Python code never executes guest instructions.

**DECIDED (D20):** the assembler stays in Python 3, stdlib only, in
`tools/`. It is not part of the VM runtime. This closes open question 1.

### 2.2 Fixed-width 8-byte instruction encoding

```
+--------+--------+--------+--------+------------------+
| opcode |   dst  |   src  |  class |  imm32 (LE)      |   = 8 bytes
|  u8    |   u8   |   u8   |   u8   |  u32             |
+--------+--------+--------+--------+------------------+
```

- `dst`/`src`: 0–15 = register, `0xFF` = unused. Any other value is
  `INVALID_REGISTER`.
- `class` is informational/redundant (see §2.3); the assembler always emits
  the correct class byte, the VM ignores it for dispatch (dispatch is purely
  on `opcode`).
- `imm32`: sign-extended to 64 bits when used as an integer immediate;
  interpreted as an unsigned byte offset when used as a code address or
  memory address.

**Why fixed width:** fetch/decode become trivially correct (no instruction-
boundary bugs, no desync after a bad jump — every PC is validated 8-aligned),
the loader can statically validate the whole program, and the debugger's
disassembler is simple. Cost: code density. At 64 KiB of address space this
cost is irrelevant; correctness is the priority.

### 2.3 Opcode-per-variant (no mode bits)

Instead of overloading a few opcodes with mode bits, each operand shape gets
its own opcode (43 total, frozen — see §2.3a). The *assembly language* still exposes the clean
mnemonics from the spec (`MOV`, `ADD`, …); the assembler selects the opcode
from the operand shapes. Example:

| Assembly | Encoding |
|---|---|
| `MOV R0, R1` | `MOV_RR (0x02)` |
| `MOV R0, 10` | `MOV_RI (0x03)` |
| `MOV R0, label` | `MOV_RI (0x03)` with imm32 = resolved address |

This removes all decode-time ambiguity: one opcode byte ⇒ one fixed operand
layout ⇒ one jump-table entry.

### 2.3a ISA freeze (❄️ normative)

`docs/ISA.md` is the **normative source** of the ISA, frozen at exactly
**43 opcodes** (`0x00`–`0x2A`) — count, numeric values, formats, operands,
semantics, affected flags and possible errors. `docs/BYTECODE.md`
(container format v1) is frozen with it.

**Change protocol (normative, D14):** if an ISA/bytecode change becomes
necessary during implementation: (1) stop implementing the affected part;
(2) document the problem; (3) update the specification; (4) record the
decision in `docs/DECISIONS.md`; (5) only then continue. No silent
creation, removal or alteration of any instruction — ever.

All architectural decisions live in `docs/DECISIONS.md` (D01–D20).

### 2.4 Virtual CPU state

Kept in a single state struct in BSS (explicit, auditable — no hidden
register allocation tricks):

```nasm
vm_regs:    resq 16        ; R0-R15
vm_pc:      resq 1         ; byte offset, 8-aligned, within code segment
vm_sp:      resq 1         ; init 0x10000 (empty-stack sentinel)
vm_fp:      resq 1         ; init 0x10000
vm_flags:   resq 1         ; bit0=ZERO bit1=CARRY bit2=NEGATIVE bit3=OVERFLOW
vm_mem:     resb 65536     ; the entire 64 KiB
```

Hot-loop performance is a non-goal; clarity and verifiability are the goals.

### 2.5 Flags model (x86-inspired, precisely defined)

For operands `a`, `b` (u64) and result `r` (u64, mod 2⁶⁴):

- **ADD** `r=a+b`: `C = (r < a)` (carry out); `V = ((a^r)&(b^r))>>63`
  (signed overflow); `Z = (r==0)`; `N = r>>63`.
- **SUB/CMP** `r=a-b`: `C = (a < b)` (borrow; x86 CF convention);
  `V = ((a^b)&(a^r))>>63`; `Z`, `N` as above.
- **MUL** unsigned 128-bit product `p=a*b`, `r=low(p)`:
  `C = V = (high(p) != 0)`; `Z`, `N` from `r`.
- **DIV** signed: `C=0`; `V=1` only for `INT64_MIN / -1`; `Z`, `N` from `r`.
- **INC**: `r=a+1`; **C unchanged**; `V=(a==0x7FFF…F)`; `Z`,`N` from `r`.
- **DEC**: `r=a-1`; **C unchanged**; `V=(a==0x8000…0)`; `Z`,`N` from `r`.
- **AND/OR/XOR**: `Z`,`N` from `r`; `C=0`; `V=0`.
- **NOT**: flags **unchanged** (x86 convention).
- **MOV/LOAD/STORE/PUSH/POP/JMP*/CALL/RET/NOP/HALT/IN/OUT/OUTC**: flags
  unchanged.

Conditional jumps (signed): `JE: Z=1`; `JNE: Z=0`; `JG: Z=0 ∧ N=V`;
`JL: N≠V`; `JGE: N=V`; `JLE: Z=1 ∨ N≠V`.

### 2.6 I/O model

- `OUT Rs` — write `Rs` as signed decimal ASCII + `\n` to stdout.
- `OUTC Rs` — write low byte of `Rs` to stdout.
- `IN Rd` — blocking read of 1 byte from stdin; `Rd` = zero-extended byte,
  or `0xFFFF…F` on EOF.
- Only syscalls used: `read`, `write`. No buffering inside the VM (each
  `OUT`/`OUTC` is one syscall) — simple and deterministic.

### 2.7 Memory map (64 KiB)

```
0x0000 ──────────────────────────────
  CODE      code_size bytes     [read-only, execute]
  DATA      data_size bytes     [read-write]
  ...free...
0xF000 ──────────────────────────────
  STACK     0xF000–0xFFFF       [read-write, grows down]
0x10000 ─────────────────────────────
```

- Loader rejects programs where `code_size + data_size > 0xF000`
  (`INVALID_MEMORY_LAYOUT`).
- `SP` init `0x10000`; `PUSH`: `if SP-8 < 0xF000 → STACK_OVERFLOW`;
  `SP -= 8; mem64[SP] = value`.
- `POP`: `if SP >= 0x10000 → STACK_UNDERFLOW`; `value = mem64[SP]; SP += 8`.
- Every load/store checks `addr ≤ 0x10000 − size` (wraparound-safe;
  `INVALID_MEMORY_ACCESS`) and rejects writes into `[0, code_size)`
  (`WRITE_TO_CODE`).

### 2.8 Calling convention (uniform frames)

```
CALL target:
    push(PC_next)        ; return address
    push(FP)             ; save caller frame
    FP = SP
    PC = target
RET:
    SP = FP              ; drop frame locals
    FP = pop()
    PC = pop()
```

Every call creates a frame — uniform, debuggable (the debugger can walk
`FP` chains for a backtrace), and recursion works naturally. The 4 KiB
stack holds 512 qwords = 256 nested frames worst-case; deep `fib` tests
stay far below that.

### 2.9 Bytecode file format

```
offset  size  field
0x00    8     magic  41 55 52 4F 52 41 01 00  ("AURORA" + 0x01,0x00)
0x08    2     version = 0x0001 (LE)
0x0A    4     code_size   (LE u32, >0, multiple of 8)
0x0E    4     entry       (LE u32, < code_size, 8-aligned)
0x12    4     data_size   (LE u32)
0x16    4     reserved    (must be 0)
0x1A    …     code  (code_size bytes)
…       …     data  (data_size bytes; loaded at address code_size)
```

Total file size must equal `0x1A + code_size + data_size` exactly.

Loader validation (all *before* first fetch):
1. magic, version, reserved, exact file size;
2. `code_size + data_size ≤ 0xF000`, entry valid;
3. **full decode scan**: every 8-byte slot has a known opcode, valid
   register fields, and every `J*`/`CALL` target is `< code_size` and
   8-aligned.

A program that passes the loader cannot fail with `INVALID_OPCODE`,
`INVALID_REGISTER` or `INVALID_PC` at runtime (defense in depth: the
execution loop still checks).

### 2.10 Error model

Fatal errors print `aurora: error: <NAME>: <detail>` to stderr and exit
with code `100 + id`:

| id | Name | Trigger |
|----|------|---------|
| 1 | `INVALID_OPCODE` | unknown opcode byte (defense-in-depth; loader catches first) |
| 2 | `INVALID_REGISTER` | register field not in 0–15/`0xFF` |
| 3 | `INVALID_MEMORY_ACCESS` | read/write outside `0x0000–0xFFFF` |
| 4 | `STACK_OVERFLOW` | `SP-8 < 0xF000` |
| 5 | `STACK_UNDERFLOW` | pop from empty stack |
| 6 | `DIVISION_BY_ZERO` | `DIV` with divisor 0 |
| 7 | `INVALID_PC` | PC outside code segment or misaligned |
| 8 | `INVALID_PROGRAM` | bad magic/version/size/layout (loader) |
| 9 | `INVALID_INSTRUCTION` | loader decode scan failure (bad regs/targets) |
| 10 | `MAX_STEPS_EXCEEDED` | step limit reached |
| 11 | `WRITE_TO_CODE` | store into the code segment |
| 12 | `IO_ERROR` | syscall failure on stdin/stdout |

The VM **never** continues after a fatal error. There are no warnings —
anything malformed is rejected.

**HALT ≠ fatal error (normative).** Every execution ends with a
`termination_class` of `NORMAL` or `FATAL`, decided by the VM's internal
`termination_reason` — not by the exit code alone. `HALT` terminates
normally: `termination_reason = HALT`, exit code `R0 & 0xFF` (0–255).
Fatal errors terminate fatally: `termination_reason = <error name>`,
exit code `100 + id` (101–112), with `aurora: error: <NAME>[: <detail>]`
on stderr. Because `HALT` can exit with any value in 0–255, the numeric
ranges overlap (`HALT` with `R0 = 106` and `DIVISION_BY_ZERO` both exit
`106`); the debugger reports them with different status lines
(`halted (exit code N)` vs `fatal error: <NAME>`). Full formalization in
`ISA.md` §6.1.1; decision record D22.

### 2.11 CLI

```
aurora run   prog.bin [--max-steps N]   ; execute (default N=100000000, 0=unlimited)
aurora debug prog.bin                   ; interactive debugger
aurora --help | --version
```

### 2.12 Determinism

Same bytecode + same stdin ⇒ same stdout, same exit code, always. The only
external input is `IN` (stdin). No RNG, no clocks, no ASLR dependence (all
addresses are virtual). Documented in `docs/`.

---

## 3. ISA summary (encoding-level opcodes)

| Opcode | Mnemonic | Class | Operands | Semantics |
|--------|----------|-------|----------|-----------|
| 0x00 | NOP | — | — | no operation |
| 0x01 | HALT | — | — | stop; exit code = `R0 & 0xFF` |
| 0x02 | MOV | R | `Rd, Rs` | `Rd = Rs` |
| 0x03 | MOV | I | `Rd, imm32` | `Rd = sign_extend(imm32)` |
| 0x04 | ADD | R | `Rd, Rs` | `Rd += Rs`; flags |
| 0x05 | ADD | I | `Rd, imm32` | `Rd += sext(imm32)`; flags |
| 0x06 | SUB | R/I | … | `Rd -= …`; flags |
| 0x07 | SUB | I | | |
| 0x08 | MUL | R | | `Rd *= Rs` (unsigned); flags |
| 0x09 | MUL | I | | |
| 0x0A | DIV | R | | `Rd = sdiv(Rd, Rs)`; div-by-zero → error |
| 0x0B | DIV | I | | |
| 0x0C | INC | r | `Rd` | `Rd++`; C preserved |
| 0x0D | DEC | r | `Rd` | `Rd--`; C preserved |
| 0x0E | AND | R | | `Rd &= Rs`; Z,N; C=V=0 |
| 0x0F | AND | I | | |
| 0x10 | OR | R | | |
| 0x11 | OR | I | | |
| 0x12 | XOR | R | | |
| 0x13 | XOR | I | | |
| 0x14 | NOT | r | `Rd` | `Rd = ~Rd`; flags unchanged |
| 0x15 | CMP | R | `Ra, Rb` | flags = `Ra - Rb`; result discarded |
| 0x16 | CMP | I | `Ra, imm32` | |
| 0x17 | LOAD | M | `Rd, [a32]` | `Rd = mem64[a32]` |
| 0x18 | LOAD | R | `Rd, [Rs]` | `Rd = mem64[Rs]` |
| 0x19 | STORE | M | `[a32], Rs` | `mem64[a32] = Rs` |
| 0x1A | STORE | R | `[Rd], Rs` | `mem64[Rd] = Rs` |
| 0x1B | LOADB | R | `Rd, [Rs]` | `Rd = zero_extend(mem8[Rs])` |
| 0x1C | STOREB | R | `[Rd], Rs` | `mem8[Rd] = Rs[7:0]` |
| 0x1D | PUSH | r | `Rs` | push Rs |
| 0x1E | POP | r | `Rd` | `Rd = pop()` |
| 0x1F | CALL | J | `a32` | frame + `PC = a32` |
| 0x20 | RET | — | — | restore frame, `PC = pop()` |
| 0x21 | JMP | J | `a32` | `PC = a32` |
| 0x22 | JE | J | `a32` | `if Z: PC = a32` |
| 0x23 | JNE | J | | `if !Z` |
| 0x24 | JG | J | | `if !Z && N==V` |
| 0x25 | JL | J | | `if N!=V` |
| 0x26 | JGE | J | | `if N==V` |
| 0x27 | JLE | J | | `if Z \|\| N!=V` |
| 0x28 | OUT | r | `Rs` | print signed decimal + `\n` |
| 0x29 | OUTC | r | `Rs` | print low byte as char |
| 0x2A | IN | r | `Rd` | `Rd` = stdin byte, `-1` on EOF |

Classes: `R` = dst+src regs · `I` = dst reg + imm32 · `r` = single reg ·
`M` = absolute address + reg · `J` = absolute code address · `—` = none.

Notes:
- `LOADB`/`STOREB` exist so C-style strings work (Hello World); they are the
  only sub-word memory operations.
- `MOV Rd, label` assembles to `MOV/I` with imm32 = label address
  (addresses always fit in 32 bits).

---

## 4. Execution model

```
load & validate (loader)
PC = entry; SP = FP = 0x10000; FLAGS = 0; R0-R15 = 0
steps = 0
loop:
    if steps++ >= max_steps: die(MAX_STEPS_EXCEEDED)
    if PC >= code_size or PC % 8 != 0: die(INVALID_PC)
    fetch 8 bytes at code_base + PC
    decode opcode → jump table[256]  (unknown → INVALID_OPCODE)
    execute handler:
        - may read/write regs, memory (checked), stack (checked)
        - may update FLAGS per §2.5
        - sets PC = next (PC+8) or a jump target
    (breakpoints checked first in debug mode)
on HALT: exit(R0 & 0xFF)
on fatal error: stderr message + exit(100 + id)
```

The debugger reuses the same loop with a pre-fetch hook: check breakpoints,
then either stop for user input or single-step.

---

## 5. Assembler design (`tools/aurora-asm`, Python 3 stdlib)

- **Two passes.** Pass 1: collect labels (`name:` → instruction offset for
  code labels; data labels → address in the data segment). Pass 2: emit.
- **Syntax:** `;` comments · labels `name:` · registers `R0`–`R15`
  (case-insensitive) · immediates: decimal, `0x` hex, `0b` binary, negatives ·
  memory: `[0x1234]`, `[R3]` · data: `label: DB "str", 0, 0xFF` /
  `DW` / `DD` / `DQ`.
- **Diagnostics** with file:line: unknown instruction, invalid register,
  invalid operand shape, undefined label, duplicate label, invalid literal,
  malformed syntax, jump to a data label (code/data mixup).
- Output: the bytecode file format from §2.9. Exit 0 on success, 1 with a
  `file:line: error:` message on failure.

---

## 6. Debugger design (Assembly, `aurora debug`)

REPL reading lines from stdin; commands:

```
run | step [n] | continue | break <addr> | registers | flags
memory <addr> [count] | stack [n] | disasm | backtrace | help | quit
```

- Shows PC/SP/FP, all registers as 16-digit hex, flags as `Z C N V`,
  current instruction disassembled (`0x0010: ADD R0, R1`).
- 16 breakpoint slots; checked before each fetch in debug mode.
- `backtrace` walks the FP chain (possible thanks to uniform frames, §2.8).
- The debugger shares the CPU loop — it is not a second implementation.

## 6b. Runtime ABI design (guest-side library, `runtime/aurora_rt.asm`)

Phase 6 adds an ABI/services layer without touching the frozen ISA (D26).
The ABI is a **calling convention over existing instructions**: services
are ordinary AURORA functions in `runtime/aurora_rt.asm`, identified by
the entry point `CALL`ed — `svc_exit` (terminate via `HALT`), `svc_write`
(structured stdout via `OUTC` + `LOADB`), `svc_read` (structured stdin
via `IN` + `STOREB`). Arguments in R0–R2, return value in R0 (`-1` =
recoverable error: bad fd, bad bounds — wraparound-safe
`buf > 0x10000 − len` check per ISA §5); R3–R15/SP/FP preserved, R1/R2
and FLAGS clobbered. Linking is static by concatenation (guest FIRST so
entry 0 is guest code; `svc_`-prefixed labels reserved). One CPU, one
register file, one memory — services execute through `cpu_step()` like
any guest code; fatal errors inside a service propagate as the ISA's own
`IO_ERROR`/`WRITE_TO_CODE`. Deterministic: no clock, no random
(`docs/RUNTIME.md` is the normative ABI reference).

---

## 7. Project structure

```
aurora-vm/
├── src/
│   ├── main.asm        ; CLI dispatch (run/debug/help/version)
│   ├── loader.asm      ; file load + full validation (§2.9)
│   ├── cpu.asm         ; fetch/decode/execute loop + jump table
│   ├── handlers.asm    ; one handler per opcode (43)
│   ├── flags.asm       ; flag computation helpers
│   ├── memory.asm      ; bounds-checked load/store
│   ├── stack.asm       ; push/pop/call/ret primitives
│   ├── io.asm          ; OUT/OUTC/IN, itoa, syscall wrappers
│   ├── debugger.asm    ; REPL, breakpoints, disassembler, backtrace
│   ├── errors.asm      ; error table + die()
│   └── util.asm        ; string/hex/parse helpers
├── tools/
│   └── aurora-asm      ; assembler (Python 3, stdlib only, executable)
├── runtime/
│   └── aurora_rt.asm   ; ABI v1 guest-side library (svc_exit/svc_write/svc_read)
├── programs/           ; 7 sample programs (.asm)
├── examples/
│   └── runtime/        ; hello/io/echo/exit via the runtime ABI (.asm)
├── tests/
│   ├── run_tests.sh    ; runner
│   ├── cpu/  mem/  stack/  asm/  byte/  vm/   ; fixtures + expectations
│   ├── runtime/        ; L8 ABI tests + frozen golden .bin fixtures
│   └── helpers.sh
├── docs/
│   ├── ARCHITECTURE.md ; this file (evolves into the decision record)
│   ├── ISA.md          ; full ISA reference (from §3 + §2.5)
│   ├── BYTECODE.md     ; file format + loader validation rules
│   ├── ASSEMBLER.md    ; syntax + directives + diagnostics
│   ├── DEBUGGER.md     ; commands + examples
│   ├── RUNTIME.md      ; runtime ABI v1 contract (normative, phase 6)
│   ├── MEMORY.md       ; memory & stack model
│   ├── ERRORS.md       ; error model + exit codes
│   └── BUILD_TEST.md   ; build/run/test/clean instructions
├── Makefile            ; build | test | clean  (needs: nasm, ld, python3)
└── README.md           ; overview + quickstart
```

---

## 8. Build / test plan

- **Build:** `nasm -f elf64` each `src/*.asm` → `ld` → `build/aurora`.
  Dependencies: `nasm`, `binutils (ld)`, `python3`. Documented `apt` line.
- **Tests:** the full strategy lives in `docs/TESTING.md` (normative) and
  is summarized here:
  - **L1 golden vectors** (`ISA.md` §12): 9 hand-computed vectors with
    exact expected bytes, registers, flags, memory, stack, output and
    exit codes. Hand-written `.bin` fixtures + scripted debugger
    sessions — the VM is validated **without the assembler**, so the two
    cannot share a bug undetected.
  - **L2 assembler tests:** valid programs round-trip; invalid programs
    assert exact `file:line: error:` diagnostics per category.
  - **L3 bytecode rejection:** 20 malformed-file cases → precise
    `INVALID_PROGRAM` / `INVALID_INSTRUCTION` errors and exit codes.
  - **L4 execution:** 7 sample programs with expected stdout; torture
    tests (arithmetic/memory/stack/bytecode/execution edge cases, each
    with an expected outcome); stress program `fib30` — **recursive**
    Fibonacci(30) = `832040`, exit 40, ~40–60M guest steps (validates the
    100M default `--max-steps`).
  - **L5 fuzzing** (`make fuzz`, `tests/fuzz.py`): mutational fuzzing of
    headers, versions, opcodes, operands, class bytes, immediates,
    entry points, sizes and truncations. Oracle: no signal death, no
    hang past `--max-steps`, and the `(exit code, stderr)` pair must be
    consistent with the termination class — a fatal error exits
    `100 + id` *and* names the error on stderr; a `HALT` (any exit code
    0–255) never prints `aurora: error:`. Exit code alone is not a
    classifier (see D22).
  - **L6 determinism:** every program and vector runs twice;
    byte-identical results required. Only stdin (`IN`) is a legitimate
    nondeterminism source.
  - **L7 debugger:** scripted REPL sessions asserting output formats,
    stepping, breakpoints, memory/stack dumps, backtraces, and the
    halted-vs-fatal-error distinction.
  - **L8 runtime ABI** (`tests/runtime/`, 38 checks): the §6b contract —
    argument/return conventions, R3–R15/SP/FP preservation, `svc_exit`
    (0/42/106-normal per D22), `svc_write`/`svc_read` (valid, zero-length,
    boundary, invalid, overflow, EOF), memory safety (no unrelated
    corruption), debugger sessions over service calls, determinism,
    `IO_ERROR` propagation through services, and frozen golden `.bin`
    fixtures plus one fully hand-encoded program (assembler-independent).
- Every test asserts **observable behavior** (stdout bytes + exit code +
  debugger-visible state), never implementation internals.

---

## 9. Implementation phases (after approval)

1. `errors.asm`, `util.asm`, `io.asm` + `main.asm` skeleton → a binary that
   parses CLI and dies cleanly.
2. `loader.asm` → loads & validates; `run` reaches "first fetch".
3. `cpu.asm` + `handlers.asm` (data movement + HALT) → first program runs.
4. Arithmetic/logic/flags (`flags.asm`) → `tests/cpu` green.
5. Memory + stack + CALL/RET → `tests/mem`, `tests/stack` green.
6. `tools/aurora-asm` → round-trip: asm → bin → run.
7. `debugger.asm` → interactive session works; scripted debugger test.
8. 7 sample programs, full `tests/`, all docs, `make test` green,
   end-to-end validation, final report.

Each phase ends with build + test + fix before the next begins. Nothing is
declared working without observed evidence.

---

## 10. Open questions — ALL CLOSED (specification revision, 2026-10-01)

1. **Assembler in Python** → **CLOSED: yes, Python** (D20). Stays in
   `tools/`, stdlib only, not part of the VM runtime.
2. **Unsigned jumps `JA`/`JB`** → **CLOSED: not in v1** (D18). The 7
   signed jumps are frozen; unsigned behavior is synthesized from
   existing instructions. A v2 may reconsider — out of scope.
3. **Ambiguity resolutions (§1.2)** → **accepted as specified**, with the
   12-item revision applied on top (frozen ISA/bytecode, golden vectors,
   fuzzing, normative determinism, HALT-vs-fatal, fib30 stress, torture
   tests, ambiguity protocol).

## 10a. Ambiguity protocol during implementation (normative, D19)

Architectural ambiguities discovered during implementation are **not**
resolved silently. If a decision touches the ISA, bytecode, memory,
calling convention, flags, instruction semantics, error behavior or file
formats:

1. stop implementing the affected part;
2. record the question (in `docs/DECISIONS.md` as pending);
3. update the specification first;
4. only then continue implementation.

The specification leads; the implementation follows.
