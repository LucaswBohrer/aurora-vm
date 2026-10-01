; programs/fact.asm -- 10! = 3628800. Expected: "3628800\n", exit 0.

    MOV R0, 1
    MOV R1, 10
loop:
    MUL R0, R1
    DEC R1
    CMP R1, 1
    JG loop
    OUT R0
    HALT
