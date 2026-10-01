# AURORA VM — build
NASM      := nasm
LD        := ld
NASMFLAGS := -f elf64 -g -w+all

SRC := src/main.asm src/util.asm src/errors.asm src/cli.asm \
       src/run.asm src/debug.asm src/loader.asm src/cpu.asm
OBJ := $(SRC:src/%.asm=build/obj/%.o)
BIN := build/aurora

all: $(BIN)

$(BIN): $(OBJ)
	mkdir -p build
	$(LD) -o $@ $(OBJ)

build/obj/%.o: src/%.asm
	mkdir -p build/obj
	$(NASM) $(NASMFLAGS) $< -o $@

# loader.o and cpu.o also depend on the shared includes.
build/obj/loader.o: src/vm.inc src/errids.inc
build/obj/cpu.o: src/vm.inc src/errids.inc
build/obj/errors.o: src/errids.inc

test: $(BIN)
	tests/phase1/run_cli_tests.sh
	tests/byte/run_l3_tests.sh
	python3 tests/byte/audit_opcode_fields.py
	python3 tests/exec/test_cpu_programs.py
	python3 tests/termination/run_termination_tests.py

fuzz:
	@echo "fuzzing is specified for a later phase (see docs/TESTING.md)"

clean:
	rm -rf build

.PHONY: all test fuzz clean
