# AURORA Debugger

Interactive debugger for AURORA bytecode (`aurora debug <file>`).
Phase 5 of the AURORA VM project.

## Design principles

The debugger is an **observation and control layer**, not a second CPU:

- It uses the same `cpu_step()` as the normal runner — one instruction per
  call, same 43 handlers, same semantics.
- Breakpoints are stored **outside** the bytecode (a 16-slot table in the
  debugger). The guest memory is never modified to insert traps.
- The disassembler is display-only; it never alters program state.
- ISA, bytecode v1, opcodes, flags, calling convention, memory layout,
  stack, error IDs, and CPU semantics are unchanged (frozen).

## CLI

```
aurora debug <file>      # start interactive session
aurora debug --help      # usage
```

Exit codes follow the project convention (D21):
- `0` — debugger exited normally (`quit` or EOF).
- `2` — CLI error (missing file, unreadable file, invalid bytecode).

## Commands

All commands are line-oriented. Addresses accept `0x`-hex or decimal.
Counts are decimal or `0x`-hex.

| Command | Effect |
|---|---|
| `help` | List commands. |
| `run` | Run from current PC until breakpoint, termination, or max-steps. |
| `continue` | Alias for `run`. |
| `step [n]` | Execute n instructions (default 1). The first instruction always runs, even if a breakpoint is set at the current PC; breakpoints are checked before the 2nd..n-th fetch. |
| `break <addr>` | Set breakpoint (max 16). Address must be inside code, 8-aligned. |
| `delete <addr>` | Remove breakpoint. |
| `breakpoints` | List breakpoints. |
| `regs` / `registers` | Dump R0–R15, PC, SP, FP, FLAGS. |
| `flags` | Show Z/C/N/V. |
| `memory <addr> [count]` | Hex dump (default 16 bytes). Range must be within 0..0xFFFF. |
| `stack [count]` | Dump words from SP upward (default 8). |
| `backtrace` | Walk FP chain, print frame PCs. |
| `disasm <addr> [count]` | Disassemble count instructions (default 4). Display-only. |
| `info` | Code size, steps, max-steps, termination status, breakpoint count. |
| `reset` | Restore the pristine post-load snapshot (registers + memory). Breakpoints are kept. Steps counter cleared. Termination cleared. |
| `set max-steps <n>` | Set instruction limit (0 = unlimited). Default 100,000,000. |
| `quit` | Exit debugger (code 0). |

## Termination (D22)

The debugger reports the formal termination model:

- `terminated: NORMAL (HALT), exit code <n>` — HALT executed, R0 & 0xFF.
- `terminated: FATAL (<ERROR_NAME>), exit code <100+id>` — fatal error.

Same exit code ≠ same termination: `HALT` with R0=106 and
`DIVISION_BY_ZERO` both exit 106, but the class differs. After termination,
`run`/`continue`/`step` are rejected; use `reset` to run again.

## Breakpoints

- Up to 16, stored in `dbg_bps` (8 bytes each, -1 = empty).
- Checked **before** each fetch in `run`/`continue`.
- In `step n`, the first fetch always executes (avoids getting stuck on a
  breakpoint at the current PC); the check applies from the 2nd fetch on.
- Setting a breakpoint at the current PC then `continue` will stop
  immediately (the check happens before the fetch).

## `reset` semantics

`reset` restores the snapshot taken after loading (registers + full 64 KiB
memory), zeroes the step counter, and clears the termination flag.
Breakpoints are **kept** — they are debugger configuration, not guest state.

## Determinism

Given the same bytecode and command sequence, the debugger produces
identical output. No timestamps, no ASLR-dependent values, no randomness.

## Implementation notes

- `src/debug.asm` — REPL, commands, disassembler (~2000 lines).
- `src/cpu.asm` — `cpu_step()` refactored from `cpu_run()`; `write_all`
  returns a status code instead of jumping to `die_*` from nested calls
  (OUT → out_i64 → write_all) to keep the host stack unwind safe.
- `src/errors.asm` — exports `error_name()` for the debugger's messages.
- Address parser accepts a token followed by more arguments (space/tab/NUL
  terminated); the input buffer is never modified.

## Known limitations

- No watchpoints, no conditional breakpoints.
- No reverse execution.
- `memory`/`stack` show raw bytes; no type-aware formatting.
- The disassembler covers exactly the 43 frozen opcodes; it does not
  validate (the loader already did).
