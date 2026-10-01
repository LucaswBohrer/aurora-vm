; src/debug.asm — `aurora debug <file>`.
;
; Phase 2: operand validation + host-side file open check, then hands
; off to loader_load_file (real bytecode loader; debugger = phase 4).

default rel

global cmd_debug

extern print_fd
extern cli_error_with_arg
extern host_open_error
extern loader_load_file

%define AT_FDCWD -100
%define SYS_OPENAT 257
%define SYS_CLOSE 3

section .rodata
s_usage:       db "debug: expected exactly one file operand", 0
s_cannot_open: db "debug: cannot open", 0
s_nodebug:     db "aurora: debug: debugger not implemented in this build (phase 2)", 10
s_nodebug_len equ $ - s_nodebug

section .text

; cmd_debug(rdi = argc, rsi = argv) — argv[0] is "debug". Never returns.
cmd_debug:
    push rbx
    cmp rdi, 2
    jne .usage                   ; need exactly argv[1] = file
    mov rbx, [rsi + 8]

    mov eax, SYS_OPENAT
    mov edi, AT_FDCWD
    mov rsi, rbx
    xor edx, edx                ; O_RDONLY
    xor r10d, r10d
    syscall
    cmp rax, 0
    jl .open_fail
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall

    mov rdi, rbx
    xor esi, esi                ; no max_steps in debug mode
    call loader_load_file       ; 0 on success; fatal errors never return
    ; Phase 2 ends here: the program validated and loaded, but the
    ; debugger does not exist yet (phase 4).
    mov edi, 2
    lea rsi, [s_nodebug]
    mov edx, s_nodebug_len
    call print_fd
    mov eax, 60                 ; sys_exit
    mov edi, 3                  ; scaffolding exit code (removed in phase 4)
    syscall
    ud2

.usage:
    lea rdi, [s_usage]
    xor esi, esi
    call cli_error_with_arg     ; exits 2

.open_fail:
    lea rdi, [s_cannot_open]
    mov rsi, rbx
    call host_open_error        ; exits 2

section .note.GNU-stack noalloc noexec nowrite progbits
