; examples/runtime/exit_runtime.asm — terminate via the runtime ABI.
;
;   cat examples/runtime/exit_runtime.asm runtime/aurora_rt.asm > /tmp/l.asm
;   python3 tools/aurora-asm /tmp/l.asm -o /tmp/exit_runtime.bin
;   ./build/aurora run /tmp/exit_runtime.bin; echo $?
; Expected: no output, exit code 42, NORMAL (HALT) termination.

    MOV R0, 42
    CALL svc_exit              ; never returns
