; examples/runtime/hello_runtime.asm — "Hello" via the runtime ABI.
;
; Assemble with the GUEST FIRST (entry 0 = guest code):
;   cat examples/runtime/hello_runtime.asm runtime/aurora_rt.asm > /tmp/l.asm
;   python3 tools/aurora-asm /tmp/l.asm -o /tmp/hello_runtime.bin
;   ./build/aurora run /tmp/hello_runtime.bin
; Expected: stdout "Hello, runtime!\n", exit code 0.

    MOV R0, 1                 ; fd = stdout
    MOV R1, msg               ; buf
    MOV R2, 16                ; len
    CALL svc_write             ; R0 = 16
    MOV R0, 0
    CALL svc_exit              ; NORMAL (HALT), exit 0

msg: DB "Hello, runtime!", 10
