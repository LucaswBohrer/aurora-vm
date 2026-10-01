; T1 — HALT with R0 = 0.
; Expected: termination_class = NORMAL, termination_reason = HALT, exit = 0.
; (Source is documentation until the assembler exists in phase 5;
;  the normative bytes are in run_termination_tests.py.)

MOV R0, 0
HALT
