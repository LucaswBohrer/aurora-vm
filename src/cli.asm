; src/cli.asm — `aurora --help` and `aurora --version`.

default rel

global cmd_help
global cmd_version

extern print_cstr_stdout

section .rodata
help_text:
    db "Usage: aurora <command> [options]", 10
    db 10
    db "Commands:", 10
    db "  run <file> [--max-steps N]   Execute an AURORA bytecode program (.bin)", 10
    db "  debug <file>                 Debug a program interactively", 10
    db "  --help, -h                   Print this help and exit", 10
    db "  --version, -V                Print version and exit", 10
    db 10
    db "Run options:", 10
    db "  --max-steps N                Stop after N guest instructions", 10
    db "                               (default 100000000, 0 = unlimited).", 10
    db "                               Exceeding it raises MAX_STEPS_EXCEEDED.", 10
    db 10
    db "Exit codes:", 10
    db "  0                            success, --help, --version", 10
    db "  2                            command-line usage error", 10
    db "  100 + <error id>             fatal VM error (e.g. 106 = DIVISION_BY_ZERO)", 10
    db 10
    db "The VM core is 100% x86-64 Assembly; the assembler (tools/aurora-asm)", 10
    db "is separate Python 3 tooling. The ISA is frozen: 43 opcodes, see", 10
    db "docs/ISA.md.", 10
    db 0

version_text:
    db "aurora 1.0.0 (phase 1: CLI skeleton + error reporting)", 10, 0

section .text

; cmd_help() — print help to stdout, exit 0.
cmd_help:
    lea rdi, [help_text]
    call print_cstr_stdout
    mov eax, 60                 ; sys_exit
    xor edi, edi
    syscall
    ud2

; cmd_version() — print version to stdout, exit 0.
cmd_version:
    lea rdi, [version_text]
    call print_cstr_stdout
    mov eax, 60
    xor edi, edi
    syscall
    ud2

section .note.GNU-stack noalloc noexec nowrite progbits
