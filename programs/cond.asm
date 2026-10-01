; programs/cond.asm -- JE/JNE/JG/JL/JGE/JLE taken paths.
; Expected output: "1\n2\n3\n4\n5\n".

    MOV R0, 5
    MOV R1, 5
    CMP R0, R1
    JE is_equal
    JMP fail
is_equal:
    MOV R0, 1
    OUT R0
    MOV R0, 5
    MOV R1, 6
    CMP R0, R1
    JNE is_ne
    JMP fail
is_ne:
    MOV R0, 2
    OUT R0
    MOV R0, 7
    MOV R1, 3
    CMP R0, R1
    JG is_gt
    JMP fail
is_gt:
    MOV R0, 3
    OUT R0
    MOV R0, 3
    MOV R1, 7
    CMP R0, R1
    JL is_lt
    JMP fail
is_lt:
    MOV R0, 4
    OUT R0
    MOV R0, 9
    MOV R1, 9
    CMP R0, R1
    JGE is_ge
    JMP fail
is_ge:
    MOV R0, 5
    OUT R0
    ; JLE taken path (silent check)
    MOV R0, 4
    MOV R1, 9
    CMP R0, R1
    JLE jle_ok
    JMP fail
jle_ok:
    MOV R0, 0
    HALT
fail:
    MOV R0, 99
    OUT R0
    HALT
