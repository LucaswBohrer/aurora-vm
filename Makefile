# AURORA VM — build
NASM      := nasm
LD        := ld
NASMFLAGS := -f elf64 -g -w+all

SRC := src/main.asm src/util.asm src/errors.asm src/cli.asm \
       src/run.asm src/debug.asm src/loader.asm
OBJ := $(SRC:src/%.asm=build/obj/%.o)
BIN := build/aurora

all: $(BIN)

$(BIN): $(OBJ)
	mkdir -p build
	$(LD) -o $@ $(OBJ)

build/obj/%.o: src/%.asm
	mkdir -p build/obj
	$(NASM) $(NASMFLAGS) $< -o $@

test: $(BIN)
	tests/phase1/run_cli_tests.sh

fuzz:
	@echo "fuzzing is specified for a later phase (see docs/TESTING.md)"

clean:
	rm -rf build

.PHONY: all test fuzz clean
