; src/loader.asm — bytecode loader (phase 2).
;
; loader_load_file(rdi = path cstr, rsi = max_steps u64) -> rax = 0 on success.
;
; Validates the file per docs/BYTECODE.md §4 (normative order, steps 1-9),
; loads code/data into the 64 KiB virtual memory image, zeroes the rest, and
; initializes registers (PC = entry, SP = FP = 0x10000, FLAGS = 0, R[*] = 0).
; On invalid input: fatal_error(INVALID_PROGRAM / INVALID_INSTRUCTION);
; never returns. max_steps is accepted but unused until the CPU exists
; (phase 3).
;
; The input file is treated as untrusted: every size and address that comes
; from the header is range-checked before use, and no address arithmetic is
; performed in a form that can wrap around u64 (all sums are computed in
; 64-bit registers where the operands are bounded well below 2^64, and the
; "address <= 0x10000 - size" bound is expressed with a constant limit).

default rel
%include "src/vm.inc"

global loader_load_file
global vm_regs
global vm_mem

extern fatal_error
extern host_open_error
extern cstr_len

%define ERR_INVALID_PROGRAM      8
%define ERR_INVALID_INSTRUCTION  9

%define SYS_READ   0
%define SYS_CLOSE  3
%define SYS_OPENAT 257
%define AT_FDCWD   -100

%define FILE_BUF_SIZE 65536
; Largest possible well-formed file: 0x1A + 0xF000 (BYTECODE.md §3).
%define MAX_VALID_FILE (0x1A + 0xF000)

section .bss
vm_regs:    resb VM_REGS_SIZE
vm_mem:     resb VM_MEM_SIZE
file_buf:   resb FILE_BUF_SIZE
detail_buf: resb 256

section .rodata
magic_expected: db 0x41, 0x55, 0x52, 0x4F, 0x52, 0x41, 0x01, 0x00

; Opcode -> required operand class (indexed by opcode 0x00-0x2A).
; Classes: 0=N 1=R 2=I 3=r 4=M 5=J. Matches docs/ISA.md §6.
class_table:
    db 0, 0                         ; 0x00 NOP, 0x01 HALT
    db 1, 2, 1, 2, 1, 2, 1, 2       ; 0x02-0x09 MOV/ADD/SUB/MUL
    db 1, 2                         ; 0x0A-0x0B DIV
    db 3, 3                         ; 0x0C-0x0D INC/DEC
    db 1, 2, 1, 2, 1, 2, 3          ; 0x0E-0x14 AND/OR/XOR/NOT
    db 1, 2                         ; 0x15-0x16 CMP
    db 4, 1, 4, 1, 1, 1             ; 0x17-0x1C LOAD/STORE/LOADB/STOREB
    db 3, 3                         ; 0x1D-0x1E PUSH/POP
    db 5, 0                         ; 0x1F CALL, 0x20 RET
    db 5, 5, 5, 5, 5, 5, 5          ; 0x21-0x27 JMP/Jcc
    db 3, 3, 3                      ; 0x28-0x2A OUT/OUTC/IN

s_trunc_hdr:    db "truncated header", 0
s_bad_magic:    db "bad magic", 0
s_bad_version:  db "unsupported version", 0
s_bad_reserved: db "reserved field nonzero", 0
s_bad_codesize: db "invalid code size", 0
s_trunc_prog:   db "truncated program", 0
s_trailing:     db "trailing data", 0
s_bad_entry:    db "invalid entry point", 0
s_bad_layout:   db "invalid memory layout", 0
s_too_large:    db "file too large", 0
s_cannot_read:  db "loader: cannot read file", 0
s_cannot_open_host: db "loader: cannot open file", 0

; Dynamic detail fragments (detail_buf builder below).
s_bad_opcode:   db "bad opcode ", 0
s_bad_class:    db "bad class ", 0
s_for_opcode:   db " for opcode ", 0
s_bad_reg:      db "bad register field at code offset ", 0
s_nonzero_imm:  db "nonzero imm32 at code offset ", 0
s_bad_target:   db "bad jump target ", 0
s_bad_addr:     db "bad memory address ", 0
s_at_offset:    db " at code offset ", 0

section .text

; ---- detail_buf builder (NUL-terminated cstr for fatal_error) ----
; detail_reset() -> rax = write position (start of detail_buf).
detail_reset:
    lea rax, [detail_buf]
    ret

; detail_cstr(rdi = pos, rsi = cstr) -> rax = new pos (before NUL).
detail_cstr:
    push rbx
    mov rbx, rdi
.copy:
    mov al, [rsi]
    mov [rbx], al
    inc rsi
    inc rbx
    test al, al
    jnz .copy
    lea rax, [rbx - 1]
    pop rbx
    ret

; detail_hex(rdi = pos, rsi = u64 value) -> rax = new pos.
; Appends "0x" followed by the minimal lowercase hex digits (at least one).
detail_hex:
    mov byte [rdi], '0'
    mov byte [rdi + 1], 'x'
    lea rdi, [rdi + 2]
    mov rax, rsi
    mov ecx, 60
.skip_zero:
    test ecx, ecx
    jz .emit
    mov rdx, rax
    shr rdx, cl
    and edx, 0xF
    test edx, edx
    jnz .emit
    sub ecx, 4
    jmp .skip_zero
.emit:
.digit:
    mov rdx, rax
    shr rdx, cl
    and edx, 0xF
    cmp dl, 9
    ja .hex_letter
    add dl, '0'
    jmp .store
.hex_letter:
    add dl, 'a' - 10
.store:
    mov [rdi], dl
    inc rdi
    sub ecx, 4
    jnb .digit
    mov rax, rdi
    ret

; detail_done(rdi = pos) -> rax = detail_buf (NUL-terminated cstr).
detail_done:
    mov byte [rdi], 0
    lea rax, [detail_buf]
    ret

; ---- loader ----
loader_load_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                ; rbx = path cstr (callee-saved)
    ; rsi = max_steps: accepted, unused until phase 3.

    ; Open the file ourselves (run.asm's pre-check is only a UX nicety).
    mov eax, SYS_OPENAT
    mov edi, AT_FDCWD
    mov rsi, rbx
    xor edx, edx                ; O_RDONLY
    xor r10d, r10d
    syscall
    cmp rax, 0
    jl .open_fail
    mov r12d, eax               ; r12d = fd

    ; Read the whole file into file_buf (loop: regular files, pipes, ...).
    xor r13d, r13d              ; r13 = total bytes read
.read_loop:
    mov eax, SYS_READ
    mov edi, r12d
    lea rsi, [file_buf + r13]
    mov rdx, FILE_BUF_SIZE
    sub rdx, r13                ; remaining; r13 <= FILE_BUF_SIZE, no wrap
    jz .too_large               ; buffer full without EOF: larger than any
                                ; well-formed file (MAX_VALID_FILE < 64 KiB)
    syscall
    test rax, rax
    jz .read_done               ; EOF
    js .read_fail
    add r13, rax
    jmp .read_loop
.read_done:
    mov eax, SYS_CLOSE
    mov edi, r12d
    syscall                     ; ignore close errors

    ; ---- Step 1: file_size >= 0x1A ----
    cmp r13, 0x1A
    jb .truncated_header

    ; ---- Step 2: magic ----
    mov rax, [file_buf]
    mov rcx, [magic_expected]
    cmp rax, rcx
    jne .bad_magic

    ; ---- Step 3: version == 0x0001 ----
    movzx eax, word [file_buf + 8]
    cmp eax, 1
    jne .bad_version

    ; ---- Step 4: reserved == 0 ----
    mov eax, [file_buf + 0x16]
    test eax, eax
    jnz .bad_reserved

    ; ---- Step 5: code_size > 0 and code_size % 8 == 0 ----
    mov eax, [file_buf + 0x0A]
    mov r14, rax                ; r14 = code_size (u64)
    test r14, r14
    jz .bad_code_size
    test r14b, 7
    jnz .bad_code_size

    mov eax, [file_buf + 0x12]
    mov r15, rax                ; r15 = data_size (u64)

    ; ---- Step 6: file_size == 0x1A + code_size + data_size ----
    ; 64-bit sum of u32 fields: cannot wrap (each < 2^32).
    mov rax, 0x1A
    add rax, r14
    add rax, r15
    cmp r13, rax
    jb .truncated_program
    ja .trailing_data

    ; ---- Step 7: entry < code_size and entry % 8 == 0 ----
    mov eax, [file_buf + 0x0E]
    mov r10, rax                ; r10 = entry (u64)
    cmp r10, r14
    jae .bad_entry
    test r10b, 7
    jnz .bad_entry

    ; ---- Step 8: code_size + data_size <= 0xF000 ----
    mov rax, r14
    add rax, r15                ; < 2^33, no wrap
    cmp rax, 0xF000
    ja .bad_layout

    ; ---- Step 9: per-slot validation ----
    ; r11 = code offset, r12 = code base (file_buf + 0x1A), r14 = code_size.
    xor r11d, r11d
    lea r12, [file_buf + 0x1A]
.scan:
    cmp r11, r14
    jae .scan_done
    movzx eax, byte [r12 + r11]     ; eax = opcode
    cmp eax, 0x2A
    ja .bad_opcode
    movzx ecx, byte [class_table + rax] ; ecx = required class
    movzx edx, byte [r12 + r11 + 3]     ; edx = actual class
    cmp edx, ecx
    jne .bad_class
    movzx esi, byte [r12 + r11 + 1]     ; esi = dst
    movzx edi, byte [r12 + r11 + 2]     ; edi = src
    mov r8d, [r12 + r11 + 4]            ; r8 = imm32 (zero-extended)

    cmp ecx, 0
    je .cls_n
    cmp ecx, 1
    je .cls_r
    cmp ecx, 2
    je .cls_i
    cmp ecx, 3
    je .cls_lr
    cmp ecx, 4
    je .cls_m
    jmp .cls_j                      ; class 5

.cls_n:                             ; NOP/HALT/RET: no regs, imm == 0
    cmp esi, 0xFF
    jne .bad_reg
    cmp edi, 0xFF
    jne .bad_reg
    test r8, r8
    jnz .bad_imm
    jmp .next_slot

.cls_r:                             ; (Rd, Rs): both registers, imm == 0
    cmp esi, 0x0F
    ja .bad_reg
    cmp edi, 0x0F
    ja .bad_reg
    test r8, r8
    jnz .bad_imm
    jmp .next_slot

.cls_i:                             ; (Rd, imm32): dst register, src unused
    cmp esi, 0x0F
    ja .bad_reg
    cmp edi, 0xFF
    jne .bad_reg
    jmp .next_slot                  ; any imm32 pattern accepted

.cls_lr:                            ; single register: dst unused, src register
    cmp esi, 0xFF
    jne .bad_reg
    cmp edi, 0x0F
    ja .bad_reg
    test r8, r8
    jnz .bad_imm
    jmp .next_slot

.cls_m:                             ; absolute address + register
    ; Wraparound-safe: imm32 <= 0x10000 - 8 (constant bound, no u64 wrap).
    cmp r8, 0x10000 - 8
    ja .bad_addr
    cmp eax, 0x17                   ; LOAD Rd, [a32]: dst=Rd, src unused
    je .m_dst_reg
    ; 0x19 STORE [a32], Rs: dst unused, src=Rs (only other M opcode)
.m_src_reg:
    cmp esi, 0xFF
    jne .bad_reg
    cmp edi, 0x0F
    ja .bad_reg
    jmp .next_slot
.m_dst_reg:
    cmp esi, 0x0F
    ja .bad_reg
    cmp edi, 0xFF
    jne .bad_reg
    jmp .next_slot

.cls_j:                             ; absolute code address, no registers
    cmp esi, 0xFF
    jne .bad_reg
    cmp edi, 0xFF
    jne .bad_reg
    cmp r8, r14                     ; imm32 < code_size (u64 compare, no wrap)
    jae .bad_target
    test r8b, 7                     ; imm32 % 8 == 0
    jnz .bad_target
    ; fall through

.next_slot:
    add r11, 8                      ; r11 < code_size <= 64 KiB, no wrap
    jmp .scan

.scan_done:
    ; ---- Load into virtual memory ----
    ; Zero the whole 64 KiB first (no BSS: zero-init data is not stored).
    lea rdi, [vm_mem]
    xor eax, eax
    mov ecx, VM_MEM_SIZE / 8
    rep stosq
    ; Copy code: file_buf+0x1A -> vm_mem (code_size <= 0xF000, in bounds).
    lea rsi, [file_buf + 0x1A]
    lea rdi, [vm_mem]
    mov rcx, r14
    rep movsb
    ; Copy data: file_buf+0x1A+code_size -> vm_mem+code_size.
    ; Step 6 bounds code_size (0x1A+code_size+data_size == total <= 64 KiB);
    ; step 8 bounds code_size+data_size <= 0xF000. No wrap, no overflow.
    lea rsi, [file_buf + 0x1A]
    add rsi, r14
    lea rdi, [vm_mem]
    add rdi, r14
    mov rcx, r15
    rep movsb

    ; ---- Initialize registers: R[*]=0, PC=entry, SP=FP=0x10000, FLAGS=0 ----
    lea rdi, [vm_regs]
    xor eax, eax
    mov ecx, VM_REGS_SIZE / 8
    rep stosq
    mov [vm_regs + VM_OFF_PC], r10
    mov qword [vm_regs + VM_OFF_SP], VM_INIT_SP
    mov qword [vm_regs + VM_OFF_FP], VM_INIT_SP

    xor eax, eax                    ; return 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- error sites (never return) ----
.open_fail:                         ; host-side: file could not be opened
    lea rdi, [s_cannot_open_host]
    mov rsi, rbx
    call host_open_error            ; prints "aurora: ...", exits 2
    ud2
.read_fail:                         ; host-side: read error mid-file
    lea rdi, [s_cannot_read]
    mov rsi, rbx
    call host_open_error            ; exits 2
    ud2

.too_large:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_too_large]
    call fatal_error
    ud2
.truncated_header:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_trunc_hdr]
    call fatal_error
    ud2
.bad_magic:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_bad_magic]
    call fatal_error
    ud2
.bad_version:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_bad_version]
    call fatal_error
    ud2
.bad_reserved:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_bad_reserved]
    call fatal_error
    ud2
.bad_code_size:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_bad_codesize]
    call fatal_error
    ud2
.truncated_program:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_trunc_prog]
    call fatal_error
    ud2
.trailing_data:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_trailing]
    call fatal_error
    ud2
.bad_entry:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_bad_entry]
    call fatal_error
    ud2
.bad_layout:
    mov edi, ERR_INVALID_PROGRAM
    lea rsi, [s_bad_layout]
    call fatal_error
    ud2

; Slot errors: build "… at code offset 0x…" details, then INVALID_INSTRUCTION.
; Conventions on entry: eax = opcode (for .bad_opcode/.bad_class),
; edx = actual class (.bad_class), r8 = imm32 (.bad_target/.bad_addr),
; r11 = code offset (all).
.bad_opcode:
    push r11
    push rax
    call detail_reset
    mov rdi, rax
    lea rsi, [s_bad_opcode]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    lea rsi, [s_at_offset]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    call detail_done
    mov rsi, rax
    mov edi, ERR_INVALID_INSTRUCTION
    call fatal_error
    ud2
.bad_class:
    push r11
    push rdx                        ; actual class
    push rax                        ; opcode
    call detail_reset
    mov rdi, rax
    lea rsi, [s_bad_class]
    call detail_cstr
    pop rsi                         ; actual class
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    lea rsi, [s_for_opcode]
    call detail_cstr
    pop rsi                         ; opcode
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    lea rsi, [s_at_offset]
    call detail_cstr
    pop rsi                         ; code offset
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    call detail_done
    mov rsi, rax
    mov edi, ERR_INVALID_INSTRUCTION
    call fatal_error
    ud2
.bad_reg:
    push r11
    call detail_reset
    mov rdi, rax
    lea rsi, [s_bad_reg]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    call detail_done
    mov rsi, rax
    mov edi, ERR_INVALID_INSTRUCTION
    call fatal_error
    ud2
.bad_imm:
    push r11
    call detail_reset
    mov rdi, rax
    lea rsi, [s_nonzero_imm]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    call detail_done
    mov rsi, rax
    mov edi, ERR_INVALID_INSTRUCTION
    call fatal_error
    ud2
.bad_target:
    push r11
    push r8
    call detail_reset
    mov rdi, rax
    lea rsi, [s_bad_target]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    lea rsi, [s_at_offset]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    call detail_done
    mov rsi, rax
    mov edi, ERR_INVALID_INSTRUCTION
    call fatal_error
    ud2
.bad_addr:
    push r11
    push r8
    call detail_reset
    mov rdi, rax
    lea rsi, [s_bad_addr]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    lea rsi, [s_at_offset]
    call detail_cstr
    pop rsi
    mov rdi, rax
    call detail_hex
    mov rdi, rax
    call detail_done
    mov rsi, rax
    mov edi, ERR_INVALID_INSTRUCTION
    call fatal_error
    ud2

section .note.GNU-stack noalloc noexec nowrite progbits
