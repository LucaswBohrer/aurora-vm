; T4 — HALT with R0 = 105.
; Expected: termination_class = NORMAL, termination_reason = HALT, exit = 105.
; Pairs with T5: same exit code, different termination.

MOV R0, 105
HALT
