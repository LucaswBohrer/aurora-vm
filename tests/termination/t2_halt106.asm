; T2 — HALT with R0 = 106.
; Expected: termination_class = NORMAL, termination_reason = HALT, exit = 106.
; Pairs with T3: same exit code, different termination.

MOV R0, 106
HALT
