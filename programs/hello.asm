; programs/hello.asm -- expected output: "Hello, world!\n" (via OUTC loop).

    MOV R0, msg
loop:
    LOADB R1, [R0]
    CMP R1, 0
    JE done
    OUTC R1
    ADD R0, 1
    JMP loop
done:
    MOV R0, 0        ; clean exit code
    HALT

msg: DB "Hello, world!", 10, 0
