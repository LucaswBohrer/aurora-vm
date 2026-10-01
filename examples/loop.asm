; examples/loop.asm -- count 1..5 with a conditional loop.

    MOV R0, 1
loop:
    OUT R0            ; print 1, 2, 3, 4, 5
    INC R0
    CMP R0, 6
    JL loop
    HALT
