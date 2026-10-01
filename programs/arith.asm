; programs/arith.asm -- expected output: "90\n", exit 90.

    MOV R0, 20
    MOV R1, 10
    ADD R0, R1
    MOV R2, 3
    MUL R0, R2
    OUT R0
    HALT
