; src/debug.asm — `aurora debug <file>`: interactive debugger (phase 5).
;
; 100% x86-64 Assembly, Linux syscalls only, no libc.
;
; The debugger is an observation/control layer over the existing VM. It
; drives execution exclusively through cpu_step() — the same fetch/
; decode/execute implementation (all 43 handlers) used by `aurora run`.
; There is no second CPU here: the disassembler below decodes bytes for
; DISPLAY ONLY and never executes anything.
;
; Breakpoints are debugger state (16 slots, checked before each fetch).
; The loaded program bytes are never modified.
;
; REPL: commands are read as lines from stdin, so scripted sessions
; (printf ... | aurora debug prog.bin) are deterministic and CI-friendly.
; All debugger text goes to stdout; the guest program's own OUT/OUTC/IN
; use the same stdio fds as under `aurora run`.

default rel

%include "src/vm.inc"

global cmd_debug

extern loader_load_file
extern cpu_step
extern vm_mem
extern vm_regs
extern vm_code_size
extern vm_steps
extern vm_max_steps
extern error_name
extern print_fd
extern print_cstr_stdout
extern cstr_len
extern streq
extern parse_u64
extern cli_error_with_arg
extern host_open_error

%define AT_FDCWD -100
%define SYS_OPENAT 257
%define SYS_CLOSE 3
%define SYS_READ 0
%define SYS_EXIT 60

%define DBG_MAX_BPS 16
%define DBG_LINE_MAX 1024
%define DBG_DEFAULT_MAX_STEPS 100000000

section .bss
dbg_mem_init:   resb VM_MEM_SIZE    ; pristine memory image (for reset)
dbg_regs_init:  resb VM_REGS_SIZE   ; pristine registers (for reset)
dbg_bps:        resq DBG_MAX_BPS    ; breakpoint addrs; -1 = empty slot
dbg_terminated: resb 1              ; 0 = running, 1 = terminated
dbg_term_class: resb 1              ; 0 = NORMAL, 1 = FATAL (D22)
dbg_term_id:    resq 1              ; 0 = HALT, else error id 1..12
dbg_exit_code:  resq 1              ; exit code of the termination
dbg_entry:      resq 1              ; initial PC (loader entry point)
line_buf:       resb DBG_LINE_MAX
num_buf:        resb 64             ; decimal conversion scratch
regs_snap:      resb VM_REGS_SIZE   ; register snapshot (step diff)

section .rodata
s_usage:       db "debug: expected exactly one file operand", 0
s_dhelp:       db "--help", 0
s_debug_help:  db "Usage: aurora debug <file>", 10
               db 10
               db "Interactive debugger for AURORA bytecode.", 10
               db "Type 'help' at the (aurora-debug) prompt for commands.", 10, 0
s_cannot_open: db "debug: cannot open", 0
s_banner:      db "AURORA debugger - type 'help' for commands", 10, 0
s_prompt:      db "(aurora-debug) ", 0
s_nl:          db 10
s_0x:          db "0x", 0
s_hexdig:      db "0123456789ABCDEF"
s_errpre:      db "error: ", 0
s_arrow:       db " -> ", 0
s_colon_sp:    db ": ", 0

; --- help text ---
s_help:
    db "commands:", 10
    db "  run                     reset VM, run until stop", 10
    db "  continue                resume from current state until stop", 10
    db "  step [n]                execute n instructions (default 1)", 10
    db "  break <addr>            set breakpoint at code address", 10
    db "  delete <addr>           remove breakpoint", 10
    db "  breakpoints             list breakpoints", 10
    db "  regs                    show R0-R15, PC, SP, FP, FLAGS", 10
    db "  flags                   show FLAGS detail (Z C N V)", 10
    db "  memory <addr> [count]   dump virtual memory bytes", 10
    db "  stack [n]               show SP, FP and top n stack words", 10
    db "  backtrace               walk the FP chain (call frames)", 10
    db "  disasm [addr] [count]   disassemble instructions", 10
    db "  info                    show VM state summary", 10
    db "  reset                   restore initial VM state (keeps breakpoints)", 10
    db "  set max-steps <n>       set step limit (0 = unlimited)", 10
    db "  help                    show this list", 10
    db "  quit                    exit the debugger", 10
    db "addresses: 0x1A hex or 26 decimal. 'regs' is an alias of 'registers',", 10
    db "'disassemble' an alias of 'disasm'.", 10, 0

; --- command names ---
c_run:         db "run", 0
c_continue:    db "continue", 0
c_step:        db "step", 0
c_break:       db "break", 0
c_delete:      db "delete", 0
c_breakpoints: db "breakpoints", 0
c_regs:        db "regs", 0
c_registers:   db "registers", 0
c_flags:       db "flags", 0
c_memory:      db "memory", 0
c_stack:       db "stack", 0
c_backtrace:   db "backtrace", 0
c_disasm:      db "disasm", 0
c_disassemble: db "disassemble", 0
c_info:        db "info", 0
c_reset:       db "reset", 0
c_set:          db "set", 0
c_help:        db "help", 0
c_quit:        db "quit", 0
c_maxsteps:    db "max-steps", 0

; --- fixed messages ---
m_bp_set:      db "breakpoint set at ", 0
m_bp_del:      db "breakpoint deleted at ", 0
m_no_bps:      db "no breakpoints", 0
m_stopped_bp:  db "stopped at breakpoint ", 0
m_reset_done:  db "state reset (breakpoints kept)", 10, 0
m_term_normal: db "terminated: NORMAL (HALT), exit code ", 0
m_term_fatal:  db "terminated: FATAL (", 0
m_term_fatal2: db "), exit code ", 0
m_maxsteps_is: db "max-steps = ", 0
m_unlimited:   db "max-steps = unlimited", 10, 0
m_empty_stack: db "empty stack", 10, 0
; info labels
m_i_pc:        db "PC: ", 0
m_i_code:      db "code size: ", 0
m_i_steps:     db "steps executed: ", 0
m_i_max:       db "max steps: ", 0
m_i_term:      db "termination: ", 0
m_i_bps:       db "breakpoints: ", 0
m_running:     db "running", 10, 0
m_of:          db "/", 0
; regs labels
m_flags_lbl:   db "FLAGS: ", 0
m_flags_bits:  db " (Z=", 0
m_sp1:         db " C=", 0
m_sp2:         db " N=", 0
m_sp3:         db " V=", 0
m_rparen_nl:   db ")", 10, 0
; stack labels
m_sp_lbl:      db "SP: ", 0
m_fp_lbl:      db "FP: ", 0
; errors
e_unknown:     db "unknown command", 0
e_noaddr:      db "expected address", 0
e_badaddr:     db "invalid address", 0
e_badcount:    db "invalid count", 0
e_bp_range:    db "invalid breakpoint address (must be a code address)", 0
e_bp_dup:      db "breakpoint already set", 0
e_bp_full:     db "too many breakpoints (max 16)", 0
e_bp_none:     db "no breakpoint at address", 0
e_terminated:  db "program already terminated (use 'reset')", 0
e_mem_range:   db "memory range out of bounds", 0
e_dis_range:   db "address out of code range", 0
e_badset:      db "usage: set max-steps <n>", 0
e_badstep_n:   db "invalid step count", 0

section .text

; ------------------------------------------------------------------ entry ---
; cmd_debug(rdi = argc, rsi = argv) — argv[0] is "debug".
cmd_debug:
    push rbx
    push r12
    cmp rdi, 2
    jne .usage                       ; need exactly argv[1] = file
    mov rbx, [rsi + 8]               ; rbx = path
    ; Support "aurora debug --help".
    lea rdi, [rbx]
    lea rsi, [s_dhelp]
    call streq
    test rax, rax
    jnz .show_help

    ; Host-side readability check (exit 2 on failure, like cmd_run).
    mov eax, SYS_OPENAT
    mov edi, AT_FDCWD
    mov rsi, rbx
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, 0
    jl .open_fail
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall

    mov rdi, rbx
    xor esi, esi
    call loader_load_file            ; 0 on success; fatal errors exit

    ; Snapshot the pristine post-load state for `reset`.
    lea rdi, [dbg_mem_init]
    lea rsi, [vm_mem]
    mov ecx, VM_MEM_SIZE / 8
    rep movsq
    lea rdi, [dbg_regs_init]
    lea rsi, [vm_regs]
    mov ecx, VM_REGS_SIZE / 8
    rep movsq

    ; Debugger state init.
    mov rax, [vm_regs + VM_OFF_PC]
    mov [dbg_entry], rax
    mov rax, DBG_DEFAULT_MAX_STEPS
    mov [vm_max_steps], rax
    mov qword [vm_steps], 0
    mov byte [dbg_terminated], 0
    mov rax, -1
    lea rdi, [dbg_bps]
    mov ecx, DBG_MAX_BPS
    rep stosq                        ; all breakpoint slots empty

    lea rdi, [s_banner]
    call dbg_puts
    jmp repl

.usage:
    lea rdi, [s_usage]
    xor esi, esi
    call cli_error_with_arg          ; exits 2
.show_help:
    lea rdi, [s_debug_help]
    call dbg_puts
    xor edi, edi                     ; exit 0
    mov eax, SYS_EXIT
    syscall
.open_fail:
    lea rdi, [s_cannot_open]
    mov rsi, rbx
    call host_open_error             ; exits 2

; ------------------------------------------------------------------- REPL ---
repl:
    lea rdi, [s_prompt]
    call dbg_puts
    lea rdi, [line_buf]
    mov rsi, DBG_LINE_MAX
    call read_line                   ; rax = length, or -1 on EOF
    cmp rax, -1
    je dbg_quit
    ; Tokenize: rbx = command, r12 = args ("" if none).
    lea rbx, [line_buf]
    mov rdi, rbx
    call skip_spaces
    mov rbx, rax
    ; find end of command token
    mov rdi, rbx
.find_end:
    mov al, [rdi]
    test al, al
    jz .no_args
    cmp al, ' '
    je .have_args
    cmp al, 9                        ; tab
    je .have_args
    inc rdi
    jmp .find_end
.have_args:
    mov byte [rdi], 0
    inc rdi
    call skip_spaces
    mov r12, rax
    jmp .dispatch
.no_args:
    lea r12, [s_empty]
.dispatch:
    mov al, [rbx]
    test al, al
    jz repl                          ; empty line: re-prompt
%macro DISPATCH_CMD 2
    mov rdi, rbx
    lea rsi, [%1]
    call streq
    test rax, rax
    jnz %2
%endmacro
    DISPATCH_CMD c_run, cmd_run_dbg
    DISPATCH_CMD c_continue, cmd_continue
    DISPATCH_CMD c_step, cmd_step
    DISPATCH_CMD c_break, cmd_break
    DISPATCH_CMD c_delete, cmd_delete
    DISPATCH_CMD c_breakpoints, cmd_breakpoints
    DISPATCH_CMD c_regs, cmd_regs
    DISPATCH_CMD c_registers, cmd_regs
    DISPATCH_CMD c_flags, cmd_flags
    DISPATCH_CMD c_memory, cmd_memory
    DISPATCH_CMD c_stack, cmd_stack
    DISPATCH_CMD c_backtrace, cmd_backtrace
    DISPATCH_CMD c_disasm, cmd_disasm
    DISPATCH_CMD c_disassemble, cmd_disasm
    DISPATCH_CMD c_info, cmd_info
    DISPATCH_CMD c_reset, cmd_reset
    DISPATCH_CMD c_set, cmd_set
    DISPATCH_CMD c_help, cmd_help
    DISPATCH_CMD c_quit, dbg_quit
    ; unknown command: echo it for a useful diagnostic
    lea rdi, [e_unknown]
    call dbg_error_pre
    mov rdi, rbx
    call dbg_puts
    call dbg_nl
    jmp repl

cmd_help:
    lea rdi, [s_help]
    call dbg_puts
    jmp repl

dbg_quit:
    mov eax, SYS_EXIT
    xor edi, edi                     ; exit 0
    syscall
    ud2

section .rodata
s_empty: db 0
section .text

; ------------------------------------------------------------ I/O helpers ---
; All helpers follow the internal convention: System V args, callee
; preserves rbx, rbp, r12-r15. Debugger text goes to stdout (fd 1).

; dbg_puts(rdi = NUL-terminated string) — print to stdout.
dbg_puts:
    jmp print_cstr_stdout            ; tail call (same convention)

; dbg_putsn(rdi = ptr, rsi = len) — print bytes to stdout.
dbg_putsn:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    jmp print_fd                     ; tail call

; dbg_nl() — print '\n'.
dbg_nl:
    mov edi, 1
    lea rsi, [s_nl]
    mov edx, 1
    jmp print_fd

; dbg_error_pre(rdi = message cstr) — print "error: <msg>" (no newline).
dbg_error_pre:
    push rdi
    lea rdi, [s_errpre]
    call dbg_puts
    pop rdi
    jmp dbg_puts

; dbg_error(rdi = message cstr) — print "error: <msg>\n".
dbg_error:
    call dbg_error_pre
    jmp dbg_nl

; dbg_print_hex64(rax = value) — 16 uppercase hex digits, no prefix.
dbg_print_hex64:
    push rbx
    push r12
    mov rbx, rax
    xor r12d, r12d                   ; output position 0..15
.loop:
    rol rbx, 4                       ; next most-significant nibble to bits 3-0
    mov edx, ebx
    and edx, 0xF
    lea rax, [s_hexdig]
    mov dl, [rax + rdx]
    mov [num_buf + r12], dl
    inc r12
    cmp r12d, 16
    jb .loop
    lea rdi, [num_buf]
    mov rsi, 16
    call dbg_putsn
    pop r12
    pop rbx
    ret

; dbg_print_hex8(rax = value) — low 32 bits as 8 hex digits, no prefix.
dbg_print_hex8:
    push rbx
    push r12
    mov ebx, eax
    xor r12d, r12d
.loop:
    rol ebx, 4
    mov edx, ebx
    and edx, 0xF
    lea rax, [s_hexdig]
    mov dl, [rax + rdx]
    mov [num_buf + r12], dl
    inc r12
    cmp r12d, 8
    jb .loop
    lea rdi, [num_buf]
    mov rsi, 8
    call dbg_putsn
    pop r12
    pop rbx
    ret

; dbg_print_addr(rax = guest address) — "0x" + 8 hex digits.
dbg_print_addr:
    push rax
    lea rdi, [s_0x]
    call dbg_puts
    pop rax
    jmp dbg_print_hex8                ; tail call

; dbg_print_regval(rax = value) — "0x" + 16 hex digits.
dbg_print_regval:
    push rax
    lea rdi, [s_0x]
    call dbg_puts
    pop rax
    jmp dbg_print_hex64               ; tail call

; dbg_print_u64(rax = value) — unsigned decimal.
dbg_print_u64:
    lea r8, [num_buf + 64]
    mov rcx, r8
    test rax, rax
    jnz .digits
    dec rcx
    mov byte [rcx], '0'
    jmp .out
.digits:
    mov r9, 10
.digit:
    xor edx, edx
    div r9
    add dl, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz .digit
.out:
    mov rdi, rcx
    mov rsi, r8
    sub rsi, rcx
    jmp dbg_putsn

; dbg_print_i64(rax = value) — signed decimal.
dbg_print_i64:
    test rax, rax
    jns dbg_print_u64
    push rax
    mov al, '-'
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    pop rax
    neg rax                          ; caller never passes INT64_MIN here
    jmp dbg_print_u64                ; (imm32 range only)

; dbg_print_regname(rax = index 0..15) — "R<n>".
dbg_print_regname:
    push rax
    mov al, 'R'
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    pop rax
    jmp dbg_print_u64                ; tail call

; read_line(rdi = buf, rsi = maxlen) — read one line from stdin.
; Returns rax = length excluding '\n' (NUL-terminated in buf),
; or rax = -1 on EOF before any byte.
read_line:
    push rbx
    push r12
    push r13
    mov rbx, rdi                     ; buf
    mov r12, rsi                     ; maxlen
    xor r13d, r13d                   ; count
.loop:
    cmp r13, r12
    jae .full
    xor eax, eax                     ; sys_read
    xor edi, edi                     ; stdin
    lea rsi, [rbx + r13]
    mov edx, 1
    syscall
    test rax, rax
    jz .eof                          ; 0 bytes = EOF
    js .eof                          ; error: treat as EOF
    mov al, [rbx + r13]
    inc r13
    cmp al, 10
    je .done
    jmp .loop
.full:                               ; line too long: drain to newline
    xor eax, eax
    xor edi, edi
    lea rsi, [num_buf]               ; 1-byte drain
    mov edx, 1
    syscall
    test rax, rax
    jle .done
    cmp byte [num_buf], 10
    jne .full
.done:
    ; Ensure the NUL terminator lands inside the buffer: if the line
    ; filled the buffer exactly (r13 == maxlen), truncate by one so we
    ; write at [rbx + maxlen - 1], not one past the end.
    cmp r13, r12
    jb .write_nul
    lea r13, [r12 - 1]
.write_nul:
    mov byte [rbx + r13], 0
    ; strip a trailing '\n' if present (when buffer filled exactly)
    test r13, r13
    jz .ret
    cmp byte [rbx + r13 - 1], 10
    jne .ret
    mov byte [rbx + r13 - 1], 0
    dec r13
.ret:
    mov rax, r13
    pop r13
    pop r12
    pop rbx
    ret
.eof:
    test r13, r13
    jnz .done                        ; partial line without newline: use it
    mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

; skip_spaces(rdi = ptr) -> rax = first non-space/tab/NUL... (stops at NUL)
skip_spaces:
.loop:
    mov al, [rdi]
    cmp al, ' '
    je .next
    cmp al, 9
    je .next
    mov rax, rdi
    ret
.next:
    inc rdi
    jmp .loop

; parse_addr(rsi = cstr) -> rax = value, rdx = 0 ok / 1 error.
; Accepts 0x[hex]+ or [0-9]+. Stops at NUL/space/tab (the token may be
; followed by more arguments). No sign. The input buffer is never
; modified. Digits are parsed manually (like the hex path) so there is
; no dependency on parse_u64's register usage or NUL termination.
parse_addr:
    push rbx
    push r12
    mov r12, rsi                     ; r12 = token start
    cmp word [rsi], 0x7830            ; "0x"
    je .hex
    cmp word [rsi], 0x5830            ; "0X"
    je .hex
    ; decimal: manual parse with overflow check
    mov rbx, rsi
    mov al, [rbx]
    test al, al
    jz .err                          ; empty
    xor eax, eax                     ; accumulator
.loop_dec:
    mov dl, [rbx]
    test dl, dl
    jz .ok
    cmp dl, ' '
    je .ok
    cmp dl, 9
    je .ok
    sub dl, '0'
    cmp dl, 9
    ja .err                          ; non-digit
    ; overflow guard: (2^64-1)/10 = 1844674407370955161 rem 5
    mov r8, 1844674407370955161
    cmp rax, r8
    ja .err
    jb .mul_dec
    cmp dl, 5
    ja .err
.mul_dec:
    imul rax, rax, 10
    movzx r8d, dl
    add rax, r8
    inc rbx
    jmp .loop_dec
.hex:
    add r12, 2
    mov rbx, r12
    mov al, [rbx]
    test al, al
    jz .err                          ; "0x" alone
    xor eax, eax                     ; accumulator
    xor ecx, ecx                     ; digit count
.loop:
    mov dl, [rbx]
    test dl, dl
    jz .ok
    cmp dl, ' '
    je .ok
    cmp dl, 9
    je .ok
    ; hex digit -> use r8b
    mov r8b, dl
    sub r8b, '0'
    cmp r8b, 9
    jbe .dig
    mov r8b, dl
    or r8b, 0x20                     ; tolower
    sub r8b, 'a'
    cmp r8b, 5
    ja .err
    add r8b, 10
.dig:
    cmp ecx, 16
    jae .err                         ; >16 hex digits overflows u64
    shl rax, 4
    or al, r8b
    inc rbx
    inc ecx
    jmp .loop
.ok:
    xor edx, edx
    pop r12
    pop rbx
    ret
.err:
    xor eax, eax
    mov edx, 1
    pop r12
    pop rbx
    ret

; ------------------------------------------------------- breakpoint state ---
; bp_find(rax = addr) -> rax = slot index 0..15, or -1 if not present.
bp_find:
    push rbx
    lea rbx, [dbg_bps]
    xor ecx, ecx
.loop:
    cmp ecx, DBG_MAX_BPS
    je .no
    cmp [rbx + rcx*8], rax
    je .yes
    inc ecx
    jmp .loop
.yes:
    mov eax, ecx
    pop rbx
    ret
.no:
    mov rax, -1
    pop rbx
    ret

; bp_at(rax = addr) -> rax = 1 if a breakpoint is set there, else 0.
bp_at:
    call bp_find
    cmp rax, -1
    setne al
    movzx eax, al
    ret

; bp_add(rax = addr) -> rax = 0 ok, 1 duplicate, 2 full.
bp_add:
    push rbx
    mov rbx, rax
    call bp_find
    cmp rax, -1
    jne .dup
    lea rcx, [dbg_bps]
    xor eax, eax
.loop:
    cmp rax, DBG_MAX_BPS
    je .full
    cmp qword [rcx + rax*8], -1
    je .slot
    inc rax
    jmp .loop
.slot:
    mov [rcx + rax*8], rbx
    xor eax, eax
    pop rbx
    ret
.dup:
    mov eax, 1
    pop rbx
    ret
.full:
    mov eax, 2
    pop rbx
    ret

; bp_del(rax = addr) -> rax = 0 ok, 1 not found.
bp_del:
    push rbx
    mov rbx, rax
    call bp_find
    cmp rax, -1
    je .no
    mov qword [dbg_bps + rax*8], -1
    xor eax, eax
    pop rbx
    ret
.no:
    mov eax, 1
    pop rbx
    ret

; bp_count() -> rax = number of active breakpoints.
bp_count:
    lea rcx, [dbg_bps]
    xor eax, eax
    xor edx, edx
.loop:
    cmp edx, DBG_MAX_BPS
    je .done
    cmp qword [rcx + rdx*8], -1
    je .next
    inc rax
.next:
    inc edx
    jmp .loop
.done:
    ret

; ------------------------------------------------------ execution control ---
; dbg_on_terminate(rax = status 1/2, rdx = payload) — record termination
; in debugger state and print the status line. D22: the class is carried
; explicitly, never inferred from the exit code.
;   status 1: NORMAL, reason HALT, rdx = exit code (R0 & 0xFF)
;   status 2: FATAL, rdx = error id; exit code = 100 + id
dbg_on_terminate:
    push rbx
    mov rbx, rdx                     ; payload
    mov byte [dbg_terminated], 1
    cmp eax, 1
    je .normal
    ; FATAL
    mov byte [dbg_term_class], 1
    mov [dbg_term_id], rbx
    lea edi, [rbx + 100]
    mov [dbg_exit_code], rdi
    lea rdi, [m_term_fatal]
    call dbg_puts
    mov rdi, rbx                     ; error id
    call error_name                  ; rsi = name, rdx = len
    mov rdi, rsi                     ; dbg_putsn wants rdi = ptr
    mov rsi, rdx                     ; rsi = len
    call dbg_putsn
    lea rdi, [m_term_fatal2]
    call dbg_puts
    mov rax, [dbg_exit_code]
    call dbg_print_u64
    jmp .nl
.normal:
    mov byte [dbg_term_class], 0
    mov qword [dbg_term_id], 0
    mov [dbg_exit_code], rbx
    lea rdi, [m_term_normal]
    call dbg_puts
    mov rax, rbx
    call dbg_print_u64
.nl:
    call dbg_nl
    pop rbx
    ret

; dbg_exec_loop() — execute until a stop condition:
;   * breakpoint at PC (checked BEFORE the fetch, never executed past),
;   * HALT or fatal error (recorded + reported),
;   * max-steps (surfaced as FATAL MAX_STEPS_EXCEEDED by cpu_step).
; The loaded bytecode is never modified; breakpoints are debugger state.
dbg_exec_loop:
    push rbx
    push r12
.loop:
    cmp byte [dbg_terminated], 0
    jne .done
    mov rax, [vm_regs + VM_OFF_PC]
    call bp_at
    test rax, rax
    jnz .hit
    call cpu_step                    ; rax = status, rdx = payload
    test rax, rax
    jz .loop
    call dbg_on_terminate
    jmp .done
.hit:
    lea rdi, [m_stopped_bp]
    call dbg_puts
    mov rax, [vm_regs + VM_OFF_PC]
    call dbg_print_addr
    call dbg_nl
.done:
    pop r12
    pop rbx
    ret

; dbg_reset_vm() — restore the pristine post-load state: registers,
; memory, step counter and termination. Breakpoints are KEPT (D24).
dbg_reset_vm:
    push rbx
    lea rdi, [vm_mem]
    lea rsi, [dbg_mem_init]
    mov ecx, VM_MEM_SIZE / 8
    rep movsq
    lea rdi, [vm_regs]
    lea rsi, [dbg_regs_init]
    mov ecx, VM_REGS_SIZE / 8
    rep movsq
    mov qword [vm_steps], 0
    mov byte [dbg_terminated], 0
    pop rbx
    ret

; dbg_check_live() -> rax = 1 if the VM can execute, else prints the
; "already terminated" error and returns 0.
dbg_check_live:
    cmp byte [dbg_terminated], 0
    je .ok
    lea rdi, [e_terminated]
    call dbg_error
    xor eax, eax
    ret
.ok:
    mov eax, 1
    ret

; --- `run`: reset the VM, then execute until a stop condition. ---
cmd_run_dbg:
    call dbg_reset_vm
    call dbg_exec_loop
    jmp repl

; --- `continue`: resume from the current state until a stop condition. ---
; If the PC sits exactly on a breakpoint, execute that one instruction
; first (silently); otherwise `continue` would stop at the same
; breakpoint forever.
cmd_continue:
    call dbg_check_live
    test rax, rax
    jz repl
    push rbx
    mov rax, [vm_regs + VM_OFF_PC]
    call bp_at
    test rax, rax
    jz .go
    call cpu_step
    test rax, rax
    jz .go
    call dbg_on_terminate
    pop rbx
    jmp repl
.go:
    pop rbx
    call dbg_exec_loop
    jmp repl

; --- `step [n]`: execute exactly n instructions (default 1). ---
; Before each step the current instruction is disassembled; after the
; step, changed registers and the PC transition are shown. Stops early
; on a breakpoint (checked before the 2nd..n-th fetch) or on
; termination. Exactly one cpu_step() per reported step — debugger
; internals are never counted as VM steps.
cmd_step:
    call dbg_check_live
    test rax, rax
    jz repl
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, 1                       ; default n = 1
    mov al, [r12]
    test al, al
    jz .go
    ; parse optional count (decimal only)
    mov rdi, r12
    call skip_spaces
    mov rsi, rax
    call parse_u64                   ; rax = n, rdx = 0/1
    test rdx, rdx
    jnz .badn
    test rax, rax
    jz .badn
    mov r14, rax
    jmp .go
.badn:
    lea rdi, [e_badstep_n]
    call dbg_error
    jmp .done
.go:
    xor r13d, r13d                   ; i = 0
.step_loop:
    cmp r13, r14
    je .done
    cmp byte [dbg_terminated], 0
    jne .done
    ; breakpoint check before the 2nd..n-th fetch (the 1st always runs)
    test r13, r13
    jz .nostop
    mov rax, [vm_regs + VM_OFF_PC]
    call bp_at
    test rax, rax
    jz .nostop
    lea rdi, [m_stopped_bp]
    call dbg_puts
    mov rax, [vm_regs + VM_OFF_PC]
    call dbg_print_addr
    call dbg_nl
    jmp .done
.nostop:
    ; snapshot registers for the diff
    lea rdi, [regs_snap]
    lea rsi, [vm_regs]
    mov ecx, VM_REGS_SIZE / 8
    rep movsq
    mov rbx, [vm_regs + VM_OFF_PC]   ; PC before
    ; disassemble the instruction about to execute
    mov rax, rbx
    call dis_one
    call cpu_step                    ; rax = status, rdx = payload
    mov r15, rdx                     ; save payload (helpers clobber rdx)
    mov r12, rax                     ; save status
    mov rax, rbx
    call dbg_print_addr              ; PC before...
    lea rdi, [s_arrow]
    call dbg_puts
    mov rax, [vm_regs + VM_OFF_PC]   ; ...-> PC after
    call dbg_print_addr
    call dbg_nl
    call dbg_print_regdiff           ; changed R0-R15/SP/FP/FLAGS
    test r12, r12
    jz .next
    mov rax, r12                     ; terminated: report with saved payload
    mov rdx, r15
    call dbg_on_terminate
.next:
    inc r13
    jmp .step_loop
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp repl

; ------------------------------------------------------ inspection cmds ---
; dbg_print_regdiff() — compare regs_snap[] with vm_regs[]; print one
; line per changed slot: "R3: 0xOLD -> 0xNEW" (PC/SP/FP/FLAGS by name).
dbg_print_regdiff:
    push rbx
    push r12
    push r13
    push r14
    lea r12, [regs_snap]
    lea r13, [vm_regs]
    xor r14d, r14d                   ; slot 0..19
.loop:
    cmp r14d, 20
    je .done
    mov rax, [r12 + r14*8]
    mov rbx, [r13 + r14*8]
    cmp rax, rbx
    je .next
    ; print name
    cmp r14d, 16
    jl .rn
    je .pc
    cmp r14d, 17
    je .sp
    cmp r14d, 18
    je .fp
    lea rdi, [m_flags_name]
    call dbg_puts
    jmp .vals
.rn:
    mov rax, r14
    call dbg_print_regname
    jmp .vals
.pc:
    lea rdi, [m_pc_name]
    call dbg_puts
    jmp .vals
.sp:
    lea rdi, [m_sp_name]
    call dbg_puts
    jmp .vals
.fp:
    lea rdi, [m_fp_name]
    call dbg_puts
.vals:
    lea rdi, [s_colon_sp]
    call dbg_puts
    mov rax, [r12 + r14*8]
    call dbg_print_regval
    lea rdi, [s_arrow]
    call dbg_puts
    mov rax, [r13 + r14*8]
    call dbg_print_regval
    call dbg_nl
.next:
    inc r14d
    jmp .loop
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
m_pc_name:    db "PC", 0
m_sp_name:    db "SP", 0
m_fp_name:    db "FP", 0
m_flags_name: db "FLAGS", 0
section .text

; --- `regs` / `registers`: R0-R15, PC, SP, FP, FLAGS (16-digit hex). ---
cmd_regs:
    push rbx
    push r12
    xor r12d, r12d                   ; slot 0..19
.loop:
    cmp r12d, 16
    jb .greg
    cmp r12d, 19
    je .flags
    cmp r12d, 16                     ; 16/17/18 -> PC/SP/FP
    je .pc
    cmp r12d, 17
    je .sp
    lea rdi, [m_fp_name]
    call dbg_puts
    jmp .colon
.pc:
    lea rdi, [m_pc_name]
    call dbg_puts
    jmp .colon
.sp:
    lea rdi, [m_sp_name]
    call dbg_puts
.colon:
    lea rdi, [s_colon_sp]
    call dbg_puts
    mov rax, [vm_regs + r12*8]       ; slots 16/17/18 map onto PC/SP/FP
    call dbg_print_regval
    call dbg_nl
    jmp .next
.greg:
    mov rax, r12
    call dbg_print_regname
    lea rdi, [s_colon_sp]
    call dbg_puts
    mov rax, [vm_regs + r12*8]
    call dbg_print_regval
    call dbg_nl
    jmp .next
.flags:
    lea rdi, [m_flags_lbl]
    call dbg_puts
    mov rbx, [vm_regs + VM_OFF_FLAGS]
    mov rax, rbx
    call dbg_print_regval
    lea rdi, [m_flags_bits]
    call dbg_puts
    mov eax, ebx
    and eax, 1                       ; Z
    call dbg_print_u64
    lea rdi, [m_sp1]
    call dbg_puts
    mov eax, ebx
    shr eax, 1
    and eax, 1                       ; C
    call dbg_print_u64
    lea rdi, [m_sp2]
    call dbg_puts
    mov eax, ebx
    shr eax, 2
    and eax, 1                       ; N
    call dbg_print_u64
    lea rdi, [m_sp3]
    call dbg_puts
    mov eax, ebx
    shr eax, 3
    and eax, 1                       ; V
    call dbg_print_u64
    lea rdi, [m_rparen_nl]
    call dbg_puts
.next:
    inc r12d
    cmp r12d, 20
    jb .loop
    pop r12
    pop rbx
    jmp repl

; --- `flags`: FLAGS = 0x... (Z=.. C=.. N=.. V=..) ---
cmd_flags:
    push rbx
    lea rdi, [m_flags_lbl]
    call dbg_puts
    mov rax, [vm_regs + VM_OFF_FLAGS]
    mov rbx, rax
    call dbg_print_regval
    lea rdi, [m_flags_bits]
    call dbg_puts
    mov rax, rbx
    test al, 1
    setnz al
    movzx eax, al
    call dbg_print_u64
    lea rdi, [m_sp1]
    call dbg_puts
    mov rax, rbx
    test al, 2
    setnz al
    movzx eax, al
    call dbg_print_u64
    lea rdi, [m_sp2]
    call dbg_puts
    mov rax, rbx
    test al, 4
    setnz al
    movzx eax, al
    call dbg_print_u64
    lea rdi, [m_sp3]
    call dbg_puts
    mov rax, rbx
    test al, 8
    setnz al
    movzx eax, al
    call dbg_print_u64
    lea rdi, [m_rparen_nl]
    call dbg_puts
    pop rbx
    jmp repl

; --- `memory <addr> [count]`: dump virtual memory (16 bytes/line). ---
cmd_memory:
    push rbx
    push r12
    push r13
    push r14
    mov al, [r12]
    test al, al
    jz .noaddr
    mov rdi, r12
    call skip_spaces
    mov rsi, rax
    call parse_addr                    ; rax = addr
    test rdx, rdx
    jnz .badaddr
    mov rbx, rax                       ; rbx = addr
    mov r14, 16                        ; default count
    ; optional count: find next token
    mov rdi, rsi
.count_scan:
    mov al, [rdi]
    test al, al
    jz .have_count
    cmp al, ' '
    je .count_tok
    cmp al, 9
    je .count_tok
    inc rdi
    jmp .count_scan
.count_tok:
    inc rdi
    call skip_spaces
    cmp byte [rax], 0
    je .have_count
    mov rsi, rax
    call parse_addr
    test rdx, rdx
    jnz .badcount
    mov r14, rax
.have_count:
    test r14, r14
    jz .badcount
    ; bounds: addr < 0x10000 and addr+count <= 0x10000
    cmp rbx, 0x10000
    jae .range
    mov rax, rbx
    add rax, r14
    jc .range
    cmp rax, 0x10000
    ja .range
    ; dump
    xor r13d, r13d                     ; done = 0
.line:
    cmp r13, r14
    jae .done
    mov rax, rbx
    add rax, r13
    call dbg_print_addr
    lea rdi, [s_colon_sp]
    call dbg_puts
    xor r12d, r12d                     ; column 0..15
.byte:
    cmp r12, 16
    je .eol
    mov rax, r13
    add rax, r12
    cmp rax, r14
    jae .eol
    mov rax, rbx
    add rax, r13
    add rax, r12
    movzx eax, byte [vm_mem + rax]
    call dbg_print_hex8_byte
    mov al, ' '
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    inc r12
    jmp .byte
.eol:
    call dbg_nl
    add r13, 16
    jmp .line
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp repl
.noaddr:
    lea rdi, [e_noaddr]
    call dbg_error
    jmp .ret
.badaddr:
    lea rdi, [e_badaddr]
    call dbg_error
    jmp .ret
.badcount:
    lea rdi, [e_badcount]
    call dbg_error
    jmp .ret
.range:
    lea rdi, [e_mem_range]
    call dbg_error
.ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp repl

; dbg_print_hex8_byte(rax = byte value) — 2 hex digits.
dbg_print_hex8_byte:
    push rbx
    mov ebx, eax
    mov edx, ebx
    shr edx, 4
    lea rax, [s_hexdig]
    mov dl, [rax + rdx]
    mov [num_buf], dl
    and ebx, 0xF
    mov bl, [rax + rbx]
    mov [num_buf + 1], bl
    lea rdi, [num_buf]
    mov rsi, 2
    call dbg_putsn
    pop rbx
    ret

; --- `stack [n]`: SP, FP and the top n stack words. ---
cmd_stack:
    push rbx
    push r12
    push r13
    push r14
    mov r13, 8                         ; default n = 8
    mov al, [r12]
    test al, al
    jz .go
    mov rdi, r12
    call skip_spaces
    mov rsi, rax
    call parse_u64
    test rdx, rdx
    jnz .badcount
    mov r13, rax
.go:
    lea rdi, [m_sp_lbl]
    call dbg_puts
    mov rax, [vm_regs + VM_OFF_SP]
    mov rbx, rax                       ; rbx = SP
    call dbg_print_regval
    call dbg_nl
    lea rdi, [m_fp_lbl]
    call dbg_puts
    mov rax, [vm_regs + VM_OFF_FP]
    call dbg_print_regval
    call dbg_nl
    xor r12d, r12d                     ; i = 0
.word:
    cmp r12, r13
    je .done
    mov rax, rbx
    lea rcx, [r12*8]
    add rax, rcx
    cmp rax, 0x10000 - 8
    ja .done
    mov r14, rax                     ; word address (helpers clobber rax)
    call dbg_print_addr
    lea rdi, [s_colon_sp]
    call dbg_puts
    mov rax, [vm_mem + r14]
    call dbg_print_regval
    call dbg_nl
    inc r12
    jmp .word
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp repl
.badcount:
    lea rdi, [e_badcount]
    call dbg_error
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp repl

; --- `backtrace`: walk the FP chain per the calling convention. ---
; Frame layout (§2.8): [FP] = saved FP, [FP+8] = return address.
cmd_backtrace:
    push rbx
    push r12
    push r13
    mov rbx, [vm_regs + VM_OFF_FP]      ; rbx = fp
    cmp rbx, 0x10000
    je .empty
    xor r12d, r12d                     ; frame index
.frame:
    cmp r12d, 64
    je .done
    ; sanity: fp in [0xF000, 0x10000), 8-aligned, room for 16 bytes
    cmp rbx, 0xF000
    jb .done
    cmp rbx, 0x10000 - 16
    ja .done
    test bl, 7
    jnz .done
    mov rax, r12
    call dbg_print_u64                 ; "#<i>" — print as "<i>: "
    mov al, ':'
    mov [num_buf], al
    mov al, ' '
    mov [num_buf + 1], al
    lea rdi, [num_buf]
    mov rsi, 2
    call dbg_putsn
    lea rdi, [m_fp_lbl2]
    call dbg_puts
    mov rax, rbx
    call dbg_print_addr
    lea rdi, [m_ret_lbl]
    call dbg_puts
    mov rax, [vm_mem + rbx + 8]        ; return address
    call dbg_print_addr
    call dbg_nl
    mov r13, [vm_mem + rbx]            ; saved FP
    cmp r13, 0x10000
    je .done
    cmp r13, rbx
    jbe .done                          ; chain must move down (no cycles)
    mov rbx, r13
    inc r12d
    jmp .frame
.done:
    pop r13
    pop r12
    pop rbx
    jmp repl
.empty:
    lea rdi, [m_empty_stack]
    call dbg_puts
    pop r13
    pop r12
    pop rbx
    jmp repl

section .rodata
m_fp_lbl2:    db "FP=", 0
m_ret_lbl:    db " return=", 0
section .text

; --- `info`: VM state summary. ---
cmd_info:
    push rbx
    lea rdi, [m_i_pc]
    call dbg_puts
    mov rax, [vm_regs + VM_OFF_PC]
    call dbg_print_regval
    call dbg_nl
    lea rdi, [m_i_code]
    call dbg_puts
    mov rax, [vm_code_size]
    call dbg_print_u64
    lea rdi, [s_paren_hex]
    call dbg_puts
    mov rax, [vm_code_size]
    call dbg_print_addr
    lea rdi, [s_rparen_nl]
    call dbg_puts
    lea rdi, [m_i_steps]
    call dbg_puts
    mov rax, [vm_steps]
    call dbg_print_u64
    call dbg_nl
    lea rdi, [m_i_max]
    call dbg_puts
    mov rax, [vm_max_steps]
    test rax, rax
    jz .unlim
    call dbg_print_u64
    call dbg_nl
    jmp .term
.unlim:
    lea rdi, [m_unlimited2]
    call dbg_puts
.term:
    lea rdi, [m_i_term]
    call dbg_puts
    cmp byte [dbg_terminated], 0
    jne .term_done
    lea rdi, [m_running]
    call dbg_puts
    jmp .bps
.term_done:
    cmp byte [dbg_term_class], 0
    je .t_normal
    lea rdi, [m_term_fatal]
    call dbg_puts
    mov rdi, [dbg_term_id]
    call error_name                  ; rsi = name, rdx = len
    mov rdi, rsi
    mov rsi, rdx
    call dbg_putsn
    lea rdi, [m_term_fatal2]
    call dbg_puts
    mov rax, [dbg_exit_code]
    call dbg_print_u64
    call dbg_nl
    jmp .bps
.t_normal:
    lea rdi, [m_term_normal]
    call dbg_puts
    mov rax, [dbg_exit_code]
    call dbg_print_u64
    call dbg_nl
.bps:
    lea rdi, [m_i_bps]
    call dbg_puts
    call bp_count
    call dbg_print_u64
    lea rdi, [m_of]
    call dbg_puts
    mov rax, DBG_MAX_BPS
    call dbg_print_u64
    call dbg_nl
    pop rbx
    jmp repl

section .rodata
s_paren_hex:  db " (", 0
s_rparen_nl:  db ")", 10, 0
m_unlimited2: db "unlimited", 10, 0
section .text

; --- `reset`: restore the pristine post-load state (keeps breakpoints). ---
cmd_reset:
    call dbg_reset_vm
    lea rdi, [m_reset_done]
    call dbg_puts
    jmp repl

; --- `set max-steps <n>`: configure the step limit (0 = unlimited). ---
cmd_set:
    push rbx
    mov rdi, r12
    call skip_spaces                    ; rax = subcommand
    mov rbx, rax
    ; isolate subcommand token
    mov rdi, rbx
.sub_end:
    mov al, [rdi]
    test al, al
    jz .sub_args_empty
    cmp al, ' '
    je .sub_args
    cmp al, 9
    je .sub_args
    inc rdi
    jmp .sub_end
.sub_args:
    mov byte [rdi], 0
    inc rdi
    call skip_spaces
    jmp .have_sub
.sub_args_empty:
    xor eax, eax
.have_sub:
    mov r12, rax                        ; r12 = value string (or "")
    mov rdi, rbx
    lea rsi, [c_maxsteps]
    call streq
    test rax, rax
    jz .bad
    mov al, [r12]
    test al, al
    jz .bad
    mov rsi, r12
    call parse_u64
    test rdx, rdx
    jnz .bad
    mov [vm_max_steps], rax
    test rax, rax
    jz .unlim
    lea rdi, [m_maxsteps_is]
    call dbg_puts
    mov rax, [vm_max_steps]             ; dbg_puts clobbers rax; reload
    call dbg_print_u64
    call dbg_nl
    jmp .done
.unlim:
    lea rdi, [m_unlimited]
    call dbg_puts
.done:
    pop rbx
    jmp repl
.bad:
    lea rdi, [e_badset]
    call dbg_error
    pop rbx
    jmp repl

; ------------------------------------------------------- breakpoint cmds ---
; --- `break <addr>`: set a breakpoint at a code address. ---
cmd_break:
    push rbx
    mov al, [r12]
    test al, al
    jz .noaddr
    mov rdi, r12
    call skip_spaces
    mov rsi, rax
    call parse_addr
    test rdx, rdx
    jnz .badaddr
    mov rbx, rax
    ; must be a code address: addr < code_size, addr % 8 == 0
    cmp rbx, [vm_code_size]
    jae .range
    test bl, 7
    jnz .range
    mov rax, rbx
    call bp_add
    cmp eax, 1
    je .dup
    cmp eax, 2
    je .full
    lea rdi, [m_bp_set]
    call dbg_puts
    mov rax, rbx
    call dbg_print_addr
    call dbg_nl
    jmp .done
.noaddr:
    lea rdi, [e_noaddr]
    call dbg_error
    jmp .done
.badaddr:
    lea rdi, [e_badaddr]
    call dbg_error
    jmp .done
.range:
    lea rdi, [e_bp_range]
    call dbg_error
    jmp .done
.dup:
    lea rdi, [e_bp_dup]
    call dbg_error
    jmp .done
.full:
    lea rdi, [e_bp_full]
    call dbg_error
.done:
    pop rbx
    jmp repl

; --- `delete <addr>`: remove a breakpoint. ---
cmd_delete:
    push rbx
    mov al, [r12]
    test al, al
    jz .noaddr
    mov rdi, r12
    call skip_spaces
    mov rsi, rax
    call parse_addr
    test rdx, rdx
    jnz .badaddr
    mov rbx, rax
    call bp_del
    test eax, eax
    jnz .none
    lea rdi, [m_bp_del]
    call dbg_puts
    mov rax, rbx
    call dbg_print_addr
    call dbg_nl
    jmp .done
.noaddr:
    lea rdi, [e_noaddr]
    call dbg_error
    jmp .done
.badaddr:
    lea rdi, [e_badaddr]
    call dbg_error
    jmp .done
.none:
    lea rdi, [e_bp_none]
    call dbg_error
.done:
    pop rbx
    jmp repl

; --- `breakpoints`: list active breakpoints. ---
cmd_breakpoints:
    push rbx
    push r12
    call bp_count
    test rax, rax
    jz .none
    lea rbx, [dbg_bps]
    xor r12d, r12d
.loop:
    cmp r12d, DBG_MAX_BPS
    je .done
    mov rax, [rbx + r12*8]
    cmp rax, -1
    je .next
    call dbg_print_addr
    call dbg_nl
.next:
    inc r12d
    jmp .loop
.done:
    pop r12
    pop rbx
    jmp repl
.none:
    lea rdi, [m_no_bps]
    call dbg_puts
    call dbg_nl
    pop r12
    pop rbx
    jmp repl

; ---------------------------------------------------------- disassembler ---
; Display-only decoder for the 43 AURORA opcodes. It NEVER executes:
; operand shapes and mnemonics come from docs/ISA.md §6; the CPU's
; handlers remain the sole implementation of semantics.
;
; dis_one(rax = guest code address) — print one disassembled line:
;   "0x00000010: MOV R0, 42\n"
; Caller guarantees addr+8 <= code_size. Preserves rbx, r12-r15.
dis_one:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rax                     ; rbx = addr
    call dbg_print_addr
    lea rdi, [s_colon_sp]
    call dbg_puts
    mov r12, [vm_mem + rbx]          ; instruction word
    movzx r13d, r12b                 ; r13 = opcode
    cmp r13d, 0x2A
    ja .invalid
    lea rax, [dis_mnem]
    mov rdi, [rax + r13*8]
    call dbg_puts
    lea rax, [dis_fmt]
    movzx r14d, byte [rax + r13]     ; r14 = format
    cmp r14d, 0
    je .done
    mov al, ' '
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    cmp r14d, 1
    je .f_rr
    cmp r14d, 2
    je .f_ri
    cmp r14d, 3
    je .f_rd
    cmp r14d, 4
    je .f_rs
    cmp r14d, 5
    je .f_mld
    cmp r14d, 6
    je .f_mst
    cmp r14d, 7
    je .f_j
    cmp r14d, 8
    je .f_rld
    jmp .f_rst                        ; format 9
.f_rr:                               ; MNEM Rd, Rs
    mov rax, r12
    shr rax, 8
    and eax, 0xF
    call dbg_print_regname
    lea rdi, [s_comma_sp]
    call dbg_puts
    mov rax, r12
    shr rax, 16
    and eax, 0xF
    call dbg_print_regname
    jmp .done
.f_ri:                               ; MNEM Rd, imm32 (signed)
    mov rax, r12
    shr rax, 8
    and eax, 0xF
    call dbg_print_regname
    lea rdi, [s_comma_sp]
    call dbg_puts
    mov rax, r12
    shr rax, 32
    movsxd rax, eax
    call dbg_print_i64
    jmp .done
.f_rd:                               ; MNEM Rd (register in dst byte)
    mov rax, r12
    shr rax, 8
    and eax, 0xF
    call dbg_print_regname
    jmp .done
.f_rs:                               ; MNEM Rs (register in src byte)
    mov rax, r12
    shr rax, 16
    and eax, 0xF
    call dbg_print_regname
    jmp .done
.f_mld:                              ; MNEM Rd, [0x........]
    mov rax, r12
    shr rax, 8
    and eax, 0xF
    call dbg_print_regname
    lea rdi, [s_comma_sp]
    call dbg_puts
    mov al, '['
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    mov rax, r12
    shr rax, 32
    call dbg_print_addr
    mov al, ']'
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    jmp .done
.f_mst:                              ; MNEM [0x........], Rs
    mov al, '['
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    mov rax, r12
    shr rax, 32
    call dbg_print_addr
    mov al, ']'
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    lea rdi, [s_comma_sp]
    call dbg_puts
    mov rax, r12
    shr rax, 16
    and eax, 0xF
    call dbg_print_regname
    jmp .done
.f_j:                                ; MNEM 0x........
    mov rax, r12
    shr rax, 32
    call dbg_print_addr
    jmp .done
.f_rld:                              ; MNEM Rd, [Rs]
    mov rax, r12
    shr rax, 8
    and eax, 0xF
    call dbg_print_regname
    lea rdi, [s_comma_sp]
    call dbg_puts
    mov al, '['
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    mov rax, r12
    shr rax, 16
    and eax, 0xF
    call dbg_print_regname
    mov al, ']'
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    jmp .done
.f_rst:                              ; MNEM [Rd], Rs
    mov al, '['
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    mov rax, r12
    shr rax, 8
    and eax, 0xF
    call dbg_print_regname
    mov al, ']'
    mov [num_buf], al
    lea rdi, [num_buf]
    mov rsi, 1
    call dbg_putsn
    lea rdi, [s_comma_sp]
    call dbg_puts
    mov rax, r12
    shr rax, 16
    and eax, 0xF
    call dbg_print_regname
    jmp .done
.invalid:                            ; defense in depth (loader rejects these)
    lea rdi, [s_invalid_op]
    call dbg_puts
.done:
    call dbg_nl
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
s_comma_sp:  db ", ", 0
s_invalid_op: db "??? (invalid opcode)", 0

; Mnemonics indexed by opcode 0x00-0x2A (docs/ISA.md §6).
m_nop:   db "NOP", 0
m_halt:  db "HALT", 0
m_mov:   db "MOV", 0
m_add:   db "ADD", 0
m_sub:   db "SUB", 0
m_mul:   db "MUL", 0
m_div:   db "DIV", 0
m_inc:   db "INC", 0
m_dec:   db "DEC", 0
m_and:   db "AND", 0
m_or:    db "OR", 0
m_xor:   db "XOR", 0
m_not:   db "NOT", 0
m_cmp:   db "CMP", 0
m_load:  db "LOAD", 0
m_store: db "STORE", 0
m_loadb: db "LOADB", 0
m_storeb: db "STOREB", 0
m_push:  db "PUSH", 0
m_pop:   db "POP", 0
m_call:  db "CALL", 0
m_ret:   db "RET", 0
m_jmp:   db "JMP", 0
m_je:    db "JE", 0
m_jne:   db "JNE", 0
m_jg:    db "JG", 0
m_jl:    db "JL", 0
m_jge:   db "JGE", 0
m_jle:   db "JLE", 0
m_out:   db "OUT", 0
m_outc:  db "OUTC", 0
m_in:    db "IN", 0

dis_mnem:
    dq m_nop, m_halt                 ; 0x00-0x01
    dq m_mov, m_mov                  ; 0x02-0x03
    dq m_add, m_add                  ; 0x04-0x05
    dq m_sub, m_sub                  ; 0x06-0x07
    dq m_mul, m_mul                  ; 0x08-0x09
    dq m_div, m_div                  ; 0x0A-0x0B
    dq m_inc, m_dec                  ; 0x0C-0x0D
    dq m_and, m_and                  ; 0x0E-0x0F
    dq m_or, m_or                    ; 0x10-0x11
    dq m_xor, m_xor                  ; 0x12-0x13
    dq m_not                         ; 0x14
    dq m_cmp, m_cmp                  ; 0x15-0x16
    dq m_load, m_load                ; 0x17-0x18
    dq m_store, m_store              ; 0x19-0x1A
    dq m_loadb, m_storeb             ; 0x1B-0x1C
    dq m_push, m_pop                 ; 0x1D-0x1E
    dq m_call, m_ret                 ; 0x1F-0x20
    dq m_jmp, m_je                   ; 0x21-0x22
    dq m_jne, m_jg                   ; 0x23-0x24
    dq m_jl, m_jge                   ; 0x25-0x26
    dq m_jle                         ; 0x27
    dq m_out, m_outc                 ; 0x28-0x29
    dq m_in                          ; 0x2A

; Operand formats: 0=N 1=RR 2=RI 3=Rd 4=Rs 5=LOAD[Rd,[a32]]
; 6=STORE[[a32],Rs] 7=J 8=LOAD[Rd,[Rs]] 9=STORE[[Rd],Rs].
dis_fmt:
    db 0, 0                          ; 0x00-0x01
    db 1, 2                          ; 0x02-0x03
    db 1, 2                          ; 0x04-0x05
    db 1, 2                          ; 0x06-0x07
    db 1, 2                          ; 0x08-0x09
    db 1, 2                          ; 0x0A-0x0B
    db 3, 3                          ; 0x0C-0x0D
    db 1, 2                          ; 0x0E-0x0F
    db 1, 2                          ; 0x10-0x11
    db 1, 2                          ; 0x12-0x13
    db 3                             ; 0x14
    db 1, 2                          ; 0x15-0x16
    db 5, 8                          ; 0x17-0x18
    db 6, 9                          ; 0x19-0x1A
    db 8, 9                          ; 0x1B-0x1C
    db 4, 3                          ; 0x1D-0x1E
    db 7, 0                          ; 0x1F-0x20
    db 7, 7                          ; 0x21-0x22
    db 7, 7                          ; 0x23-0x24
    db 7, 7                          ; 0x25-0x26
    db 7                             ; 0x27
    db 4, 4                          ; 0x28-0x29
    db 3                             ; 0x2A

section .text

; --- `disasm [addr] [count]`: disassemble count instructions at addr. ---
; Defaults: addr = PC, count = 8. Range is restricted to the code
; segment; count*8 arithmetic is overflow-safe.
cmd_disasm:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, [vm_regs + VM_OFF_PC]     ; default addr = PC
    mov r14, 8                         ; default count = 8
    mov al, [r12]
    test al, al
    jz .validate
    mov rdi, r12
    call skip_spaces
    mov rsi, rax
    call parse_addr
    test rdx, rdx
    jnz .badaddr
    mov rbx, rax
    ; optional count: next token
    mov rdi, rsi
.scan:
    mov al, [rdi]
    test al, al
    jz .validate
    cmp al, ' '
    je .count_tok
    cmp al, 9
    je .count_tok
    inc rdi
    jmp .scan
.count_tok:
    inc rdi
    call skip_spaces
    cmp byte [rax], 0
    je .validate
    mov rsi, rax
    call parse_addr
    test rdx, rdx
    jnz .badcount
    mov r14, rax
.validate:
    test r14, r14
    jz .badcount
    ; addr < code_size, addr % 8 == 0
    cmp rbx, [vm_code_size]
    jae .range
    test bl, 7
    jnz .range
    ; count <= (code_size - addr) / 8  (no overflow: subtraction first)
    mov rax, [vm_code_size]
    sub rax, rbx
    shr rax, 3
    cmp r14, rax
    ja .range
    xor r13d, r13d
.loop:
    cmp r13, r14
    je .done
    mov rax, rbx
    call dis_one
    add rbx, 8
    inc r13
    jmp .loop
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp repl
.badaddr:
    lea rdi, [e_badaddr]
    call dbg_error
    jmp .ret
.badcount:
    lea rdi, [e_badcount]
    call dbg_error
    jmp .ret
.range:
    lea rdi, [e_dis_range]
    call dbg_error
.ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    jmp repl

section .note.GNU-stack noalloc noexec nowrite progbits
