; src/main.asm — AURORA VM program entry and top-level CLI dispatch.
;
; Phase 1: CLI skeleton + error reporting.
;
; Internal calling convention (whole codebase):
;   System V AMD64 for internal calls: args in rdi, rsi, rdx, rcx, r8, r9;
;   return value in rax. Callee preserves rbx, rbp, r12-r15; all other
;   registers are clobbered. Syscalls: Linux x86-64 directly (no libc).
;
; Every cmd_* function below terminates the process (exit syscall) and
; never returns. `ud2` guards catch any accidental return during dev.

default rel

global _start

extern streq
extern cmd_help
extern cmd_version
extern cmd_run
extern cmd_debug
extern cli_error_with_arg

section .rodata
s_run:        db "run", 0
s_debug:      db "debug", 0
s_help:       db "--help", 0
s_help_s:     db "-h", 0
s_version:    db "--version", 0
s_version_s:  db "-V", 0
s_unknown:    db "unknown command", 0

section .text

_start:
    xor ebp, ebp               ; terminate frame chain (gdb/backtrace hygiene)
    pop r12                    ; r12 = argc
    mov r13, rsp               ; r13 = argv
    and rsp, -16               ; keep stack 16-aligned for calls

    cmp r12, 2
    jl .do_help                ; bare `aurora` -> help, exit 0

    mov rbx, [r13 + 8]         ; rbx = argv[1]

    mov rdi, rbx
    lea rsi, [s_run]
    call streq
    test rax, rax
    jnz .do_run

    mov rdi, rbx
    lea rsi, [s_debug]
    call streq
    test rax, rax
    jnz .do_debug

    mov rdi, rbx
    lea rsi, [s_help]
    call streq
    test rax, rax
    jnz .do_help

    mov rdi, rbx
    lea rsi, [s_help_s]
    call streq
    test rax, rax
    jnz .do_help

    mov rdi, rbx
    lea rsi, [s_version]
    call streq
    test rax, rax
    jnz .do_version

    mov rdi, rbx
    lea rsi, [s_version_s]
    call streq
    test rax, rax
    jnz .do_version

    ; unknown command -> usage error, exit 2
    lea rdi, [s_unknown]
    mov rsi, rbx
    call cli_error_with_arg
    ud2

.do_help:
    call cmd_help               ; exits 0
    ud2

.do_version:
    call cmd_version            ; exits 0
    ud2

.do_run:
    lea rdi, [r12 - 1]          ; remaining argc (argv[0] = "run")
    lea rsi, [r13 + 8]          ; remaining argv
    call cmd_run
    ud2

.do_debug:
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call cmd_debug
    ud2

section .note.GNU-stack noalloc noexec nowrite progbits
