# AURORA Runtime — ABI & Services (v1)

**Status:** normative for the runtime layer (phase 6). Does not alter the
frozen ISA (`docs/ISA.md`), the bytecode format (`docs/BYTECODE.md`), or
any architectural decision D01–D25. New decisions are recorded as D26 in
`docs/DECISIONS.md`.

---

## 1. Objective

Give guest programs a **formal, testable, deterministic** way to request
execution services (termination, structured I/O) without breaking the
frozen ISA. The runtime is a *contract* plus a *guest-side library*:

- `docs/RUNTIME.md` (this file) — the ABI contract;
- `runtime/aurora_rt.asm` — the reference implementation, in AURORA
  assembly, using only the 43 frozen opcodes.

---

## 2. Guest / Runtime / Host boundary

```text
Guest program
      │  CALL svc_write / svc_read / svc_exit   (ABI: this document)
      ▼
Runtime library  (runtime/aurora_rt.asm — guest-side AURORA code)
      │  IN / OUTC / HALT                    (frozen ISA §6.10, §6.1)
      ▼
CPU (existing handlers in src/cpu.asm)
      │  read(0) / write(1) / process exit   (host syscalls)
      ▼
Host OS (Linux/x86-64)
```

A guest address is **always** an AURORA virtual address (`0x0000–0xFFFF`).
It is never a host pointer. The only address translation in the system is
the one the CPU already performs (`MEM + addr` after the ISA §5 bounds
check). The runtime library performs no host access of its own: every
host effect goes through the existing `IN`/`OUTC`/`HALT` handlers.

Why guest-side? The frozen ISA defines **no trap instruction** and no
reserved CALL target: every `CALL` target must satisfy
`addr < code_size ∧ addr % 8 = 0` (ISA §6.8, loader-enforced), and the
semantics of `IN`/`OUT`/`OUTC`/`HALT` cannot be extended without altering
the ISA (see D26). Any host-side dispatch smuggled into an existing
instruction would be a silent ISA change. The compatible mechanism is
therefore a **calling convention** over existing instructions — the same
way a C library is a calling convention over real syscalls.

---

## 3. ABI — service identification

A service is identified by **the entry point called**. There are no
service numbers and no multiplexed trap:

| Entry point | Service |
|-------------|---------|
| `svc_exit`   | terminate the guest |
| `svc_write`  | structured byte output |
| `svc_read`   | structured byte input |

Linking is static, by concatenation (the assembler has no `INCLUDE`):

```sh
cat prog.asm runtime/aurora_rt.asm > /tmp/linked.asm
python3 tools/aurora-asm /tmp/linked.asm -o prog.bin
```

The guest program comes first so entry point 0 is guest code; label
resolution is order-independent (two-pass assembly). Labels starting with
`svc_` are reserved; guest programs must not define them (the assembler
rejects duplicates).

---

## 4. Argument convention

Arguments are passed in general-purpose registers, in order:

```text
R0 = arg0,  R1 = arg1,  R2 = arg2
```

R3–R15 are never arguments in ABI v1. There are no stack arguments.

## 5. Return convention

```text
R0 = return value
```

The meaning of R0 on return is defined per service (§7). A return value
of `-1` (`0xFFFFFFFFFFFFFFFF`) always means a **recoverable service
error**; the specific cause is not encoded (ABI v1 keeps one error code;
see §6).

## 6. Register / flag / stack discipline

A service call is an ordinary `CALL` (ISA §6.8, §8): it pushes the return
address and the saved FP, sets `FP = SP`, and `RET` restores everything.
On top of that, every ABI v1 service guarantees:

| State | Guarantee |
|-------|-----------|
| `R0` | return value (clobbered) |
| `R1`–`R2` | argument/scratch registers (**clobbered**) |
| `R3`–`R15` | **preserved** (bit-identical after `RET`) |
| `SP`, `FP` | **preserved** (balanced; the frame is fully unwound) |
| `PC` | continues at the instruction after `CALL` |
| `FLAGS` | **clobbered** (unspecified) |
| guest stack | up to 16 bytes used below the caller's `SP` |

`FLAGS` cannot be preserved: the ISA provides no instruction that reads
`FLAGS` into a register, so no guest code — the runtime library included —
can save and restore them. Any loop needs `CMP`/`SUB`, which set flags.
Callers must assume Z/C/N/V are destroyed by a service call.

Stack requirement: the caller must have at least 16 bytes of stack headroom
(`SP ≥ 0xF000 + 16`) before the `CALL`; otherwise the service's `PUSH`
faults with `STACK_OVERFLOW`, exactly as any nested call would.

---

## 7. Services

### 7.1 `svc_exit(status)`

```text
R0 = status (u64; only R0 & 0xFF reaches the process exit code)
returns: never
```

Terminates the guest through `HALT`. Termination class is **NORMAL**,
reason **HALT**, exit code `R0 & 0xFF` — for *every* R0 value, including
106 (see D22: `HALT` with `R0 = 106` is normal termination, exit 106; it
is *not* `DIVISION_BY_ZERO`). `svc_exit` is documentation and uniformity:
the mechanism is the ISA's own `HALT`, not a second termination path.

### 7.2 `svc_write(fd, buf, len)`

```text
R0 = fd    1 = stdout (the only logical destination in ABI v1)
R1 = buf   guest virtual address of the first byte
R2 = len   number of bytes (u64)
returns: R0 = bytes written (== len), or -1 on error
```

Recoverable errors (returned as `-1`, never fatal):

- `fd != 1`;
- `len > 0x10000`, or `[buf, buf+len)` not fully inside `[0, 0x10000)`.

The bounds check is wraparound-safe and follows ISA §5 exactly:

```text
reject if len ≥ 2^63            (bit 63 set — would wrap the subtraction)
reject if len > 0x10000
limit = 0x10000 - len           (cannot wrap now)
reject if buf ≥ 2^63
reject if buf > limit
```

Notes:

- `len == 0` returns `0` (fd is still validated; the buffer is untouched).
- Bytes are emitted with `OUTC`, one per byte. A host write failure raises
  `IO_ERROR` (fatal), exactly as if the guest had executed `OUTC` itself
  (ISA §6.10). The runtime introduces **no new fatal errors**.
- The buffer is read with `LOADB`; reads from the code segment are allowed
  by the ISA, so this path can never raise `WRITE_TO_CODE`.

### 7.3 `svc_read(fd, buf, len)`

```text
R0 = fd    0 = stdin (the only logical source in ABI v1)
R1 = buf   guest virtual address to store into
R2 = len   maximum number of bytes (u64)
returns: R0 = bytes actually read (0..len), or -1 on error
```

Recoverable errors (returned as `-1`, never fatal):

- `fd != 0`;
- `len > 0x10000`, or `[buf, buf+len)` not fully inside `[0, 0x10000)`
  (same wraparound-safe rule as `svc_write`).

Notes:

- `len == 0` returns `0` without touching the buffer.
- EOF (`IN` yields `0xFFFFFFFFFFFFFFFF`) ends the read; a short count —
  possibly `0` — is returned. Empty stdin is **not** an error, matching
  ISA §6.10 and the existing EOF tests.
- Bytes are stored with `STOREB`. A store intersecting the code segment
  raises `WRITE_TO_CODE` (fatal), exactly as a direct guest `STOREB`
  would (ISA §6.6). The runtime does not mask ISA faults.
- A host read failure raises `IO_ERROR` (fatal), as for `IN` (ISA §6.10).

### 7.4 Logical descriptors

| fd | direction | bound to |
|----|-----------|----------|
| 0 | read | stdin (via `IN`) |
| 1 | write | stdout (via `OUTC`) |

Any other fd is a recoverable `-1` error. ABI v1 exposes exactly the two
host streams the ISA already exposes; there are no files, sockets, or
sinks beyond them.

---

## 8. Memory

Guest memory remains 64 KiB, `0x0000–0xFFFF` (ISA §5). Every service that
takes `buf` + `len` validates with the wraparound-safe comparison
`buf > 0x10000 − len` (never the naive `buf + len ≤ 0x10000`, which wraps
for huge register values). The runtime never:

- reads host memory as if it were guest memory;
- writes host memory;
- escapes the 64 KiB;
- interprets a guest address as a host pointer — the only translation is
  the CPU's existing `MEM + addr` after the bounds check.

---

## 9. I/O

All host I/O goes through the frozen instructions:

- output: `OUTC` (byte stream, no decimal formatting — unlike `OUT`);
- input: `IN` (blocking 1-byte read; `0xFFFFFFFFFFFFFFFF` on EOF);
- errors: `IO_ERROR` (fatal, exit 112), unchanged from direct use.

`svc_write`/`svc_read` add **structure** (buffer + length + validation +
counted return) on top of the **existing byte facilities**. They do not
add buffering, seeking, or new streams.

---

## 10. Determinism

The runtime is deterministic (ISA §9): same bytecode + same initial state
+ same stdin ⇒ same registers, memory, stack, flags, output, exit code,
and the same observable debugger session. No service reads the clock,
seeds randomness, or depends on host addresses. ABI v1 introduces **no
nondeterministic service** (`time`, `random`, UUID and equivalents are
explicitly out of scope; see §15). Repeated-execution tests pin this
(`tests/runtime/`, determinism checks).

---

## 11. Interaction with the CPU

There is exactly one CPU. Services execute as ordinary guest instructions
through the existing `cpu_step()` fetch/decode/execute loop — the same
handlers (`h_in`, `h_outc`, `h_halt`, …), the same registers, the same
memory, the same `FLAGS`. No second register file, no second PC, no
shadow memory, no reimplemented flags. `vm_steps`/`max_steps` accounting
is unchanged: service instructions are guest instructions and consume
steps like any other.

---

## 12. Interaction with the debugger

The debugger (phase 5) needs **no changes**:

- `step`/`run`/`continue` keep their semantics — a service call is just
  instructions; `step` over a `CALL svc_write` executes the whole service
  (as it would for any call), and breakpoints can be set on the `CALL`,
  inside the library, or after the return;
- breakpoints remain guest code addresses;
- `regs` shows the real post-service state (R0 = return value, R1–R15
  preserved per §6);
- `memory` shows the virtual memory the service read/wrote;
- `reset` restores the post-load snapshot, as before;
- termination is reported with the D22 classes: `svc_exit(106)` shows
  `halted (exit code 106)` — NORMAL — exactly like a direct `HALT`.

---

## 13. Termination

D22 is sovereign and untouched. The runtime defines **no second
termination model**:

- `svc_exit(n)` → `NORMAL` / `HALT`, exit `n & 0xFF`;
- a fatal error inside a service (`IO_ERROR` from `OUTC`/`IN`,
  `WRITE_TO_CODE` from `STOREB` into code) → `FATAL` / `<error>`,
  exit `100 + id`, with `aurora: error: <NAME>` on stderr.

The `(termination_class, termination_reason, exit_code)` triple is asserted
by tests, never the exit code alone (TESTING.md §10).

---

## 14. Examples

`examples/runtime/` (each assembled by concatenating the guest program
FIRST, so entry 0 is guest code — `runtime/aurora_rt.asm` comes second):

- `hello_runtime.asm` — `svc_write(1, msg, 16)` then `svc_exit(0)`;
- `io_runtime.asm` — `svc_read(0, buf, 16)` then echo with
  `svc_write(1, buf, n)`; demonstrates short reads and EOF;
- `exit_runtime.asm` — `svc_exit(42)`; the minimal termination service.

Build & run:

```sh
cat examples/runtime/hello_runtime.asm runtime/aurora_rt.asm > /tmp/l.asm
python3 tools/aurora-asm /tmp/l.asm -o /tmp/hello.bin
./build/aurora run /tmp/hello.bin
```

---

## 15. Limitations (explicit non-goals)

- No nondeterministic services (`time`, `random`, UUID, …). Determinism
  outranks feature count in this phase.
- One error code (`-1`); no `errno`-style detail. The cause space is tiny
  (bad fd, bad bounds) and documented per service.
- No files, directories, sockets, or seeking — only stdin/stdout.
- `FLAGS` are clobbered by every service (§6) — the ISA gives guest code
  no way to preserve them.
- No dynamic linking: the library is concatenated at assembly time.
- `svc_read` into the code segment is a fatal `WRITE_TO_CODE` (ISA §6.6),
  not a recoverable error — a deliberate choice to never mask ISA faults.

---

## 16. Conformance

`tests/runtime/run_runtime_tests.py` (TESTING.md §8, L8) pins: the ABI
contract (arguments, return, preserved registers, `FLAGS` clobbered),
`svc_exit` (0, 42, 106 + D22 contrast), `svc_write`/`svc_read` (valid,
zero-length, boundary, invalid, overflow, EOF, empty input), memory
safety (no unrelated corruption, SP/FP/PC correct), debugger sessions
(step/run/breakpoint/reset over services), and determinism (repeated
runs byte-identical). Key fixtures are frozen as golden `.bin` files so
they stay independent of future assembler changes.
