; examples/memory.asm -- 64-bit and byte memory round-trips.

    MOV R0, 0x1000
    MOV R1, 0x5A5A
    STORE [R0], R1    ; mem64[0x1000] = 0x5A5A
    MOV R2, 0
    LOAD R2, [0x1000] ; R2 = 0x5A5A
    CMP R2, R1
    JNE fail
    OUT R2            ; prints "23130"
    MOV R3, cell
    MOV R4, 0xAB
    STOREB [R3], R4   ; mem8[cell] = 0xAB
    LOADB R5, [R3]    ; R5 = 0xAB
    CMP R5, R4
    JNE fail
    MOV R0, 1
    OUT R0            ; prints "1" (ok marker)
    HALT
fail:
    MOV R0, 0
    OUT R0
    HALT

cell: DB 0
