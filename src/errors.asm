; src/errors.asm — fatal VM errors and CLI usage errors.
;
; fatal_error(rdi = error id 1..12, rsi = detail cstr or 0):
;   prints "aurora: error: <NAME>[: <detail>]\n" to stderr,
;   exits with code 100 + id. Never returns.
;   Precondition: 1 <= id <= 12 (all call sites use named constants).
;
; cli_error_with_arg(rdi = message cstr, rsi = argument cstr or 0):
;   prints "aurora: <message>[ '<arg>']\n" to stderr, exits 2.
;
; host_open_error(rdi = prefix cstr, rsi = path cstr):
;   prints "aurora: <prefix> '<path>'\n" to stderr, exits 2.
;   Used for host-side file open failures (NOT the guest IO_ERROR).

default rel

global fatal_error
global cli_error_with_arg
global host_open_error

extern print_fd
extern cstr_len

; Error ids (match ARCHITECTURE.md §2.10 and ISA.md).
; Shared with cpu.asm via src/errids.inc (single source of truth).
%include "src/errids.inc"

section .rodata
s_err_prefix: db "aurora: error: "
s_err_prefix_len equ $ - s_err_prefix
s_cli_prefix: db "aurora: "
s_cli_prefix_len equ $ - s_cli_prefix
s_colon_sp: db ": "
s_colon_sp_len equ $ - s_colon_sp
s_quote_sp: db " '"
s_quote_sp_len equ $ - s_quote_sp
s_quote: db "'"
s_nl: db 10

; Error names, indexed by (id - 1).
n01: db "INVALID_OPCODE"
n01_len equ $ - n01
n02: db "INVALID_REGISTER"
n02_len equ $ - n02
n03: db "INVALID_MEMORY_ACCESS"
n03_len equ $ - n03
n04: db "STACK_OVERFLOW"
n04_len equ $ - n04
n05: db "STACK_UNDERFLOW"
n05_len equ $ - n05
n06: db "DIVISION_BY_ZERO"
n06_len equ $ - n06
n07: db "INVALID_PC"
n07_len equ $ - n07
n08: db "INVALID_PROGRAM"
n08_len equ $ - n08
n09: db "INVALID_INSTRUCTION"
n09_len equ $ - n09
n10: db "MAX_STEPS_EXCEEDED"
n10_len equ $ - n10
n11: db "WRITE_TO_CODE"
n11_len equ $ - n11
n12: db "IO_ERROR"
n12_len equ $ - n12

error_names:
    dq n01, n01_len
    dq n02, n02_len
    dq n03, n03_len
    dq n04, n04_len
    dq n05, n05_len
    dq n06, n06_len
    dq n07, n07_len
    dq n08, n08_len
    dq n09, n09_len
    dq n10, n10_len
    dq n11, n11_len
    dq n12, n12_len

section .text

fatal_error:
    push rbx
    push r12
    mov ebx, edi                ; id
    mov r12, rsi                ; detail (or 0)

    ; "aurora: error: "
    mov edi, 2
    lea rsi, [s_err_prefix]
    mov edx, s_err_prefix_len
    call print_fd

    ; error name from table
    mov eax, ebx
    dec eax                     ; 0-based
    shl rax, 4                  ; 16 bytes per entry
    lea rcx, [error_names]
    mov rsi, [rcx + rax]
    mov rdx, [rcx + rax + 8]
    mov edi, 2
    call print_fd

    ; optional ": <detail>"
    test r12, r12
    jz .no_detail
    mov edi, 2
    lea rsi, [s_colon_sp]
    mov edx, s_colon_sp_len
    call print_fd
    mov rdi, r12
    call cstr_len
    mov rdx, rax
    mov rsi, r12
    mov edi, 2
    call print_fd
.no_detail:
    ; "\n"
    mov edi, 2
    lea rsi, [s_nl]
    mov edx, 1
    call print_fd

    ; exit(100 + id)
    mov eax, 60                 ; sys_exit
    lea edi, [rbx + 100]
    syscall
    ud2                         ; unreachable

cli_error_with_arg:
    push rbx
    push r12
    mov rbx, rdi                ; message
    mov r12, rsi                ; arg or 0

    ; "aurora: "
    mov edi, 2
    lea rsi, [s_cli_prefix]
    mov edx, s_cli_prefix_len
    call print_fd

    ; message
    mov rdi, rbx
    call cstr_len
    mov rdx, rax
    mov rsi, rbx
    mov edi, 2
    call print_fd

    ; optional " '<arg>'"
    test r12, r12
    jz .no_arg
    mov edi, 2
    lea rsi, [s_quote_sp]
    mov edx, s_quote_sp_len
    call print_fd
    mov rdi, r12
    call cstr_len
    mov rdx, rax
    mov rsi, r12
    mov edi, 2
    call print_fd
    mov edi, 2
    lea rsi, [s_quote]
    mov edx, 1
    call print_fd
.no_arg:
    mov edi, 2
    lea rsi, [s_nl]
    mov edx, 1
    call print_fd

    mov eax, 60                 ; sys_exit
    mov edi, 2
    syscall
    ud2

host_open_error:
    ; rdi = prefix cstr (e.g. "run: cannot open"), rsi = path cstr
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov edi, 2
    lea rsi, [s_cli_prefix]
    mov edx, s_cli_prefix_len
    call print_fd

    mov rdi, rbx
    call cstr_len
    mov rdx, rax
    mov rsi, rbx
    mov edi, 2
    call print_fd

    mov edi, 2
    lea rsi, [s_quote_sp]
    mov edx, s_quote_sp_len
    call print_fd

    mov rdi, r12
    call cstr_len
    mov rdx, rax
    mov rsi, r12
    mov edi, 2
    call print_fd

    mov edi, 2
    lea rsi, [s_quote]
    mov edx, 1
    call print_fd

    mov edi, 2
    lea rsi, [s_nl]
    mov edx, 1
    call print_fd

    mov eax, 60
    mov edi, 2
    syscall
    ud2

section .note.GNU-stack noalloc noexec nowrite progbits
