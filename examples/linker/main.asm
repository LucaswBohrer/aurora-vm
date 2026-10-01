; examples/linker/main.asm — entry module for the linker example.
;
; Calls functions and reads data defined in math.o, linked with:
;
;   python3 tools/aurora-asm -c examples/linker/main.asm -o /tmp/main.o
;   python3 tools/aurora-asm -c examples/linker/math.asm  -o /tmp/math.o
;   python3 tools/aurora-ld /tmp/main.o /tmp/math.o -o /tmp/math_demo.bin
;   ./build/aurora run /tmp/math_demo.bin
;
; Expected stdout: "50\n21\n5\n", exit code 0.
;
; NOTE: main.o must come first on the link line: the linker writes
; entry = 0, so execution starts at the first object's first
; instruction (docs/LINKER.md section 2).

    MOV R0, 8
    CALL add42          ; R0 = 8 + 42 = 50 (defined in math.o)
    OUT R0
    MOV R0, 7
    CALL mul3           ; R0 = 7 * 3 = 21 (defined in math.o)
    OUT R0
    LOAD R1, [factor]   ; R1 = 5 (data defined in math.o)
    OUT R1
    MOV R0, 0
    HALT
