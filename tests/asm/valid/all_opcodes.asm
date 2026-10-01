; All 43 opcodes in one runnable program. Ends with HALT, exit 0.
; The test runner independently decodes every instruction and checks
; opcode/class/dst/src/imm against docs/ISA.md section 6.
    NOP
    MOV R0, R1
    MOV R1, 10
    MOV R2, -1
    MOV R3, 0xFF
    MOV R4, 0b101
    ADD R0, R1
    ADD R0, 5
    SUB R0, R1
    SUB R0, 5
    MOV R5, 3
    MUL R5, R1
    MUL R5, 2
    DIV R5, R1
    DIV R5, 2
    INC R5
    DEC R5
    AND R5, R1
    AND R5, 7
    OR R5, R1
    OR R5, 5
    XOR R5, R1
    XOR R5, 5
    NOT R5
    CMP R5, R1
    CMP R5, 5
    MOV R6, 0x1000
    MOV R7, 0x5A5A
    STORE [R6], R7
    LOAD R8, [R6]
    STORE [0x1010], R7
    LOAD R8, [0x1010]
    MOV R9, sbyte
    MOV R10, 0xAB
    STOREB [R9], R10
    LOADB R11, [R9]
    PUSH R5
    POP R12
    CALL func
    JMP done
func:
    MOV R13, 1
    RET
done:
    MOV R0, 5
    CMP R0, 5
    JE t1
    JMP fail
t1:
    MOV R0, 5
    MOV R1, 6
    CMP R0, R1
    JNE t2
    JMP fail
t2:
    MOV R0, 7
    MOV R1, 3
    CMP R0, R1
    JG t3
    JMP fail
t3:
    MOV R0, 3
    MOV R1, 7
    CMP R0, R1
    JL t4
    JMP fail
t4:
    MOV R0, 9
    MOV R1, 9
    CMP R0, R1
    JGE t5
    JMP fail
t5:
    MOV R0, 4
    MOV R1, 9
    CMP R0, R1
    JLE t6
    JMP fail
t6:
    OUT R12
    OUTC R12
    IN R14
    MOV R0, 0
    HALT
fail:
    MOV R0, 99
    HALT

sbyte: DB 0
