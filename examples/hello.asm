; examples/hello.asm — illustrative AURORA Assembly program.
;
; Prints 42 to stdout and halts. The exit code is R0 & 0xFF = 42.
; (The assembler that turns this into bytecode arrives in phase 5;
;  the hand-assembled bytes are shown in README.md.)

MOV R0, 42
OUT R0        ; prints R0 as signed decimal + newline
HALT          ; exit code = R0 & 0xFF
