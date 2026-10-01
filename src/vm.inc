; src/vm.inc — shared virtual-machine state layout.
;
; Included by loader.asm (which defines the BSS) and, in later phases, by
; cpu.asm / debug.asm (which reference it via extern). Constants only,
; no code emitted.
;
; The loader owns initialization (docs/BYTECODE.md §4 step 9 / §5):
;   MEM[0..code_size)        = code bytes (read-only for the guest)
;   MEM[code_size..code_size+data_size) = data bytes
;   MEM elsewhere            = 0x00
;   R0-R15 = 0, PC = entry, SP = FP = 0x10000, FLAGS = 0.

; 64 KiB virtual memory image.
%define VM_MEM_SIZE   0x10000

; vm_regs layout: R0-R15 (16 qwords), then PC, SP, FP, FLAGS (all u64).
%define VM_NREGS       16
%define VM_OFF_PC      (16*8)
%define VM_OFF_SP      (17*8)
%define VM_OFF_FP      (18*8)
%define VM_OFF_FLAGS   (19*8)
%define VM_REGS_SIZE   (20*8)

; Initial stack pointer / frame pointer (top of the 64 KiB address space).
%define VM_INIT_SP     0x10000
