; examples/hello.asm -- Hello, world! via OUTC loop over a DB string.
;
; Assembled with: python3 tools/aurora-asm examples/hello.asm -o hello.bin
; Run with:       ./build/aurora run hello.bin

    MOV R0, msg        ; R0 = address of the string
loop:
    LOADB R1, [R0]     ; next byte
    CMP R1, 0
    JE done            ; null terminator ends the loop
    OUTC R1            ; print one character
    ADD R0, 1
    JMP loop
done:
    MOV R0, 0        ; clean exit code
    HALT

msg: DB "Hello, world!", 10, 0
