; examples/stack.asm -- PUSH/POP LIFO order and CALL/RET.

    MOV R0, 1
    PUSH R0
    MOV R0, 2
    PUSH R0
    MOV R0, 3
    PUSH R0
    POP R0
    OUT R0            ; 3
    POP R0
    OUT R0            ; 2
    POP R0
    OUT R0            ; 1
    CALL get6
    OUT R0            ; 6
    HALT

get6:
    MOV R0, 6
    RET
