# AURORA VM — Test Strategy

**Status:** SPECIFICATION — the test suite must implement this plan.
Companion: `ISA.md` §12 (golden vectors), `ARCHITECTURE.md` §8.

Every test asserts **observable behavior**: stdout bytes, exit code,
and — via scripted debugger sessions — registers, flags, memory and
stack contents. No test depends on implementation internals.

---

## 1. Test layers

```
L1  Golden vectors      hand-written .bin fixtures, normative (ISA.md §12)
L2  Assembler tests     valid programs + exact diagnostics for invalid ones
L3  Bytecode rejection  corrupted/truncated/malformed files → precise errors
L4  Execution tests     sample programs, torture tests, stress program
L5  Fuzzing             mutational bytecode fuzzing, safety oracle
L6  Determinism         repeated runs, byte-identical results
L7  Debugger            scripted REPL sessions
```

`make test` runs L1–L4, L6, L7. `make fuzz` runs L5 (bounded iterations).

---

## 2. L1 — Golden vectors (normative)

**Problem addressed:** testing only through `assembler → bytecode → VM`
lets the assembler and the VM share the same bug.

**Method:**

1. `tests/golden/vNN.bin` are **hand-written byte fixtures** — the exact
   bytes from `ISA.md` §12, committed as binary files. They are produced
   by a small Python script containing the hex literals copied from the
   spec (`tests/golden/make_fixtures.py`), **not** by `tools/aurora-asm`.
2. An independent checker (`tests/golden/check_bytes.py`) re-parses each
   `.bin` and asserts the header fields and instruction stream match the
   spec text, catching transcription errors between doc and fixture.
3. Execution assertions run the fixture two ways:
   - `aurora run vNN.bin` → assert stdout bytes + exit code;
   - scripted debugger session → assert registers, flags, stack and
     memory:

```
printf 'registers\nflags\nstack 4\nmemory 0xFFF0 16\nquit\n' \
  | aurora debug vNN.bin > session.txt
```

   The debugger output format is specified in `docs/DEBUGGER.md` with
   fixed field layouts so the harness can parse it deterministically.

4. Vectors V1–V9 cover: MOV reg/reg, MOV immediate (incl. negative),
   ADD with carry/zero flags, SUB with borrow/negative flags, CMP +
   conditional jump, PUSH/POP with stack-memory residue, CALL/RET with
   frame layout, LOAD/STORE (absolute + indirect), HALT exit code.

A vector fails if **any** of bytes / registers / flags / memory / stack /
output / exit code differs from `ISA.md` §12.

---

## 3. L2 — Assembler tests

- `tests/asm/valid/*.asm` → assembles with exit 0; output re-validated by
  the loader (round-trip: `aurora-asm` → `aurora run`).
- Byte-equality: for selected programs, assembler output must equal the
  hand-written golden bytes (catches encoder drift against §12).
- `tests/asm/invalid/*.asm` → exit 1, stderr matches
  `file:line: error: <category>` for each category: unknown instruction,
  invalid register, invalid operand shape, undefined label, duplicate
  label, invalid numeric literal, malformed syntax, jump to data label,
  `DB` with bad operand.

---

## 4. L3 — Bytecode rejection tests

Python-generated malformed files (`tests/byte/gen.py`), each asserting a
specific fatal error name and exit code:

| Case | Expected |
|------|----------|
| bad magic (1 byte flipped) | `INVALID_PROGRAM` (108), "bad magic" |
| version `0x0002` | `INVALID_PROGRAM` (108), "unsupported version" |
| reserved field nonzero | `INVALID_PROGRAM` (108) |
| truncated header (10 bytes) | `INVALID_PROGRAM` (108), "truncated" |
| truncated code (header ok, half the code) | `INVALID_PROGRAM` (108) |
| trailing garbage byte | `INVALID_PROGRAM` (108) |
| `code_size = 0` | `INVALID_PROGRAM` (108) |
| `code_size % 8 != 0` | `INVALID_PROGRAM` (108) |
| `entry >= code_size` | `INVALID_PROGRAM` (108), "entry point" |
| `entry % 8 != 0` | `INVALID_PROGRAM` (108) |
| `code_size + data_size > 0xF000` | `INVALID_PROGRAM` (108), "memory layout" |
| opcode `0xFF` in slot | `INVALID_INSTRUCTION` (109) |
| opcode `0x2B` (first reserved) | `INVALID_INSTRUCTION` (109) |
| class byte mismatch | `INVALID_INSTRUCTION` (109) |
| register field `0x10` | `INVALID_INSTRUCTION` (109) |
| nonzero imm32 on class N/R/r | `INVALID_INSTRUCTION` (109) |
| `JMP` target `>= code_size` | `INVALID_INSTRUCTION` (109) |
| `JMP` target misaligned | `INVALID_INSTRUCTION` (109) |
| `CALL` target misaligned | `INVALID_INSTRUCTION` (109) |
| `LOAD_M` address `0xFFFFFFF8` | `INVALID_INSTRUCTION` (109) |

---

## 5. L4 — Execution tests

### 5.1 Sample programs

The 7 required programs (`programs/*.asm`) with expected stdout:

| Program | Expected output |
|---------|-----------------|
| `hello.asm` | `Hello, world!\n` (via OUTC loop over `DB` string) |
| `arith.asm` | `90\n`, exit 90 |
| `cond.asm` | branch markers, e.g. `1\n2\n3\n4\n5\n` for JE/JNE/JG/JL/JGE (+JLE) taken paths |
| `fact.asm` | `3628800\n` (10!), exit `3628800 & 0xFF = 0` |
| `fib.asm` | `55\n` (fib(10) recursive), exit 55 |
| `stack.asm` | nested-call results, e.g. `6\n` |
| `mem.asm` | `1\n` (round-trip ok marker) |

### 5.2 Torture tests (`tests/torture/`)

Each: small `.asm`, expected outcome. `→` means "must produce".

**Arithmetic**
- `div_zero.asm`: `DIV R0, R1` with R1=0 → `DIVISION_BY_ZERO` (106).
- `mul_overflow.asm`: `R0=0xFFFFFFFFFFFFFFFF; R1=2; MUL R0,R1` → R0=`0xFFFFFFFFFFFFFFFE`, `C=1,V=1,Z=0,N=1`; OUT R0 → `-2\n`.
- `div_min_by_neg1.asm`: `R0=0x8000000000000000; MOV R1,-1; DIV R0,R1` → R0=`0x8000000000000000`, `V=1`; OUT → `-9223372036854775808\n`.
- `neg_imm.asm`: `MOV R0,-5; MOV R1,-10; ADD R0,R1` → R0=`0xFFFFFFFFFFFFFFF1`; OUT → `-15\n`.
- `add_max_plus1.asm`: `R0=0x7FFFFFFFFFFFFFFF; INC R0` → R0=`0x8000000000000000`, `V=1`, `C` unchanged (0); OUT → `-9223372036854775808\n`.
- `sub_borrow.asm`: `R0=0; R1=1; SUB R0,R1` → R0=`0xFFFFFFFFFFFFFFFF`, `C=1`.

**Memory**
- `mem_first_byte.asm`: `LOADB R0,[R1]` with R1=0 → ok (reads code byte, no error).
- `mem_last_byte.asm`: `LOADB R0,[R1]` with R1=`0xFFFF` → ok.
- `mem_first_invalid.asm`: `LOAD R0,[R1]` with R1=`0x10000` → `INVALID_MEMORY_ACCESS` (103).
- `mem_last_plus1.asm`: `LOADB R0,[R1]` with R1=`0x10000` → `INVALID_MEMORY_ACCESS` (103).
- `mem_crossing.asm`: `LOAD R0,[R1]` with R1=`0xFFFD` (`0xFFFD+8 > 0x10000`) → `INVALID_MEMORY_ACCESS` (103).
- `mem_write_code.asm`: `STORE [0x0000],R0` → `WRITE_TO_CODE` (111).
- `mem_high_data.asm`: store/load at `0xEFFF` (last byte before stack) → round-trip ok.

**Stack**
- `push_pop.asm`: 3 pushes, 3 pops → LIFO order verified via OUT.
- `stack_underflow.asm`: `POP R0` on empty stack → `STACK_UNDERFLOW` (105).
- `stack_overflow.asm`: 300 nested `CALL`s (or 600 `PUSH`s) → `STACK_OVERFLOW` (104).
- `call_ret.asm`: nested 3-deep calls returning values → correct unwinding.
- `fib20_rec.asm`: recursive fib(20)=6765 → `6765\n` (recursion depth 20, frames correct).
- `ret_without_call.asm`: `RET` as first instruction → `STACK_UNDERFLOW` (105) (SP=FP=0x10000, first pop fails).

**Bytecode** — covered by L3.

**Execution**
- `halt_code.asm`: `MOV R0,200; HALT` → exit 200, no output, no error.
- `max_steps.asm`: `loop: JMP loop` with `--max-steps 1000` → `MAX_STEPS_EXCEEDED` (110).
- `infinite_loop_default.asm`: same program, default limit → 110 (terminates; slow — run with a timeout guard in the harness, generous: 120 s).
- `pc_invalid_ret.asm`: hand-crafted `.bin` where a `RET` pops a bad address (e.g. `0xFFFFFFF8`) → `INVALID_PC` (107) at runtime. (Static jumps can never do this — the loader rejects them; `RET` is the dynamic path.)

### 5.3 Stress program: `fib30`

`programs/stress_fib30.asm` — **recursive** Fibonacci(30). Not iterative:
it must exercise CALL/RET/FP/SP/frames/branches/CMP/flags/memory/return
values under real load.

- Expected output: `832040\n`; exit code `832040 & 0xFF = 40`.
- Call count ≈ 2,692,537; estimated guest steps ≈ 40–60M — under the
  default `--max-steps` 100,000,000 (validates the default is sane), and
  the harness also runs it with `--max-steps 1000000` expecting (110).
- Runtime budget: a few seconds in optimized Assembly; the harness
  asserts wall time < 60 s.

---

## 6. L5 — Bytecode fuzzing (`tests/fuzz.py`, `make fuzz`)

**Goal:** malformed inputs must never crash, hang (past `--max-steps`),
or corrupt the host. Not a proof of absence of bugs — a safety bar.

**Corpus:** all `tests/golden/*.bin` + assembled sample programs.

**Mutation operators** (applied 1–4 per iteration, seeded RNG for
reproducibility):
- header: flip bytes in magic, randomize version, code_size, entry,
  data_size, reserved;
- sizes: code_size/data_size inconsistent with file length (±1..16);
- truncation: cut file at random offsets (incl. mid-instruction);
- opcode: random byte in each slot (bias toward 0x2B–0xFF and 0x00–0x2A);
- operands: randomize dst/src bytes; class byte randomize;
- immediates: 0, 1, `0xFFFFFFFF`, `code_size±8`, `0x80000000`;
- entry: 0, misaligned, `code_size`, huge.

**Oracle** (per iteration, `--max-steps 10000`, timeout 10 s):
- the `(exit code, stderr)` pair must be consistent with the termination
  class: a fatal error must exit `100 + id` **and** print
  `aurora: error: <NAME>` on stderr; a `HALT` (any exit code 0–255)
  must never print `aurora: error:`. Exit code alone is not a
  classifier (D22);
- must not die by signal (segfault/abort → FAIL with the input saved to
  `tests/fuzz_crashes/`);
- must not exceed the timeout;
- stderr on fatal errors must name the error.

**Runs:** default 5,000 iterations (`--iterations N` to scale). Seeded:
`--seed` reproduces a run; CI uses a fixed seed.

---

## 7. L6 — Determinism

Normative requirement (`ISA.md` §9, D17): same bytecode + same initial
state + same configuration MUST yield identical registers, memory, stack,
flags, output and exit code.

**Tests:**
- every `programs/*.asm` + every golden vector runs **twice**;
  stdout and exit code byte-compared (`diff`).
- a scripted debugger session runs twice; register/memory dumps
  byte-compared.
- `IN`-reading programs run twice with identical piped stdin → identical
  results; with different stdin → (documented) different results.

**Documented nondeterminism sources:** only stdin bytes consumed by `IN`.
No RNG, no clocks, no host addresses leak into guest state.

---

## 8. L7 — Debugger tests

Automated in `tests/debug/run_debug_tests.py` (40 checks, run via
`make test`). Scripted sessions (`printf ... | aurora debug prog.bin`),
asserting:
- `help`/`quit`: command list, exit 0; `debug --help` usage, exit 0;
  missing file exits 2;
- `run`/`continue`/`step [n]`: execution, single-step, multi-step;
- `break`/`delete`/`breakpoints`: set at entry/middle, list, delete,
  invalid address rejected;
- `regs`/`registers`/`flags`: PC/SP/FP, R0–R15, Z/C/N/V;
- `memory <addr> [count]`: hex and decimal addresses, counts, out-of-range
  rejected; `stack`/`backtrace`;
- `disasm`: 43-opcode display-only disassembler;
- `reset`: restores snapshot, allows re-run; `set max-steps`;
- D22: `DIVISION_BY_ZERO` (FATAL, 106) vs `HALT` R0=106 (NORMAL, 106);
  commands rejected after termination;
- determinism: identical output for identical sessions.

---

## 9. Test harness conventions

- Runner: `tests/run_tests.sh` (POSIX sh). Each test prints
  `PASS`/`FAIL: <name> (<reason>)`; the suite exits nonzero on any
  failure and prints a summary count.
- Assembler-error tests match stderr with `grep -F` on the
  `file:line: error:` prefix plus the category word.
- VM-error tests match the `(termination_class, termination_reason,
  exit_code)` triple: exit code **and** the error name on stderr
  (`aurora: error: DIVISION_BY_ZERO …`). A bare exit-code match is not
  sufficient — see the normative termination tests in §10.
- New tests are added as data (`.asm` + `.expected` / `.bin` + expectations),
  not as harness code, wherever possible.
- No network, no absolute paths, no host-specific assumptions.
  `python3` required only for fixture generation and fuzzing.

---

## 10. Normative termination tests (D22)

These tests prove the termination model of `ISA.md` §6.1.1: the exit code,
in isolation, does not classify a run. Each test asserts the full
`(termination_class, termination_reason, exit_code)` triple.

| Test | Program | termination_class | termination_reason | exit_code |
|------|---------|-------------------|--------------------|-----------|
| T1 | `MOV R0, 0` · `HALT` | NORMAL | HALT | 0 |
| T2 | `MOV R0, 106` · `HALT` | NORMAL | HALT | 106 |
| T3 | `MOV R1, 10` · `MOV R2, 0` · `DIV R1, R2` · `HALT` | FATAL | DIVISION_BY_ZERO | 106 |
| T4 | `MOV R0, 105` · `HALT` | NORMAL | HALT | 105 |
| T5 | `POP R0` · `HALT` | FATAL | STACK_UNDERFLOW | 105 |

The decisive assertions:

- **T2 vs T3:** same exit code (`106`) ≠ same termination —
  `NORMAL/HALT` vs `FATAL/DIVISION_BY_ZERO`. T3 must also print
  `aurora: error: DIVISION_BY_ZERO …` on stderr; T2 must not print any
  `aurora: error:` line.
- **T4 vs T5:** same principle for a second overlapping error —
  `NORMAL/HALT` with exit `105` vs `FATAL/STACK_UNDERFLOW` with exit
  `105` (`POP` on the empty stack: initial `SP = 0x10000` violates the
  `SP < 0x10000` precondition).

Byte-level fixtures (hand-derived from the frozen spec, assembler-
independent like the L1 golden vectors) live in
`tests/termination/`: `.asm` sources, a manifest with the exact code
bytes and the expected triples, and `run_termination_tests.py`, which
rebuilds the `.bin` files, checks the size equation
(`file_size == 0x1A + code_size + data_size`), the header fields, and
an independent per-slot scan (opcode range, class tag, register fields,
imm32 rules). The execution half of the assertions — running each
fixture under `aurora run` and checking the reported termination triple —
is wired into L4 and runs once the CPU exists (phase 3); until then the
script validates fixtures and skips execution with a clear message.

No test in this section may assert a category from the exit code alone.
