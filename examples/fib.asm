; examples/fib.asm -- fib(10) = 55, iterative.

    MOV R0, 0         ; a = fib(0)
    MOV R1, 1         ; b = fib(1)
    MOV R2, 10        ; iterations remaining
loop:
    MOV R3, R0
    ADD R3, R1        ; R3 = a + b
    MOV R0, R1        ; a = b
    MOV R1, R3        ; b = a + b
    DEC R2
    CMP R2, 0
    JG loop
    OUT R0            ; prints "55"
    HALT
