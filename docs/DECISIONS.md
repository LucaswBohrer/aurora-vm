# AURORA VM — Decision Log

Architectural decisions are recorded here, not lost in chat history.
Format: `DNN — date — title`, then context / decision / consequences.
The ISA freeze (D14) is the most consequential entry: after it, ISA changes
follow the protocol in `ISA.md` §0, not casual edits.

---

## D01 — 2026-10-01 — Language split: Assembly core, Python tooling

**Context:** The challenge requires the VM execution engine in x86-64
Assembly but allows other languages for tooling if clearly separated.

**Decision:** `src/*.asm` → single static binary `aurora` (no libc, raw
syscalls): CPU loop, loader, debugger. `tools/aurora-asm` → assembler in
Python 3, stdlib only. The assembler is build-time tooling, never part of
the runtime; it never executes guest instructions.

**Consequences:** Two-pass symbol tables, diagnostics and string parsing
stay in a maintainable language; the Assembly surface stays focused on the
machine model. Directory layout makes the split visible and enforceable.

## D02 — 2026-10-01 — Fixed-width 8-byte instruction encoding

**Context:** Variable-width encodings are denser but introduce
instruction-boundary bugs and complicate static validation.

**Decision:** Every instruction is exactly 8 bytes:
`[opcode|dst|src|class|imm32 LE]`.

**Consequences:** Fetch/decode are trivially correct; the loader can
validate the whole program statically; the debugger disassembler is
simple. Code density is sacrificed — irrelevant at 64 KiB scale.

## D03 — 2026-10-01 — Opcode-per-variant, no mode bits

**Context:** One mnemonic with mode bits vs. one opcode per operand shape.

**Decision:** 43 opcodes (0x00–0x2A); the assembler maps mnemonic +
operand shapes to the opcode. Dispatch is purely on the opcode byte via a
256-entry jump table.

**Consequences:** Zero decode-time ambiguity; each opcode has one fixed
operand layout. Cost: a larger opcode table, documented once in `ISA.md`.

## D04 — 2026-10-01 — Flags model: x86-inspired, precisely specified

**Decision:** Z/C/N/V with exact formulas per operation (§3.1 of ISA.md):
ADD/SUB/MUL per unsigned/signed rules, DIV signed (idiv-like), INC/DEC
preserve C, AND/OR/XOR clear C and V, NOT leaves flags unchanged,
non-arithmetic instructions leave flags unchanged.

**Consequences:** Flag behavior is testable bit-for-bit via golden
vectors; no "whatever the implementation does" cases.

## D05 — 2026-10-01 — I/O model: OUT (decimal), OUTC (char), IN (byte)

**Decision:** `OUT Rs` prints signed decimal + newline; `OUTC Rs` writes
the low byte; `IN Rd` reads one stdin byte (zero-extended), `-1` on EOF.

**Consequences:** Arithmetic programs are testable through stdout;
Hello World is possible without string-printing syscalls in the VM.

## D06 — 2026-10-01 — Code segment is read-only

**Decision:** Stores intersecting `[0, code_size)` raise `WRITE_TO_CODE`.
Reads from code are allowed.

**Consequences:** Wild-pointer bugs trap instead of silently corrupting
the program. Self-modifying code is impossible in v1 (documented).

## D07 — 2026-10-01 — Jumps are absolute byte offsets

**Decision:** `J*`/`CALL` targets are absolute offsets from the code base,
validated by the loader (`< code_size`, 8-aligned).

**Consequences:** Static validation of all control flow; simpler than
relative-offset fixups.

## D08 — 2026-10-01 — Infinite-loop protection via --max-steps

**Decision:** Default 100,000,000 steps; `0` = unlimited;
`MAX_STEPS_EXCEEDED` is a fatal error (exit 110).

**Consequences:** Deterministic, testable protection. The fib(30) stress
program (~40–60M steps) fits under the default; genuine infinite loops do not.

## D09 — 2026-10-01 — HALT exit code = R0 & 0xFF

**Decision:** Normal termination exits with the low byte of R0.
Fatal errors exit with `100 + id` (101–112).

**Consequences:** Tests can assert computed values via exit codes;
`HALT` and fatal errors are disjoint, machine-checkable categories.

> **Amended by D22 (2026-10-01):** the "disjoint, machine-checkable
> categories" consequence was incorrect *as a claim about exit codes*:
> `HALT` exits `R0 & 0xFF` (0–255), which overlaps the fatal-error range
> 101–112. The categories remain disjoint — but the classifier is the
> VM's `termination_class`/`termination_reason`, not the exit code
> alone. Nothing about opcodes, error ids or exit-code values changed.

## D10 — 2026-10-01 — Stack is a reserved region of the 64 KiB

**Decision:** `0xF000–0xFFFF`, 4 KiB, grows down; `SP`/`FP` init
`0x10000` (empty sentinel). Not a separate memory.

**Consequences:** One coherent memory model; the debugger inspects the
stack through the memory view.

## D11 — 2026-10-01 — Uniform call frames

**Decision:** `CALL` = `push(PC+8); push(FP); FP=SP`. `RET` =
`SP=FP; FP=pop(); PC=pop()`.

**Consequences:** Every call has a frame; recursion works; the debugger's
`backtrace` walks the FP chain. Two pushes of overhead per call —
uniformity over micro-optimization.

## D12 — 2026-10-01 — Signed division (idiv semantics)

**Decision:** `DIV` is signed. Divisor 0 → `DIVISION_BY_ZERO`.
`INT64_MIN / -1` → result `0x8000000000000000`, `V=1` (no trap).

**Consequences:** Friendlier than unsigned division for a teaching VM;
the single overflow case is defined instead of trapping.

## D13 — 2026-10-01 — Unaligned accesses allowed, bounds always checked

**Decision:** 64-bit loads/stores may be unaligned (x86-64 handles them);
only `[addr, addr+size) ≤ 0x10000` is enforced.

**Consequences:** Simpler than alignment traps; still memory-safe.

## D14 — 2026-10-01 — ISA v1.0 FROZEN at 43 opcodes

**Context:** Specification revision round (user directive).

**Decision:** `docs/ISA.md` is the normative ISA source, frozen at
exactly 43 opcodes (`0x00`–`0x2A`) with fixed numeric values, formats,
operands, semantics, flags and errors. `docs/BYTECODE.md` (container
format v1) is frozen with it.

**Change protocol (normative):** if an ISA change becomes necessary
during implementation: (1) stop implementing that part; (2) document the
problem; (3) update the specification; (4) record the decision here;
(5) only then continue. No silent creation, removal or alteration of any
instruction.

## D15 — 2026-10-01 — Golden test vectors are normative

**Decision:** `ISA.md` §12 defines 9 golden vectors with hand-computed
expected bytes, registers, flags, memory, stack, output and exit codes.
They validate the VM independently of the assembler (hand-written `.bin`
fixtures + scripted debugger sessions).

**Consequences:** The assembler and VM cannot share a bug undetected on
covered semantics; the vectors are the executable definition of the ISA.

## D16 — 2026-10-01 — Bytecode fuzzing is required

**Decision:** `tests/fuzz.py` mutates headers, versions, opcodes,
operands, class bytes, immediates, entry points, sizes and truncations.
Oracle: the VM must never segfault, hang past `--max-steps`, or exit
with a code outside `{0} ∪ {101..112}`.

> **Amended by D22 (2026-10-01):** the `{0} ∪ {101..112}` oracle wording
> was incorrect — `HALT` can legally exit with any code in `0–255`, so
> the oracle is now stated as an `(exit code, stderr)` consistency check
> against the termination class: a fatal error must exit `100 + id`
> *and* name the error on stderr; a `HALT` never prints
> `aurora: error:`. The exit code alone is not a classifier.

**Consequences:** A clear safety bar against malformed inputs, enforced
in the test suite.

## D17 — 2026-10-01 — Determinism is normative

**Decision:** Same bytecode + same initial state + same configuration
MUST produce same registers, memory, stack, flags, output and exit
code. `IN` (stdin) is the only legitimate nondeterminism source, and it
is documented as such.

## D18 — 2026-10-01 — No unsigned jumps in v1

**Decision:** `JA`/`JB` and other unsigned conditional jumps are NOT
added. v1 keeps the 7 signed jumps (`JMP` + `JE/JNE/JG/JL/JGE/JLE`).
Unsigned behavior must be synthesized from existing instructions.

**Consequences:** ISA stays minimal per the "don't expand just to add
instructions" principle. Revisit in a hypothetical v2 (out of scope).

## D19 — 2026-10-01 — Ambiguity protocol during implementation

**Decision:** Architectural ambiguities discovered during implementation
(ISA, bytecode, memory, calling convention, flags, instruction semantics,
error behavior, file formats) are NOT resolved silently. Implementation
of the affected part stops; the question is recorded; the documentation
is updated first; only then does implementation continue.

## D20 — 2026-10-01 — Assembler stays in Python (question closed)

**Decision:** The open question "assembler in Python vs Assembly" is
closed: Python 3 stdlib-only in `tools/`, per D01. The VM core remains
100% x86-64 Assembly.

## D21 — 2026-10-01 — CLI exit-code scheme (phase 1)

**Decision:** Host-side exit codes, distinct from guest/VM codes:

- `0` — success, `--help`/`--version`, or bare `aurora` (prints help).
- `2` — command-line usage error: unknown command, missing/extra
  operands, unknown option, invalid `--max-steps` value, unreadable
  input file. Message format: `aurora: <context>: <detail>\n` on stderr.
- `3` — phase-1 scaffolding only: loader/debugger not implemented yet.
  Removed when phase 2 lands; no test may depend on it long-term.
- `100 + <error id>` — fatal VM errors per the frozen spec (101–112).

A host-side file-open failure is a *usage error* (exit 2), NOT the
guest `IO_ERROR` (id 12, exit 112), which is reserved for guest
stdin/stdout failure during execution.

**Consequences:** `make test` (phase 1) asserts these codes. The `run`
subcommand validates `--max-steps` with an overflow-checked u64 parser
(empty string, non-digits, negative and >2^64-1 rejected).

## D22 — 2026-10-01 — Termination model: exit code is not a classifier

**Problem:** `HALT` exits with `R0 & 0xFF` (0–255) while fatal errors
exit with `100 + id` (101–112). The ranges overlap: `HALT` with
`R0 = 106` exits `106`, exactly like `DIVISION_BY_ZERO`. The spec
claimed the two categories were "disjoint, machine-checkable" by exit
code — that claim was wrong.

**Decision:** Keep both rules exactly as specified — `HALT` exits
`R0 & 0xFF`, fatal errors exit `100 + id`. No opcode, error id, exit
code value, bytecode format or calling convention changes. Instead,
define formally that **the exit code, in isolation, does not determine
whether execution ended normally or fatally**. Every execution ends
with a VM-internal `termination_class` (`NORMAL` / `FATAL`) and a
`termination_reason` (`HALT` or the specific error name):

- `HALT` → `termination_class = NORMAL`, `termination_reason = HALT`,
  `exit_code = R0 & 0xFF`;
- fatal error → `termination_class = FATAL`,
  `termination_reason = <error name>`, `exit_code = 100 + id`.

The debugger distinguishes `halted (exit code N)` from
`fatal error: <NAME>` even when `N` is numerically equal to a fatal
error's exit code. Tests assert the
`(termination_class, termination_reason, exit_code)` triple, never the
exit code alone.

**Why the overlap is acceptable:** the exit code is a lossy 8-bit
channel to the host OS; it was never meant to carry the termination
semantics. The VM's own termination state is the source of truth, and
fatal errors additionally announce themselves on stderr
(`aurora: error: <NAME>[: <detail>]`), which a `HALT` never prints.

**Consequences:** `ISA.md` §6.1.1 rewritten around the termination
model; `ARCHITECTURE.md` error-model and L5 oracle corrected; the L5
fuzzing oracle is now an `(exit code, stderr)` consistency check against
the termination class; `TESTING.md` §10 adds five normative termination
tests (T1–T5) proving that identical exit codes can mean different
terminations; D09 and D16 carry amendment notes (history preserved).

## D23 — 2026-10-01 — Assembler language choices (phase 4)

**Problem:** the frozen ISA specifies mnemonics, operand shapes, encoding
and bytecode exactly, but no assembly *language* (comments, labels,
literals, directives, diagnostics). The assembler (`tools/aurora-asm`)
had to choose a concrete syntax without inventing semantics.

**Decision:** the syntax follows the ISA text as literally as possible:

- Mnemonics, register names and directives are case-insensitive;
  labels are case-sensitive (labels are user-defined names, and
  case-folding them would create collisions the spec never defines).
- `;` starts a comment (except inside string literals); labels are
  `name:`; memory operands are `[a32]` / `[Rs]` exactly as written in
  ISA §6; data directives are `DB`/`DW`/`DD`/`DQ` with the widths the
  spec's own examples imply.
- No entry-point directive: output always uses `entry = 0`, the first
  instruction. An entry directive would be a new semantic; omitting it
  keeps every assembled program's layout fully determined by source
  order.
- Class-I immediates accept the full `-2^31..2^32-1` pattern range,
  mirroring the loader rule (BYTECODE.md §2), encoded as low 32 bits.
  Out-of-range values are a hard assembly error, never silent
  truncation.
- The assembler re-checks the loader's address rules (`[a32]` within
  `0x10000 - 8`, jump targets inside code, `code + data <= 0xF000`) at
  assembly time so invalid programs fail early with a `file:line:col`
  diagnostic instead of producing bytecode the loader would refuse.

**Non-decisions (deliberately left out):** macros, includes, constants
(`EQU`), sections, alignment directives, relocation, listing output.
None is needed to express any of the 43 opcodes, and each would be a
new semantic the frozen spec does not define.

**Consequences:** `docs/ASSEMBLER.md` is the language reference;
`tests/asm/` pins the syntax, the 43/43 opcode coverage, the class-`r`
field placement, the V1–V9 byte-exact golden comparison, and 33
negative diagnostics. The golden vectors in ISA §12 remain the
normative authority and stay assembler-independent.

## D24 — Debugger: observation layer, not a second CPU (2026-10-01)

**Context:** Phase 5 adds `aurora debug`, an interactive debugger.

**Decision:** The debugger reuses `cpu_step()` — the same single-instruction
function the runner uses — instead of reimplementing fetch/decode/execute.
Breakpoints live in a 16-slot debugger-side table (`dbg_bps`); the guest
bytecode is never patched. The disassembler is display-only.

**`reset` semantics:** `reset` restores the post-load snapshot (registers +
full memory) and clears steps/termination. Breakpoints are kept, per Lucas's
explicit guidance that they "may remain configured" — they are debugger
configuration, not guest state.

**Consequences:** ISA, bytecode, and CPU semantics stay frozen. `step n`
always executes the first instruction (breakpoint check starts at the 2nd
fetch) so a breakpoint at the current PC cannot wedge the session.
Termination follows D22 explicitly (NORMAL/FATAL + reason).

## D25 — `write_all` returns status instead of dying from nested calls

**Context:** `OUT → out_i64 → write_all` (and `OUTC → write_all`) are nested
host calls inside `cpu_step`. The old `write_all` jumped to `die_io_error`
directly, which would unwind to `step_ret` with stale return addresses on
the host stack.

**Decision:** `write_all` returns `rax = 0` (ok) / `-1` (error). The `h_out`
and `h_outc` handlers check and jump to `die_io_error` themselves, at the
top-level handler frame where the stack layout is known.

**Consequences:** I/O errors remain fatal (`IO_ERROR`, exit 100+id) with a
safe unwind. No behavior change on success.
