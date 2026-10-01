; T5 — STACK_UNDERFLOW.
; Expected: termination_class = FATAL, termination_reason = STACK_UNDERFLOW,
; exit = 105, and "aurora: error: STACK_UNDERFLOW" on stderr.
; Pairs with T4: same exit code (105), different termination.
; (Initial SP = 0x10000, stack empty, so POP violates SP < 0x10000.)

POP R0
HALT          ; unreached
