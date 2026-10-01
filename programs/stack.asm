; programs/stack.asm -- nested calls. Expected: "6\n", exit 6.

    CALL level1
    OUT R0
    HALT
level1:
    CALL level2
    RET
level2:
    CALL level3
    RET
level3:
    MOV R0, 6
    RET
