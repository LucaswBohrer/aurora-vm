# Linker examples

Multi-module AURORA programs, linked with `tools/aurora-ld`
(docs/LINKER.md). Each `.asm` file is assembled separately to a
relocatable object (`.o`) and then linked into one bytecode v1
executable (`.bin`).

## math_demo — cross-module calls and data

`main.asm` (entry) + `math.asm` (library):

```bash
python3 tools/aurora-asm -c examples/linker/main.asm -o /tmp/main.o
python3 tools/aurora-asm -c examples/linker/math.asm  -o /tmp/math.o
python3 tools/aurora-ld /tmp/main.o /tmp/math.o -o /tmp/math_demo.bin
./build/aurora run /tmp/math_demo.bin
```

Expected stdout:

```text
50
21
5
```

Exit code 0. Demonstrates: `CALL` to a function in another module
(`CODE32` relocation), `LOAD [factor]` reading data from another
module (`MEM32` relocation), a `LOCAL` symbol (`helper_local`) that
never leaks across modules, and the entry policy (the entry module
comes first because the linker writes `entry = 0`).

## echo — the runtime as a linked module

`echo_main.asm` (entry) + `runtime/aurora_rt.asm` (ABI v1 library).
This replaces the phase-6 concatenation recipe
(`cat prog.asm runtime/aurora_rt.asm`) with real linking:

```bash
python3 tools/aurora-asm -c examples/linker/echo_main.asm -o /tmp/echo.o
python3 tools/aurora-asm -c runtime/aurora_rt.asm          -o /tmp/rt.o
python3 tools/aurora-ld /tmp/echo.o /tmp/rt.o -o /tmp/echo.bin
echo -n "hi" | ./build/aurora run /tmp/echo.bin
```

Expected: stdout `hi`, exit code 0. The services `svc_read`,
`svc_write`, `svc_exit` are resolved as ordinary global symbols; the
linker attaches no special meaning to them (D26).
