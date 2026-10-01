; Mnemonics/registers/directives are case-insensitive; labels are not.
    mov r0, 65
    outc R0              ; prints "A"
    MoV R1, msg
    loadb r2, [R1]       ; 0
    cmp R2, 0
    je Done              ; taken (exact-case label match)
    jmp Fail
Done:
    mov r0, 0
    HALT
Fail:
    mov r0, 99
    HALT
msg: db 0
