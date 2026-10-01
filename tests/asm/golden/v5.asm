    MOV R0, 5
    MOV R1, 5
    CMP R0, R1
    JE equal
    MOV R2, 0
    HALT
equal:
    MOV R2, 1
    HALT
