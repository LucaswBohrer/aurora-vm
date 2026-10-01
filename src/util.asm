; src/util.asm — small string/IO helpers used across the codebase.
;
; All functions follow the internal convention (System V AMD64 args,
; callee preserves rbx, rbp, r12-r15).

default rel

global print_fd
global cstr_len
global print_cstr_stdout
global print_cstr_stderr
global streq
global starts_with
global parse_u64

section .text

; print_fd(rdi=fd, rsi=buf, rdx=len) — write all bytes, loop on partial.
print_fd:
    test rdx, rdx
    jz .done
.loop:
    mov rax, 1                  ; sys_write
    syscall                     ; clobbers rcx, r11
    test rax, rax
    jle .done                   ; error (or 0): give up silently
    sub rdx, rax
    add rsi, rax
    test rdx, rdx
    jnz .loop
.done:
    ret

; cstr_len(rdi=cstr) -> rax = length excluding NUL.
cstr_len:
    xor eax, eax
.loop:
    cmp byte [rdi + rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    ret

; print_cstr_stdout(rdi=cstr) / print_cstr_stderr(rdi=cstr)
print_cstr_stdout:
    push rdi
    call cstr_len               ; rax = len (rdi preserved)
    mov rdx, rax
    pop rsi                     ; rsi = cstr
    mov edi, 1
    jmp print_fd                ; tail call

print_cstr_stderr:
    push rdi
    call cstr_len
    mov rdx, rax
    pop rsi
    mov edi, 2
    jmp print_fd

; streq(rdi=a, rsi=b) -> rax = 1 if equal NUL-terminated strings, else 0.
streq:
.loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .no
    test al, al
    jz .yes
    inc rdi
    inc rsi
    jmp .loop
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; starts_with(rdi=haystack, rsi=prefix) -> rax = 1 if haystack starts
; with prefix, else 0.
starts_with:
.loop:
    mov cl, [rsi]
    test cl, cl
    jz .yes
    mov al, [rdi]
    cmp al, cl
    jne .no
    inc rdi
    inc rsi
    jmp .loop
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; parse_u64(rsi=cstr) -> rax = value, rdx = 0 ok / 1 error.
; Accepts [0-9]+ only (no sign, no whitespace). Rejects empty strings,
; non-digits and values > 2^64-1 (overflow-checked before multiply).
parse_u64:
    xor eax, eax                ; accumulator
    movzx r8d, byte [rsi]
    test r8b, r8b
    jz .err                     ; empty string
.loop:
    movzx r8d, byte [rsi]
    test r8b, r8b
    jz .ok
    sub r8b, '0'
    cmp r8b, 9
    ja .err
    ; overflow guard: 2^64-1 = 18446744073709551615;
    ; (2^64-1)/10 = 1844674407370955161 rem 5.
    ; NOTE: the constant does not fit in a sign-extended imm32, so it is
    ; loaded into a register first (a direct `cmp rax, imm` would compare
    ; against the truncated value — nasm warns [-w+number-overflow]).
    mov r9, 1844674407370955161
    cmp rax, r9
    ja .err
    jb .mul
    cmp r8b, 5
    ja .err
.mul:
    imul rax, rax, 10           ; cannot overflow after the guard above
    add rax, r8
    inc rsi
    jmp .loop
.ok:
    xor edx, edx
    ret
.err:
    mov edx, 1
    xor eax, eax
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
