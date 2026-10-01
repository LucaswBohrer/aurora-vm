; examples/runtime/io_runtime.asm — echo stdin to stdout via the runtime ABI.
;
;   cat examples/runtime/io_runtime.asm runtime/aurora_rt.asm > /tmp/l.asm
;   python3 tools/aurora-asm /tmp/l.asm -o /tmp/io_runtime.bin
;   echo -n "abc" | ./build/aurora run /tmp/io_runtime.bin
; Expected: stdout "abc", exit code 0. Empty stdin -> no output, exit 0.

    MOV R0, 0                 ; fd = stdin
    MOV R1, buf               ; buf
    MOV R2, 16                ; max len
    CALL svc_read              ; R0 = n (0..16), short on EOF
    MOV R2, R0                ; len = n
    MOV R0, 1                 ; fd = stdout
    MOV R1, buf
    CALL svc_write             ; echo what was read
    MOV R0, 0
    CALL svc_exit

buf: DB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
