; T3 — DIVISION_BY_ZERO.
; Expected: termination_class = FATAL, termination_reason = DIVISION_BY_ZERO,
; exit = 106, and "aurora: error: DIVISION_BY_ZERO" on stderr.
; Pairs with T2: same exit code (106), different termination.

MOV R1, 10
MOV R2, 0
DIV R1, R2    ; divisor is 0 -> DIVISION_BY_ZERO (fatal, HALT unreached)
HALT
