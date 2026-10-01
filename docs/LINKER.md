# AURORA VM — Linker

**Status:** phase 7 (normative for `tools/aurora-ld`).
**Scope:** static linking of AURORA Object Format v1 files
(`docs/OBJECT_FORMAT.md`) into AURORA executable bytecode v1
(`docs/BYTECODE.md`). The linker is a host tool; the CPU, the loader
and the debugger never see object files.

---

## 1. Pipeline

```text
module_a.asm ──aurora-asm -c──▶ module_a.o ──┐
module_b.asm ──aurora-asm -c──▶ module_b.o ──┼──▶ aurora-ld ──▶ program.bin
runtime.asm  ──aurora-asm -c──▶ runtime.o  ──┘        │
                                                     ▼
                                          bytecode v1 (26-byte header,
                                          entry = 0, [code][data])
```

Stages, in order:

1. **Parse & validate** every `.o` strictly (`docs/OBJECT_FORMAT.md`
   §3–§5). Any structural violation is a link error (exit 1); the
   linker never trusts an object file.
2. **Symbol resolution** — build the global symbol table (§3).
3. **Layout** — assign final base addresses (§4).
4. **Relocation** — patch every imm32 field per `docs/OBJECT_FORMAT.md`
   §5, with range validation (§5).
5. **Emit** — write the executable v1 header + code + data.

No stage may depend on hash iteration order, filesystem order,
timestamps, host addresses, or randomness. Object files are processed
strictly in command-line order.

---

## 2. Entry point

The executable v1 header carries an `entry` u32 (`docs/BYTECODE.md`).
The linker always writes **`entry = 0`**, exactly as `tools/aurora-asm`
does today.

**Entry policy (normative):** the object listed **first** on the link
line provides the entry code: its `.code` is placed first, and since
`entry = 0`, execution starts at its first instruction.

Consequences:

- To link `main.o` with `runtime.o`, write
  `aurora-ld main.o runtime.o -o program.bin` — never the reverse.
- There is no `_start`/`main`/magic-entry symbol in v1. Nothing in the
  executable header changed for the linker (no STOP needed; see §15 of
  the phase-7 authorization: no conflict with `entry = 0` exists).

---

## 3. Symbol resolution

For each object, in link order:

1. For every `LOCAL` symbol: record it under the object's private
   namespace. Locals never participate in cross-module resolution and
   never conflict across objects.
2. For every `GLOBAL` symbol: if the name is already defined by a
   previously linked object → **link error** "duplicate global symbol",
   naming the symbol, the object that defined it first, and the object
   attempting the second definition.
3. For every `UNDEFINED` symbol: record a reference.

After all objects are scanned: every `UNDEFINED` symbol must have
exactly one matching `GLOBAL` definition. Any remaining undefined
symbol → **link error** "undefined symbol", naming the symbol and the
object(s) that reference it. Undefined symbols are never resolved to
zero.

A `GLOBAL` defined in object A satisfies references from *any*
object, including object A itself.

Duplicate definitions *within* a single object are rejected by the
object validator before resolution even starts.

---

## 4. Layout

Let the objects be `O_0 … O_{n-1}` in link order, with sizes
`cs_i` (code) and `ds_i` (data):

```text
code_base[i] = Σ cs_j        for j < i
data_base[i] = total_code + Σ ds_j   for j < i
total_code   = Σ cs_i
total_data   = Σ ds_i
```

The final image is `[code of all objects in order][data of all objects
in order]`, i.e. the same two-segment model the assembler emits today
(`docs/ASSEMBLER.md` §5) — just with several modules concatenated per
segment.

### Link-time layout validation (all link errors)

- `total_code > 0` (the loader requires a non-empty code segment).
- `total_code % 8 == 0` (structural; guaranteed by per-object checks).
- `total_code + total_data ≤ 0xF000` (the guest code+data region; the
  stack `0xF000–0xFFFF` is untouched, exactly as in `docs/BYTECODE.md`
  §5).
- Every computed base and end is checked wraparound-safe
  (`base + size` must not overflow u32/u64 and must be `< 0x10000`).

Link order is semantically significant (§2, §9) and always honored
exactly as given.

---

## 5. Relocation

For each relocation entry, in the order stored in each object (which
is code order — deterministic):

1. Resolve the referenced symbol to its final absolute address `S`
   (`docs/OBJECT_FORMAT.md` §5).
2. Apply the type-specific validation from `docs/OBJECT_FORMAT.md`
   §5 (range, section, alignment).
3. Patch the 4 bytes at `code_base[obj] + offset` (little-endian).

Any violation is a **link error** — the linker never truncates, never
wraps, and never emits a partially-resolved image. In particular:

- a `CODE32` relocation to a DATA symbol → link error;
- a `MEM32` relocation whose symbol address exceeds `0x10000 - 8` →
  link error;
- a relocation index outside the symbol table → link error
  (caught at validation).

Additionally, after all patches, the linker validates **every**
class-J instruction in the final image (`CALL`, `JMP`, `Jcc`):
target `< total_code`, target `% 8 == 0`. This mirrors the loader's
own validation and guarantees the linker never emits a `.bin` the
loader would reject. (In `-c` mode the assembler deliberately skips the
`< code_size` check for numeric jump targets, because the final code
size is unknowable at assembly time.)

---

## 6. Guest/host boundary

The linker knows **symbols and relocations only**. It knows nothing
about opcodes, the CPU, the runtime ABI, or `svc_*` semantics. The
runtime is just another object file: `svc_exit`, `svc_write`,
`svc_read` are ordinary global symbols resolved by name (§3, D26
intact).

The linker is a host tool: its exit codes are `0` (success),
`1` (link/semantic error), `2` (CLI/file error) — the same convention
as `tools/aurora-asm` — never VM fatal error codes.

---

## 7. CLI

```text
tools/aurora-ld a.o b.o -o program.bin
```

| option | meaning |
|--------|---------|
| `-o FILE` | output `.bin` path (required; multiple `-o` → error) |
| `--help` | usage; exit 0 |
| `--version` | `aurora-ld <version>`; exit 0 |

Behavior:

- With no `-o`, the output name is derived from the first input:
  `foo.o` → `foo.bin` (same directory rule as `aurora-asm`).
- Input files are read in the order given; order is significant (§2).
- Exit `0` on success; `1` on link error (bad object, duplicate
  global, undefined symbol, relocation/overflow failure); `2` on
  CLI/file errors (missing file, unknown option, unreadable input).
- Errors are single-line `aurora-ld: <what>: <detail>` messages on
  stderr. No traceback on normal errors.

---

## 8. Errors (normative list)

| # | condition | exit |
|---|-----------|------|
| L1 | unreadable/missing input file | 2 |
| L2 | unknown CLI option / missing `-o` argument / no inputs | 2 |
| L3 | object fails structural validation (`docs/OBJECT_FORMAT.md` §3–§5) | 1 |
| L4 | duplicate global symbol | 1 |
| L5 | undefined symbol at end of resolution | 1 |
| L6 | relocation references nonexistent symbol | 1 |
| L7 | relocation type/section mismatch (`CODE32` to data, …) | 1 |
| L8 | relocation value out of representable range | 1 |
| L9 | layout overflow (`code+data > 0xF000`, wraparound, empty code) | 1 |
| L10 | final class-J target invalid (not `< total_code`, misaligned) | 1 |

---

## 9. Determinism

Same objects + same order + same options → byte-identical `.bin`
(`sha256` equality). Determinism follows from:

- strict command-line processing order (no sorting, no hashing into
  layout decisions);
- fixed symbol/relocation emission order in `.o` files
  (`docs/OBJECT_FORMAT.md` §8);
- no timestamps, no randomness, no absolute host paths in the output.

Changing the link order legitimately changes the layout (§2); that is
documented behavior, tested explicitly (`order_matters` test).

---

## 10. Examples

```bash
# two modules
python3 tools/aurora-asm -c examples/linker/main.asm    -o /tmp/main.o
python3 tools/aurora-asm -c examples/linker/math.asm    -o /tmp/math.o
python3 tools/aurora-ld /tmp/main.o /tmp/math.o -o /tmp/math_demo.bin
./build/aurora run /tmp/math_demo.bin

# runtime as a reusable module (replaces the phase-6 cat trick)
python3 tools/aurora-asm -c runtime/aurora_rt.asm       -o /tmp/rt.o
python3 tools/aurora-asm -c examples/linker/echo_main.asm -o /tmp/echo.o
python3 tools/aurora-ld /tmp/echo.o /tmp/rt.o -o /tmp/echo.bin
echo -n "hi" | ./build/aurora run /tmp/echo.bin
```

See `examples/linker/README.md` for the full walkthrough.

---

## 11. Testing

`tests/linker/run_linker_tests.py` (L9 in `docs/TESTING.md`) covers:
object creation/parsing/validation, local/global/undefined symbols,
duplicate globals, all three relocation types and their range checks,
code/data layout, entry=0 policy, real runtime linking, real
multi-module execution on the VM, malformed objects, CLI behavior,
determinism (`sha256` equality), link-order significance, and the
phase-5 debugger driving a linked binary. Golden `.o` files are built
by hand with `struct` — independent of both the assembler and the
linker (`docs/OBJECT_FORMAT.md` §10).
