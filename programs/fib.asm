; programs/fib.asm -- fib(10) = 55, recursive. Expected: "55\n", exit 55.

    MOV R0, 10
    CALL fib
    OUT R0
    HALT

fib:
    CMP R0, 2
    JL base          ; n < 2 -> return n
    PUSH R0          ; save n
    DEC R0
    CALL fib         ; R0 = fib(n-1)
    MOV R1, R0
    POP R0           ; R0 = n
    SUB R0, 2
    PUSH R1          ; save fib(n-1)
    CALL fib         ; R0 = fib(n-2)
    POP R1
    ADD R0, R1       ; R0 = fib(n-1) + fib(n-2)
    RET
base:
    RET
