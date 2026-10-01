; src/loader.asm — bytecode loader.
;
; PHASE 1 STUB. The real loader (header + instruction-slot validation per
; docs/BYTECODE.md) is implemented in phase 2 and replaces this stub.
;
; Interface (stable across phases):
;   loader_load_file(rdi = path cstr, rsi = max_steps u64)
;     -> on success: continues into execution (phase 2+)
;     -> on invalid input: fatal_error(INVALID_PROGRAM / INVALID_INSTRUCTION)

default rel

global loader_load_file

extern print_fd

section .rodata
s_stub: db "aurora: loader: not implemented in this build (phase 1)", 10
s_stub_len equ $ - s_stub

section .text

loader_load_file:
    ; rdi = path (unused in stub), rsi = max_steps (unused in stub)
    mov edi, 2
    lea rsi, [s_stub]
    mov edx, s_stub_len
    call print_fd
    mov eax, 60                 ; sys_exit
    mov edi, 3                  ; scaffolding exit code (phase 1 only)
    syscall
    ud2

section .note.GNU-stack noalloc noexec nowrite progbits
