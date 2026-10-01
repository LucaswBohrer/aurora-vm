; src/errids.inc — shared fatal-error id constants.
;
; Included by errors.asm (which defines fatal_error) and by cpu.asm
; (which raises the errors). Single source of truth; values match
; ARCHITECTURE.md §2.10 and ISA.md. Constants only, no code emitted.

%define ERR_INVALID_OPCODE        1
%define ERR_INVALID_REGISTER     2
%define ERR_INVALID_MEMORY_ACCESS 3
%define ERR_STACK_OVERFLOW       4
%define ERR_STACK_UNDERFLOW      5
%define ERR_DIVISION_BY_ZERO     6
%define ERR_INVALID_PC           7
%define ERR_INVALID_PROGRAM      8
%define ERR_INVALID_INSTRUCTION  9
%define ERR_MAX_STEPS_EXCEEDED   10
%define ERR_WRITE_TO_CODE        11
%define ERR_IO_ERROR             12
