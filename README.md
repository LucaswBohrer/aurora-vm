# AURORA VM

A 64-bit virtual machine with a custom ISA, bytecode format, assembler and
debugger — implemented from scratch in x86-64 Assembly.

AURORA is an engineering challenge: design a complete virtual computer
(virtual CPU, registers, memory, stack, loader, debugger, assembler,
bytecode format) and implement its runtime core in **100% x86-64 Assembly**
(NASM, ELF64, Linux syscalls only — no libc). The assembler is separate
Python 3 tooling (stdlib only) in `tools/`.

## Highlights

- **Custom virtual CPU** — fetch → decode → execute loop in x86-64 Assembly
- **16 virtual registers** (`R0`–`R15`, 64-bit) plus `PC`, `SP`, `FP`, `FLAGS`
- **64-bit architecture** — all arithmetic/logic is 64-bit
- **64 KiB virtual memory** — byte-addressable, bounds-checked, wraparound-safe
- **Custom ISA** — 43 opcodes (`0x00`–`0x2A`), frozen for v1
- **Custom bytecode** — 26-byte header, fixed 8-byte instructions
- **x86-64 Assembly VM** — static binary, no libc, raw Linux syscalls
- **Python assembler** — two-pass, labels, directives (stdlib only)
- **Debugger** — breakpoints, stepping, register/memory/stack inspection
- **Deterministic execution** — same bytecode + same input ⇒ same everything
- **Golden vectors** — normative byte-level test vectors, assembler-independent
- **Fuzzing** — mutational bytecode fuzzing in the suite
- **Automated tests** — 7 test layers, `make test`

## Architecture

```text
AURORA Assembly
       │
       ▼
   Assembler
   (Python)
       │
       ▼
   Bytecode
       │
       ▼
┌───────────────┐
│   AURORA VM   │
│               │
│ CPU           │
│ Memory        │
│ Stack         │
│ Loader        │
│ Debugger      │
└───────────────┘
       │
       ▼
 Linux x86-64
```

The assembler (Python, `tools/`) translates AURORA Assembly into the frozen
bytecode format. The VM (Assembly, `src/`) validates the file in the loader,
then executes it on the virtual CPU. The debugger (Assembly) drives the same
CPU with breakpoints and inspection.

## Example

`examples/hello.asm` — assembled with `tools/aurora-asm` (phase 4):

```asm
; Print "Hello, world!" and halt with exit code 0.
    MOV R0, msg
loop:
    LOADB R1, [R0]
    CMP R1, 0
    JE done
    OUTC R1
    ADD R0, 1
    JMP loop
done:
    MOV R0, 0
    HALT

msg: DB "Hello, world!", 10, 0
```

Pipeline (end-to-end since phase 4):

```text
hello.asm
  ↓  aurora-asm (phase 4)
hello.bin            ← 26-byte header + 9 fixed 8-byte instructions
  ↓  aurora run (phase 3)
Hello, world!        ← stdout
(exit code 0)
```

Hand-assembled per `docs/BYTECODE.md` (header: magic `41 55 52 4F 52 41 01 00`,
version `0x0001`, `code_size` = 24, `entry` = 0, `data_size` = 0):

```text
offset  bytes
0x00    41 55 52 4F 52 41 01 00   magic "AURORA" + format tag
0x08    01 00                     version 0x0001 (LE)
0x0A    18 00 00 00               code_size = 24 (LE u32)
0x0E    00 00 00 00               entry = 0
0x12    00 00 00 00               data_size = 0
0x16    00 00 00 00               reserved
0x1A    03 00 FF 02 2A 00 00 00   MOV R0, 42      (I-class, imm32 = 42)
0x22    28 FF 00 03 00 00 00 00   OUT R0          (r-class, reg in src)
0x2A    01 FF FF 00 00 00 00 00   HALT            (N-class)
```

What works today (phase 1):

```console
$ ./build/aurora --help
Usage: aurora <command> [options]
...
$ ./build/aurora run hello.bin
aurora: loader: not implemented in this build (phase 1)
$ echo $?
3
```

## ISA

The AURORA ISA is **frozen at exactly 43 opcodes** (`0x00`–`0x2A`) for v1:

| Group | Instructions |
|-------|--------------|
| System | `NOP`, `HALT` |
| Data movement | `MOV` (reg/reg, reg/imm32) |
| Arithmetic | `ADD`, `SUB`, `MUL`, `DIV`, `MOD`, `NEG` (reg and imm forms) |
| Logic | `AND`, `OR`, `XOR`, `NOT`, `SHL`, `SHR` |
| Compare | `CMP` (sets Z/C/N/V flags) |
| Control flow | `JMP`, `JE`, `JNE`, `JG`, `JL`, `JGE`, `JLE` (signed) |
| Functions | `CALL`, `RET` (uniform frame: return address + saved `FP`) |
| Stack | `PUSH`, `POP` |
| Memory | `LOAD`, `STORE` (64-bit, unaligned-safe), `LOADB`, `STOREB` |
| I/O | `OUT`, `OUTC`, `IN` |
| Debug | `BREAK` |

Every instruction is exactly 8 bytes:
`[opcode:u8][dst:u8][src:u8][class:u8][imm32:LE]`.
Flags `Z/C/N/V`; 12 fatal errors exit with `100 + id` (101–112).

Full normative specification: [`docs/ISA.md`](docs/ISA.md).

## Bytecode

```
file_size == 0x1A + code_size + data_size
```

- 26-byte header: magic, version (`0x0001`), `code_size`, `entry`, `data_size`
- Code: `code_size / 8` fixed 8-byte instruction slots
- Data: raw bytes loaded at virtual address `code_size`
- The loader validates **every** slot (opcode range, class tag, register
  fields, jump targets, memory addresses) before execution begins

Full normative specification: [`docs/BYTECODE.md`](docs/BYTECODE.md).

## Debugger

`aurora debug <file>` (phase 5) — interactive debugger in Assembly:

- 16 breakpoints, `run` / `step` / `continue`
- register dump, memory dump, stack view, backtrace
- distinguishes `halted (exit code N)` from `fatal error: <NAME>`

## Runtime ABI

`runtime/aurora_rt.asm` (phase 6) — a guest-side service library in AURORA
assembly (frozen ISA, no traps): `svc_exit`, `svc_write`, `svc_read`.
Guest programs link it by concatenation and `CALL` the entry points;
arguments in R0–R2, return in R0, R3–R15/SP/FP preserved.
Full contract: [`docs/RUNTIME.md`](docs/RUNTIME.md).

## Testing

Eight layers ([`docs/TESTING.md`](docs/TESTING.md)):

```text
L1 Golden Vectors        byte-exact vectors, assembler-independent (normative)
L2 Assembler             two-pass assembly, directives, diagnostics
L3 Bytecode Rejection    malformed files rejected with the right error
L4 Execution / Torture   CPU, memory, stack, flags; fib(30) stress program
L5 Fuzzing               mutational bytecode fuzzing, no hangs/crashes
L6 Determinism           repeated runs are bit-identical
L7 Debugger              scripted interactive sessions
L8 Runtime ABI           service contract, memory safety, golden fixtures
```

## Build

Requirements: `nasm`, `ld` (binutils), `make`, `python3` (assembler only).

```bash
make
```

Produces the static binary `build/aurora` (no libc).

## Tests

```bash
make test
```

Runs the phase test suites (`make test`): L1–L4, L6, L7, L8 — all green
(CLI, bytecode, opcode audit, CPU, termination, assembler, debugger,
runtime ABI).

## Fuzzing

```bash
make fuzz
```

Bytecode mutation fuzzing — lands with the CPU in a later phase
(see [`docs/TESTING.md`](docs/TESTING.md)).

## Project Structure

```text
aurora-vm/
├── src/            # VM core — 100% x86-64 Assembly (NASM)
│   ├── main.asm    # _start, CLI dispatch
│   ├── cli.asm     # --help / --version
│   ├── errors.asm  # fatal_error (100+id), usage errors
│   ├── util.asm    # string/IO helpers, u64 parser
│   ├── run.asm     # `aurora run`
│   ├── debug.asm   # `aurora debug`
│   └── loader.asm  # bytecode loader (phase 2)
├── tools/          # assembler — Python 3 stdlib only (phase 4)
├── runtime/        # ABI v1 guest-side library (phase 6)
├── programs/       # sample AURORA programs (phase 4)
├── tests/          # test suites per phase + golden vectors
├── docs/           # normative specifications
│   ├── ARCHITECTURE.md
│   ├── ISA.md
│   ├── BYTECODE.md
│   ├── DECISIONS.md
│   ├── TESTING.md
│   └── RUNTIME.md
├── examples/       # illustrative AURORA Assembly sources
└── Makefile
```

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — design rationale, memory
  map, calling convention, error model
- [`docs/ISA.md`](docs/ISA.md) — **normative** ISA: 43 opcodes, encodings,
  semantics, flags, golden vectors
- [`docs/BYTECODE.md`](docs/BYTECODE.md) — **normative** file format and
  loader validation rules
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — architectural decision log
  (D01–D26)
- [`docs/TESTING.md`](docs/TESTING.md) — the 8 test layers
- [`docs/RUNTIME.md`](docs/RUNTIME.md) — **normative** runtime ABI v1:
  services, argument/return conventions, memory safety

## Status

| Phase | Scope | State |
|-------|-------|-------|
| 0 | Architecture + frozen ISA/bytecode spec | ✅ done |
| 1 | Foundation: CLI skeleton, error reporting | ✅ done |
| 2 | Loader: header + instruction-slot validation | ✅ done |
| 3 | CPU core: 43 handlers, flags, memory, stack, I/O | ✅ done |
| 4 | Assembler (Python 3 stdlib) + sample programs | ✅ done |
| 5 | Interactive debugger | ✅ done |
| 6 | Runtime ABI & services (guest-side library, D26) | ✅ done |
| 7 | Fib(30) stress + full program suite | ⬜ planned |
| 8 | Full suite + fuzzing + final docs | ⬜ planned |

Only phases marked ✅ are implemented. Nothing above is presented as working
before it is observed working.

## License

MIT — see [LICENSE](LICENSE).
