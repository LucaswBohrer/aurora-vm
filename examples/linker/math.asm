; examples/linker/math.asm — reusable arithmetic module.
;
; Exports two functions and one data word. `helper_local` stays local:
; another module may define its own `helper_local` without conflict.
;
;   python3 tools/aurora-asm -c examples/linker/math.asm -o /tmp/math.o

    .global add42
    .global mul3
    .global factor

add42:
    ADD R0, 42         ; R0 = R0 + 42
    RET

mul3:
    MOV R1, 3
    MUL R0, R1         ; R0 = R0 * 3
    RET

helper_local:          ; LOCAL symbol: invisible to other modules
    RET

factor: DQ 5           ; 8-byte data word, read by main.o via LOAD
