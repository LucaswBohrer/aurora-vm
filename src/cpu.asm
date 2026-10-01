; src/cpu.asm — AURORA virtual CPU: fetch/decode/execute.
;
; Phase 3 (core) + phase 5 (single-step extraction). 100% x86-64 Assembly,
; Linux syscalls only, no libc.
;
; Entry points:
;   cpu_run(rdi = max_steps). Never returns.
;   cpu_step(). Executes exactly ONE guest instruction and returns:
;       rax = 0: instruction executed, VM still running
;       rax = 1: HALT (NORMAL termination, D22); rdx = exit code (R0 & 0xFF)
;       rax = 2: fatal error; rdx = error id (1..12)
;     cpu_step never exits the process; it preserves rbx, rbp, r12-r15.
;     The debugger (phase 5) drives execution through cpu_step. There is
;     exactly one implementation of the 43 instruction handlers — the
;     debugger observes and controls, it does not re-execute.
;   Precondition (established by the loader, docs/BYTECODE.md §5):
;     vm_mem[0..code_size)            = code bytes (read-only for the guest)
;     vm_mem[code_size..code_size+data_size) = data bytes
;     vm_mem elsewhere                = 0x00
;     vm_regs: R0-R15 = 0, PC = entry, SP = FP = 0x10000, FLAGS = 0
;     vm_code_size                    = code_size
;
; Execution loop (normative pseudocode, docs/ISA.md §7):
;     steps = 0
;     loop forever:
;         if steps >= max_steps and max_steps != 0: die(MAX_STEPS_EXCEEDED)
;         steps += 1
;         if PC >= code_size or PC % 8 != 0: die(INVALID_PC)
;         instr = MEM[PC..PC+8); op = instr[0]
;         if op > 0x2A: die(INVALID_OPCODE)
;         dispatch(op, instr)
;
; The step counter and limit live in globals so the debugger can observe
; and configure them: vm_steps (u64, incremented once per cpu_step),
; vm_max_steps (u64, 0 = unlimited).
;
; Host register allocation (guest state lives in vm_regs / vm_mem):
;     rbx = guest memory base (&vm_mem, constant)
;     r15 = guest PC (cached; published to vm_regs at the top of each loop)
;     r14 = code_size (constant)
;     r13 = max_steps (constant; 0 = unlimited)
;     r12 = steps executed so far
;     rax, rcx, rdx, rsi, rdi, r8-r11 = scratch inside handlers
;
; Flag semantics are implemented exactly per docs/ISA.md §3.1 — they are NOT
; assumed to match x86 except where the spec formulas coincide (ADD/SUB map
; directly onto x86 CF/ZF/SF/OF; MUL/INC/DEC need manual handling, see below).
; FLAGS bits 63-4 always read 0; only bits 3-0 (Z/C/N/V) are ever written.

default rel

%include "src/vm.inc"
%include "src/errids.inc"

global cpu_run
global cpu_step
global vm_steps
global vm_max_steps

extern vm_mem
extern vm_regs
extern vm_code_size
extern fatal_error

section .bss
out_buf:    resb 32                 ; decimal conversion buffer for OUT
vm_steps:   resq 1                  ; instructions executed (u64)
vm_max_steps: resq 1                ; step limit (u64, 0 = unlimited)

section .rodata
s_i64min:   db "-9223372036854775808"

; Dispatch table: opcode 0x00-0x2A -> handler. Matches docs/ISA.md §6.
dispatch:
    dq h_nop                        ; 0x00 NOP
    dq h_halt                       ; 0x01 HALT
    dq h_mov_rr                     ; 0x02 MOV Rd, Rs
    dq h_mov_ri                     ; 0x03 MOV Rd, imm32
    dq h_add_rr                     ; 0x04 ADD Rd, Rs
    dq h_add_ri                     ; 0x05 ADD Rd, imm32
    dq h_sub_rr                     ; 0x06 SUB Rd, Rs
    dq h_sub_ri                     ; 0x07 SUB Rd, imm32
    dq h_mul_rr                     ; 0x08 MUL Rd, Rs
    dq h_mul_ri                     ; 0x09 MUL Rd, imm32
    dq h_div_rr                     ; 0x0A DIV Rd, Rs
    dq h_div_ri                     ; 0x0B DIV Rd, imm32
    dq h_inc                        ; 0x0C INC Rd
    dq h_dec                        ; 0x0D DEC Rd
    dq h_and_rr                     ; 0x0E AND Rd, Rs
    dq h_and_ri                     ; 0x0F AND Rd, imm32
    dq h_or_rr                      ; 0x10 OR Rd, Rs
    dq h_or_ri                      ; 0x11 OR Rd, imm32
    dq h_xor_rr                     ; 0x12 XOR Rd, Rs
    dq h_xor_ri                     ; 0x13 XOR Rd, imm32
    dq h_not                        ; 0x14 NOT Rd
    dq h_cmp_rr                     ; 0x15 CMP Ra, Rb
    dq h_cmp_ri                     ; 0x16 CMP Ra, imm32
    dq h_load_m                     ; 0x17 LOAD Rd, [a32]
    dq h_load_r                     ; 0x18 LOAD Rd, [Rs]
    dq h_store_m                    ; 0x19 STORE [a32], Rs
    dq h_store_r                    ; 0x1A STORE [Rd], Rs
    dq h_loadb_r                    ; 0x1B LOADB Rd, [Rs]
    dq h_storeb_r                   ; 0x1C STOREB [Rd], Rs
    dq h_push                       ; 0x1D PUSH Rs
    dq h_pop                        ; 0x1E POP Rd
    dq h_call                       ; 0x1F CALL a32
    dq h_ret                        ; 0x20 RET
    dq h_jmp                        ; 0x21 JMP a32
    dq h_je                         ; 0x22 JE a32
    dq h_jne                        ; 0x23 JNE a32
    dq h_jg                         ; 0x24 JG a32
    dq h_jl                         ; 0x25 JL a32
    dq h_jge                        ; 0x26 JGE a32
    dq h_jle                        ; 0x27 JLE a32
    dq h_out                        ; 0x28 OUT Rs
    dq h_outc                       ; 0x29 OUTC Rs
    dq h_in                         ; 0x2A IN Rd

section .text

; PACK_FLAGS z, c, n, v — four 8-bit registers each holding 0/1.
; Writes [vm_regs + VM_OFF_FLAGS] = Z | C<<1 | N<<2 | V<<3. Clobbers rax, rcx.
%macro PACK_FLAGS 4
    movzx eax, %1
    movzx ecx, %2
    shl ecx, 1
    or eax, ecx
    movzx ecx, %3
    shl ecx, 2
    or eax, ecx
    movzx ecx, %4
    shl ecx, 3
    or eax, ecx
    mov [vm_regs + VM_OFF_FLAGS], rax
%endmacro

; DECODE_DST — extract the dst register index (instruction byte 1) into r10d.
; (movzx r10d, ah is unencodable: a high-byte register cannot be used
; together with a REX prefix, which r10 requires.)
%macro DECODE_DST 0
    movzx edx, ah
    mov r10d, edx
%endmacro

; NEXT — finish the current instruction: advance to the next sequential
; slot and return from cpu_step with status 0 (still running).
%macro NEXT 0
    add r15, 8
    jmp step_done
%endmacro

; cpu_run(rdi = max_steps). Never returns.
; The phase-3 execution loop, now structured over cpu_step. Observable
; behavior is unchanged: HALT exits with R0 & 0xFF; a fatal error prints
; "aurora: error: <NAME>" to stderr and exits with 100 + id (D22).
cpu_run:
    mov [vm_max_steps], rdi         ; 0 = unlimited (ISA §7)
    mov qword [vm_steps], 0
.loop:
    call cpu_step                   ; rax = status, rdx = payload
    test rax, rax
    jz .loop                        ; status 0: keep executing
    cmp eax, 1
    je .halt
    mov edi, edx                    ; status 2: fatal error, rdx = id
    xor esi, esi
    jmp fatal_error                 ; never returns
.halt:                              ; status 1: HALT (NORMAL, D22)
    mov edi, edx                    ; exit code = R0 & 0xFF
    mov eax, 60                     ; sys_exit
    syscall
    ud2

; cpu_step() — execute exactly one guest instruction.
; Returns rax = 0 (executed, still running), 1 (HALT; rdx = exit code),
;         2 (fatal error; rdx = error id 1..12).
; Never exits the process. Preserves rbx, rbp, r12-r15.
; The debugger drives the VM through this function; the 43 handlers below
; remain the single implementation of instruction semantics.
cpu_step:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [vm_mem]               ; guest memory base
    mov r14, [vm_code_size]         ; code_size
    mov r13, [vm_max_steps]         ; max_steps (0 = unlimited)
    mov r12, [vm_steps]             ; steps executed so far
    mov r15, [vm_regs + VM_OFF_PC]  ; PC = entry / resume point

    mov [vm_regs + VM_OFF_PC], r15  ; publish PC (architectural state)
    ; -- max-steps (ISA.md §7: checked before the increment) --
    test r13, r13
    jz .no_limit
    cmp r12, r13
    jae die_max_steps_exceeded
.no_limit:
    inc r12                         ; steps += 1 (u64; cannot wrap in practice)
    mov [vm_steps], r12
    ; -- PC validation (defense in depth; static targets pre-validated) --
    cmp r15, r14
    jae die_invalid_pc              ; PC >= code_size
    test r15b, 7
    jnz die_invalid_pc              ; PC % 8 != 0
    ; -- fetch --
    mov rax, [rbx + r15]            ; 8-byte instruction word
    movzx ecx, al                   ; opcode
    cmp ecx, 0x2A
    ja die_invalid_opcode           ; defense in depth (loader rejects these)
    jmp [dispatch + rcx*8]

; step_done — normal instruction completion: publish the final PC and
; return status 0. All sequential handlers (NEXT) and control-flow
; handlers (CALL/RET/jumps, which set r15 directly) converge here.
step_done:
    xor eax, eax                    ; status 0 = still running
    jmp step_ret
; step_fatal — entered via die_* with edx = error id: return status 2.
step_fatal:
    mov eax, 2                      ; status 2 = fatal error
    jmp step_ret
step_ret:
    mov [vm_regs + VM_OFF_PC], r15  ; publish final PC
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------- system ---
h_nop:                              ; 0x00 NOP — no operation, flags unchanged
    NEXT

h_halt:                             ; 0x01 HALT — NORMAL termination (D22)
    movzx edx, byte [vm_regs]       ; exit code = R0 & 0xFF
    mov eax, 1                      ; status 1 = HALT
    jmp step_ret

; ---------------------------------------------------------- data movement ---
h_mov_rr:                           ; 0x02 MOV Rd, Rs — flags unchanged
    movzx edx, ah                   ; dst
    shr rax, 16
    movzx ecx, al                   ; src
    mov rax, [vm_regs + rcx*8]
    mov [vm_regs + rdx*8], rax
    NEXT

h_mov_ri:                           ; 0x03 MOV Rd, imm32 — Rd = sext(imm32)
    movzx edx, ah                   ; dst
    shr rax, 32
    movsxd rax, eax                 ; sign-extend imm32 to 64 bits
    mov [vm_regs + rdx*8], rax
    NEXT

; ------------------------------------------------------------ arithmetic ---
; Shared tails: rax = a, r8 = b, r10 = dst index.

h_add_rr:                           ; 0x04 ADD Rd, Rs
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp add_common
h_add_ri:                           ; 0x05 ADD Rd, imm32
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp add_common
; ISA §3.1 ADD: C=(r<a) carry out, V=((a^r)&(b^r))>>63, Z=(r==0), N=r>>63.
; These coincide exactly with x86 CF/OF/ZF/SF after ADD.
add_common:
    add rax, r8
    setz r9b                        ; Z
    setc r11b                       ; C
    sets sil                        ; N
    seto dil                        ; V
    mov [vm_regs + r10*8], rax
    PACK_FLAGS r9b, r11b, sil, dil
    NEXT

h_sub_rr:                           ; 0x06 SUB Rd, Rs
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp sub_common
h_sub_ri:                           ; 0x07 SUB Rd, imm32
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp sub_common
; ISA §3.1 SUB: C=(a<b) borrow, V=((a^b)&(a^r))>>63, Z, N.
; x86 CF after SUB is the borrow bit; OF is the signed-overflow formula.
sub_common:
    sub rax, r8
    setz r9b                        ; Z
    setc r11b                       ; C (borrow)
    sets sil                        ; N
    seto dil                        ; V
    mov [vm_regs + r10*8], rax
    PACK_FLAGS r9b, r11b, sil, dil
    NEXT

h_mul_rr:                           ; 0x08 MUL Rd, Rs (unsigned)
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp mul_common
h_mul_ri:                           ; 0x09 MUL Rd, imm32 (unsigned)
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp mul_common
; ISA §3.1 MUL: C=V=(high64(a*b)!=0); Z=(r==0); N=r>>63.
; x86 MUL sets CF=OF iff the high half is nonzero; ZF/SF computed manually.
mul_common:
    mul r8                          ; rdx:rax = a*b
    setc r11b                       ; C = V = (high != 0)
    mov [vm_regs + r10*8], rax
    test rax, rax
    setz r9b                        ; Z
    mov rcx, rax
    shr rcx, 63                     ; N = cl
    PACK_FLAGS r9b, r11b, cl, r11b
    NEXT

h_div_rr:                           ; 0x0A DIV Rd, Rs (signed)
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp div_common
h_div_ri:                           ; 0x0B DIV Rd, imm32 (signed)
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp div_common
; ISA §3.1 DIV: r = s(a)/s(b); C=0; V=1 only for INT64_MIN / -1
; (result defined as INT64_MIN); Z=(r==0); N=r>>63.
; Division by zero is the fatal error DIVISION_BY_ZERO, not a flag case.
div_common:
    test r8, r8
    jz die_division_by_zero
    mov r11, 0x8000000000000000
    cmp rax, r11
    jne .normal
    cmp r8, -1
    jne .normal
    ; INT64_MIN / -1: rax already holds 0x8000000000000000 (no idiv trap).
    mov [vm_regs + r10*8], rax
    mov qword [vm_regs + VM_OFF_FLAGS], 0x0C  ; V=1, N=1, Z=0, C=0
    NEXT
.normal:
    cqo
    idiv r8                         ; safe: only remaining idiv fault cases
                                    ; (div-by-zero, INT64_MIN/-1) excluded above
    mov [vm_regs + r10*8], rax
    test rax, rax
    setz r9b                        ; Z
    mov rcx, rax
    shr rcx, 63                     ; N = cl
    xor r11d, r11d                  ; C = 0, V = 0
    PACK_FLAGS r9b, r11b, cl, r11b
    NEXT

h_inc:                              ; 0x0C INC Rd — C preserved (ISA §3.1)
    DECODE_DST                 ; dst register (normative: byte 1)
    mov rax, [vm_regs + r10*8]
    mov r11b, [vm_regs + VM_OFF_FLAGS]
    and r11b, 0x02                  ; keep old C at bit 1
    inc rax                         ; x86 INC preserves CF by design
    setz r9b                        ; Z
    seto dil                        ; V = (a was 0x7FFFFFFFFFFFFFFF)
    sets sil                        ; N
    mov [vm_regs + r10*8], rax
    movzx eax, r9b                  ; Z
    or eax, r11d                    ; + old C<<1 (already at bit 1)
    movzx ecx, sil
    shl ecx, 2
    or eax, ecx                     ; + N<<2
    movzx ecx, dil
    shl ecx, 3
    or eax, ecx                     ; + V<<3
    mov [vm_regs + VM_OFF_FLAGS], rax
    NEXT

h_dec:                              ; 0x0D DEC Rd — C preserved (ISA §3.1)
    DECODE_DST                 ; dst register (normative: byte 1)
    mov rax, [vm_regs + r10*8]
    mov r11b, [vm_regs + VM_OFF_FLAGS]
    and r11b, 0x02                  ; keep old C at bit 1
    dec rax                         ; x86 DEC preserves CF by design
    setz r9b                        ; Z
    seto dil                        ; V = (a was 0x8000000000000000)
    sets sil                        ; N
    mov [vm_regs + r10*8], rax
    movzx eax, r9b
    or eax, r11d
    movzx ecx, sil
    shl ecx, 2
    or eax, ecx
    movzx ecx, dil
    shl ecx, 3
    or eax, ecx
    mov [vm_regs + VM_OFF_FLAGS], rax
    NEXT

; ----------------------------------------------------------------- logic ---
h_and_rr:                           ; 0x0E AND Rd, Rs
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp and_common
h_and_ri:                           ; 0x0F AND Rd, imm32
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp and_common
h_or_rr:                            ; 0x10 OR Rd, Rs
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp or_common
h_or_ri:                            ; 0x11 OR Rd, imm32
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp or_common
h_xor_rr:                           ; 0x12 XOR Rd, Rs
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp xor_common
h_xor_ri:                           ; 0x13 XOR Rd, imm32
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp xor_common
; ISA §3.1 AND/OR/XOR: Z=(r==0), N=r>>63, C=0, V=0.
; x86 clears CF/OF for these ops, matching the spec.
and_common:
    and rax, r8
    jmp logic_flags
or_common:
    or rax, r8
    jmp logic_flags
xor_common:
    xor rax, r8
    ; fall through
logic_flags:
    setz r9b                        ; Z
    sets sil                        ; N
    mov [vm_regs + r10*8], rax
    xor r11d, r11d                  ; C = 0, V = 0
    PACK_FLAGS r9b, r11b, sil, r11b
    NEXT

h_not:                              ; 0x14 NOT Rd — flags unchanged (ISA §3.1)
    movzx edx, ah                   ; dst register (normative: byte 1)
    not qword [vm_regs + rdx*8]
    NEXT

; ------------------------------------------------------------- comparison ---
h_cmp_rr:                           ; 0x15 CMP Ra, Rb — flags from Ra-Rb
    DECODE_DST
    shr rax, 16
    movzx ecx, al
    mov rax, [vm_regs + r10*8]
    mov r8, [vm_regs + rcx*8]
    jmp cmp_common
h_cmp_ri:                           ; 0x16 CMP Ra, imm32
    DECODE_DST
    shr rax, 32
    movsxd r8, eax
    mov rax, [vm_regs + r10*8]
    jmp cmp_common
cmp_common:                         ; result discarded; SUB flag semantics
    sub rax, r8
    setz r9b
    setc r11b
    sets sil
    seto dil
    PACK_FLAGS r9b, r11b, sil, dil
    NEXT

; ----------------------------------------------------------------- memory ---
; Address checks are wraparound-safe: `addr > 0x10000 - size` (ISA.md §5).
; Check order per ISA §6.6: memory bounds first, then code write protection.

h_load_m:                           ; 0x17 LOAD Rd, [a32]
    movzx edx, ah                   ; dst register (normative: byte 1)
    shr rax, 32                     ; eax = a32 (loader: <= 0x10000-8)
    cmp eax, 0x10000 - 8            ; defense in depth
    ja die_invalid_mem
    mov r8d, eax
    mov rax, [rbx + r8]
    mov [vm_regs + rdx*8], rax
    NEXT

h_load_r:                           ; 0x18 LOAD Rd, [Rs]
    movzx edx, ah                   ; dst
    shr rax, 16
    movzx ecx, al                   ; src (address register)
    mov r8, [vm_regs + rcx*8]       ; addr (u64)
    cmp r8, 0x10000 - 8
    ja die_invalid_mem
    mov rax, [rbx + r8]
    mov [vm_regs + rdx*8], rax
    NEXT

h_store_m:                          ; 0x19 STORE [a32], Rs
    shr rax, 16
    movzx ecx, al                   ; src register (normative: byte 2)
    shr rax, 16                     ; eax = a32
    cmp eax, 0x10000 - 8
    ja die_invalid_mem
    cmp rax, r14
    jb die_write_to_code            ; addr < code_size
    mov r8, [vm_regs + rcx*8]
    mov [rbx + rax], r8
    NEXT

h_store_r:                          ; 0x1A STORE [Rd], Rs
    movzx edx, ah                   ; dst (address register)
    shr rax, 16
    movzx ecx, al                   ; src
    mov r8, [vm_regs + rdx*8]       ; addr (u64)
    cmp r8, 0x10000 - 8
    ja die_invalid_mem
    cmp r8, r14
    jb die_write_to_code            ; addr < code_size
    mov rax, [vm_regs + rcx*8]
    mov [rbx + r8], rax
    NEXT

h_loadb_r:                          ; 0x1B LOADB Rd, [Rs] — zero-extended byte
    movzx edx, ah                   ; dst
    shr rax, 16
    movzx ecx, al                   ; src (address register)
    mov r8, [vm_regs + rcx*8]       ; addr (u64)
    cmp r8, 0x10000 - 1
    ja die_invalid_mem
    movzx eax, byte [rbx + r8]
    mov [vm_regs + rdx*8], rax
    NEXT

h_storeb_r:                         ; 0x1C STOREB [Rd], Rs — low byte of Rs
    movzx edx, ah                   ; dst (address register)
    shr rax, 16
    movzx ecx, al                   ; src
    mov r8, [vm_regs + rdx*8]       ; addr (u64)
    cmp r8, 0x10000 - 1
    ja die_invalid_mem
    cmp r8, r14
    jb die_write_to_code            ; addr < code_size
    mov al, [vm_regs + rcx*8]       ; Rs[7:0]
    mov [rbx + r8], al
    NEXT

; ------------------------------------------------------------------ stack ---
; Stack region: 0xF000-0xFFFF, grows down. Empty sentinel SP = 0x10000.

h_push:                             ; 0x1D PUSH Rs — SP-=8; require SP>=0xF000
    shr rax, 16
    movzx ecx, al                   ; src register (normative: byte 2)
    mov r8, [vm_regs + VM_OFF_SP]
    cmp r8, 0xF008
    jb die_stack_overflow           ; checked BEFORE SP is modified (ISA §6.7)
    sub r8, 8
    mov [vm_regs + VM_OFF_SP], r8
    mov rax, [vm_regs + rcx*8]
    mov [rbx + r8], rax
    NEXT

h_pop:                              ; 0x1E POP Rd — require SP<0x10000
    movzx edx, ah                   ; dst register (normative: byte 1)
    mov r8, [vm_regs + VM_OFF_SP]
    cmp r8, 0x10000
    jae die_stack_underflow
    mov rax, [rbx + r8]
    mov [vm_regs + rdx*8], rax
    add r8, 8
    mov [vm_regs + VM_OFF_SP], r8
    NEXT

; --------------------------------------------------------------- functions ---
h_call:                             ; 0x1F CALL a32
    shr rax, 32                     ; eax = target (loader pre-validated)
    cmp rax, r14                    ; defense in depth: INVALID_PC
    jae die_invalid_pc
    test al, 7
    jnz die_invalid_pc
    mov r9, rax                     ; save target
    ; push(PC+8) — §6.7 PUSH primitive incl. overflow check
    mov r8, [vm_regs + VM_OFF_SP]
    cmp r8, 0xF008
    jb die_stack_overflow
    sub r8, 8
    lea rax, [r15 + 8]              ; return address
    mov [rbx + r8], rax
    ; push(FP)
    cmp r8, 0xF008
    jb die_stack_overflow
    sub r8, 8
    mov rax, [vm_regs + VM_OFF_FP]
    mov [rbx + r8], rax
    mov [vm_regs + VM_OFF_SP], r8
    mov [vm_regs + VM_OFF_FP], r8   ; FP = SP
    mov r15, r9                     ; PC = target
    jmp step_done

h_ret:                              ; 0x20 RET
    mov r8, [vm_regs + VM_OFF_FP]
    mov [vm_regs + VM_OFF_SP], r8   ; SP = FP (drops the frame)
    cmp r8, 0x10000                 ; FP = pop(): underflow check
    jae die_stack_underflow
    mov rax, [rbx + r8]             ; saved FP
    add r8, 8
    mov [vm_regs + VM_OFF_FP], rax
    cmp r8, 0x10000                 ; PC = pop(): underflow check
    jae die_stack_underflow
    mov r15, [rbx + r8]             ; return address
    add r8, 8
    mov [vm_regs + VM_OFF_SP], r8
    cmp r15, r14                    ; validate dynamic return target
    jae die_invalid_pc
    test r15b, 7
    jnz die_invalid_pc
    jmp step_done

; ------------------------------------------------------------ control flow ---
h_jmp:                              ; 0x21 JMP a32
    shr rax, 32                     ; eax = target
    jmp jcc_take

h_je:                               ; 0x22 JE a32 — Z=1
    shr rax, 32
    mov cl, [vm_regs + VM_OFF_FLAGS]
    test cl, 1
    jz jcc_next
    jmp jcc_take

h_jne:                              ; 0x23 JNE a32 — Z=0
    shr rax, 32
    mov cl, [vm_regs + VM_OFF_FLAGS]
    test cl, 1
    jnz jcc_next
    jmp jcc_take

h_jg:                               ; 0x24 JG a32 — !Z && N==V (signed)
    shr rax, 32
    mov cl, [vm_regs + VM_OFF_FLAGS]
    test cl, 1
    jnz jcc_next                    ; Z=1 -> not taken
    mov dl, cl
    shr dl, 2
    and dl, 1                       ; dl = N
    shr cl, 3
    and cl, 1                       ; cl = V
    cmp dl, cl
    jne jcc_next                    ; N!=V -> not taken
    jmp jcc_take

h_jl:                               ; 0x25 JL a32 — N!=V (signed)
    shr rax, 32
    mov cl, [vm_regs + VM_OFF_FLAGS]
    mov dl, cl
    shr dl, 2
    and dl, 1                       ; dl = N
    shr cl, 3
    and cl, 1                       ; cl = V
    cmp dl, cl
    je jcc_next                     ; N==V -> not taken
    jmp jcc_take

h_jge:                              ; 0x26 JGE a32 — N==V (signed)
    shr rax, 32
    mov cl, [vm_regs + VM_OFF_FLAGS]
    mov dl, cl
    shr dl, 2
    and dl, 1
    shr cl, 3
    and cl, 1
    cmp dl, cl
    jne jcc_next
    jmp jcc_take

h_jle:                              ; 0x27 JLE a32 — Z || N!=V (signed)
    shr rax, 32
    mov cl, [vm_regs + VM_OFF_FLAGS]
    test cl, 1
    jnz jcc_take                    ; Z=1 -> taken
    mov dl, cl
    shr dl, 2
    and dl, 1
    shr cl, 3
    and cl, 1
    cmp dl, cl
    je jcc_next                     ; N==V -> not taken
    jmp jcc_take

; Shared jump tail: rax = absolute target. Static targets are loader-
; validated; this is defense in depth (and load-bearing for RET).
jcc_take:
    cmp rax, r14
    jae die_invalid_pc
    test al, 7
    jnz die_invalid_pc
    mov r15, rax                    ; PC = target
    jmp step_done
jcc_next:
    add r15, 8
    jmp step_done

; --------------------------------------------------------------------- i/o ---
h_out:                              ; 0x28 OUT Rs — signed decimal + '\n'
    shr rax, 16
    movzx ecx, al                   ; src register (normative: byte 2)
    mov rax, [vm_regs + rcx*8]
    call out_i64                    ; preserves rbx, r12-r15; rax = 0/-1
    test rax, rax
    js die_io_error
    NEXT

h_outc:                             ; 0x29 OUTC Rs — low byte of Rs
    shr rax, 16
    movzx ecx, al                   ; src register (normative: byte 2)
    mov al, [vm_regs + rcx*8]
    mov [out_buf], al
    mov edi, 1                      ; stdout
    lea rsi, [out_buf]
    mov edx, 1
    call write_all                  ; rax = 0 ok, -1 error
    test rax, rax
    js die_io_error
    NEXT

h_in:                               ; 0x2A IN Rd — 1 byte; EOF -> 0xFFF...F
    DECODE_DST                 ; dst register (normative: byte 1)
    xor edi, edi                    ; stdin
    lea rsi, [out_buf]              ; 1-byte scratch buffer
    mov edx, 1
    xor eax, eax                    ; sys_read
    syscall                         ; clobbers rcx, r11
    test rax, rax
    js die_io_error
    jz .eof
    movzx eax, byte [out_buf]
    mov [vm_regs + r10*8], rax      ; zero-extended byte
    NEXT
.eof:
    mov qword [vm_regs + r10*8], -1 ; 0xFFFFFFFFFFFFFFFF
    NEXT

; out_i64 — print rax as signed decimal followed by '\n' to stdout.
; ISA §6.10: OUT of 0x8000000000000000 prints -9223372036854775808
; (no negation overflow: the minimum value is special-cased).
; Clobbers rax, rcx, rdx, rsi, rdi, r8-r11. Preserves rbx, r12-r15, rbp.
out_i64:
    lea r8, [out_buf + 32]
    mov byte [r8 - 1], 10           ; '\n'
    lea r9, [r8 - 1]                ; write cursor (grows downward)
    mov r11, 0x8000000000000000
    cmp rax, r11
    je .min
    xor r10d, r10d                  ; sign flag = 0
    test rax, rax
    jns .digits
    neg rax                         ; safe: INT64_MIN handled above
    mov r10b, 1                     ; sign flag = 1
    jmp .digits
.min:
    sub r9, 20
    mov rdi, r9
    lea rsi, [s_i64min]
    mov ecx, 20
    rep movsb
    jmp .write
.digits:
    mov ecx, 10
.digit:
    xor edx, edx
    div rcx                         ; rax /= 10, rdx = digit
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .digit
    test r10b, r10b
    jz .write
    dec r9
    mov byte [r9], '-'
.write:
    mov edi, 1                      ; stdout
    mov rsi, r9
    lea rdx, [out_buf + 32]
    sub rdx, r9                     ; length
    call write_all                  ; rax = 0 ok, -1 error
    ret

; write_all — write rdx bytes from rsi to fd rdi; loops on short writes.
; Returns rax = 0 on success, rax = -1 on error (or zero progress).
; Does NOT jump to die_* (it may be called from nested contexts like
; out_i64 where the cpu_step stack frame is not on top).
; Clobbers rax, rcx, r11. Preserves rbx, r12-r15, rbp.
write_all:
    test rdx, rdx
    jz .done
.loop:
    mov eax, 1                      ; sys_write
    syscall
    test rax, rax
    jle .err
    sub rdx, rax
    je .done
    add rsi, rax
    jmp .loop
.done:
    xor eax, eax                    ; success
    ret
.err:
    mov rax, -1                     ; error (64-bit!)
    ret

; ------------------------------------------------------------ fatal errors ---
; Each site: edx = error id; control flows to step_fatal, which returns
; status 2 (rdx = id) from cpu_step. cpu_run converts that into the
; phase-3 behavior: fatal_error(id, NULL) — "aurora: error: <NAME>" on
; stderr, exit 100 + id (D22). The debugger reports the termination
; itself and stays in the REPL.
die_invalid_opcode:
    mov edx, ERR_INVALID_OPCODE
    jmp step_fatal
die_invalid_mem:
    mov edx, ERR_INVALID_MEMORY_ACCESS
    jmp step_fatal
die_stack_overflow:
    mov edx, ERR_STACK_OVERFLOW
    jmp step_fatal
die_stack_underflow:
    mov edx, ERR_STACK_UNDERFLOW
    jmp step_fatal
die_division_by_zero:
    mov edx, ERR_DIVISION_BY_ZERO
    jmp step_fatal
die_invalid_pc:
    mov edx, ERR_INVALID_PC
    jmp step_fatal
die_max_steps_exceeded:
    mov edx, ERR_MAX_STEPS_EXCEEDED
    jmp step_fatal
die_write_to_code:
    mov edx, ERR_WRITE_TO_CODE
    jmp step_fatal
die_io_error:
    mov edx, ERR_IO_ERROR
    jmp step_fatal

section .note.GNU-stack noalloc noexec nowrite progbits
