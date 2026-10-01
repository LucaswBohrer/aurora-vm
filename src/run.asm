; src/run.asm — `aurora run <file> [--max-steps N]`.
;
; Full argument parsing + host-side file open check, then hands off to
; loader_load_file (real bytecode loader, phase 2), which validates the
; program and initializes the VM state. On success, cpu_run (phase 3)
; executes it and never returns: HALT exits with R0 & 0xFF, fatal errors
; exit with 100 + error id (D22).

default rel

global cmd_run

extern streq
extern starts_with
extern parse_u64
extern print_fd
extern cli_error_with_arg
extern host_open_error
extern loader_load_file
extern cpu_run

%define AT_FDCWD -100
%define SYS_OPENAT 257
%define SYS_CLOSE 3

section .rodata
s_missing_file:  db "run: missing file operand", 0
s_unknown_opt:   db "run: unknown option", 0
s_unexpected:    db "run: unexpected operand", 0
s_noval:         db "run: --max-steps requires a value", 0
s_badval:        db "run: invalid value for --max-steps", 0
s_cannot_open:   db "run: cannot open", 0
s_maxsteps:      db "--max-steps", 0
s_maxsteps_eq:   db "--max-steps=", 0
s_maxsteps_eq_len equ 12

section .text

; cmd_run(rdi = argc, rsi = argv) — argv[0] is "run". Never returns.
cmd_run:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rdi                 ; r14 = argc
    mov r15, rsi                 ; r15 = argv

    cmp r14, 1
    jle .missing_file            ; need at least argv[1] = file

    mov rbx, [r15 + 8]           ; rbx = file path
    mov r12, 100000000           ; r12 = max_steps (default)
    mov r13, 2                   ; r13 = i (first option index)

.loop:
    cmp r13, r14
    jge .args_done
    mov rax, [r15 + r13*8]       ; rax = arg

    mov rdi, rax
    lea rsi, [s_maxsteps]
    call streq
    test rax, rax
    jnz .maxsteps_next

    mov rdi, [r15 + r13*8]
    lea rsi, [s_maxsteps_eq]
    call starts_with
    test rax, rax
    jnz .maxsteps_eq

    mov rax, [r15 + r13*8]
    cmp byte [rax], '-'
    je .unknown_option

    ; unexpected positional operand
    lea rdi, [s_unexpected]
    mov rsi, rax
    call cli_error_with_arg      ; exits 2

.maxsteps_next:                  ; "--max-steps" <value>
    lea rax, [r13 + 1]
    cmp rax, r14
    jge .noval
    mov rsi, [r15 + rax*8]
    call parse_u64
    test rdx, rdx
    jnz .badval
    mov r12, rax
    add r13, 2
    jmp .loop

.maxsteps_eq:                    ; "--max-steps=<value>"
    mov rax, [r15 + r13*8]
    lea rsi, [rax + s_maxsteps_eq_len]
    call parse_u64
    test rdx, rdx
    jnz .badval
    mov r12, rax
    inc r13
    jmp .loop

.missing_file:
    lea rdi, [s_missing_file]
    xor esi, esi
    call cli_error_with_arg

.unknown_option:
    mov rax, [r15 + r13*8]
    lea rdi, [s_unknown_opt]
    mov rsi, rax
    call cli_error_with_arg

.noval:
    lea rdi, [s_noval]
    xor esi, esi
    call cli_error_with_arg

.badval:
    lea rdi, [s_badval]
    xor esi, esi
    call cli_error_with_arg

.args_done:
    ; Host-side readability check. The loader (phase 2) reopens the file.
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
    syscall                     ; ignore close errors here

    mov rdi, rbx                ; path
    call loader_load_file       ; 0 on success; fatal errors never return
    mov rdi, r12                ; max_steps (0 = unlimited per ISA §7)
    call cpu_run                ; never returns: HALT exits, errors are fatal
    ud2

.open_fail:
    lea rdi, [s_cannot_open]
    mov rsi, rbx
    call host_open_error        ; exits 2

section .note.GNU-stack noalloc noexec nowrite progbits
