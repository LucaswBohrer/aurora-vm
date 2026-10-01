; programs/mem.asm -- memory round-trip. Expected: "1\n", exit 1.

    MOV R0, 0x1000
    MOV R1, 0x5A5A
    STORE [R0], R1
    LOAD R2, [R0]
    CMP R2, R1
    JNE fail
    MOV R0, cell
    MOV R1, 0xAB
    STOREB [R0], R1
    LOADB R2, [R0]
    CMP R2, R1
    JNE fail
    MOV R0, 1
    OUT R0
    HALT
fail:
    MOV R0, 0
    OUT R0
    HALT

cell: DB 0
