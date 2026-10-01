; The eight class-r opcodes. The runner asserts the exact dst/src
; placement: INC/DEC/NOT/POP/IN carry the register in dst,
; PUSH/OUT/OUTC carry it in src (the phase-3 correction).
; The PUSH seeds the stack so POP does not underflow.
    PUSH R3
    INC R3
    DEC R3
    NOT R3
    POP R3
    IN R3
    OUT R3
    OUTC R3
    MOV R0, 0
    HALT
