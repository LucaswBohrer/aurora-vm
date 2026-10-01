; examples/arithmetic.asm -- (20 + 10) * 3 = 90.
; The exact bytes are worked out in docs/ISA.md section 11.

    MOV R0, 20
    MOV R1, 10
    ADD R0, R1        ; R0 = 30
    MOV R2, 3
    MUL R0, R2        ; R0 = 90
    OUT R0            ; prints "90"
    HALT              ; exit code = 90
