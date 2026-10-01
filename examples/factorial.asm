; examples/factorial.asm -- 10! = 3628800.

    MOV R0, 1         ; result
    MOV R1, 10        ; counter
loop:
    MUL R0, R1
    DEC R1
    CMP R1, 1
    JG loop
    OUT R0            ; prints "3628800"
    HALT              ; exit code = 3628800 & 0xFF = 0
