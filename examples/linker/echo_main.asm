; examples/linker/echo_main.asm — entry module using the runtime ABI
; as a *linked* module (phase 6 used source concatenation instead).
;
;   python3 tools/aurora-asm -c examples/linker/echo_main.asm -o /tmp/echo.o
;   python3 tools/aurora-asm -c runtime/aurora_rt.asm          -o /tmp/rt.o
;   python3 tools/aurora-ld /tmp/echo.o /tmp/rt.o -o /tmp/echo.bin
;   echo -n "hi" | ./build/aurora run /tmp/echo.bin
;
; Expected: stdout "hi", exit code 0. Empty stdin -> no output, exit 0.
;
; svc_read / svc_write / svc_exit are ordinary global symbols resolved
; by the linker; the linker knows nothing about their semantics (D26).

    MOV R0, 0                 ; fd = stdin
    MOV R1, buf               ; buf
    MOV R2, 16                ; max len
    CALL svc_read             ; R0 = n (0..16), short on EOF
    MOV R2, R0                ; len = n
    MOV R0, 1                 ; fd = stdout
    MOV R1, buf
    CALL svc_write            ; echo what was read
    MOV R0, 0
    CALL svc_exit

buf: DB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
