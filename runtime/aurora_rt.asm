; ============================================================================
; AURORA Runtime Library — ABI v1 (guest-side)
;
; Services offered by the AURORA runtime, implemented entirely with the
; frozen ISA (43 opcodes, no traps, no new instructions). A service is an
; ordinary function: the guest CALLs its entry point following the ABI
; contract documented in docs/RUNTIME.md.
;
; Linking (static, by concatenation — the assembler has no INCLUDE):
;
;     cat prog.asm runtime/aurora_rt.asm > /tmp/linked.asm
;     python3 tools/aurora-asm /tmp/linked.asm -o prog.bin
;
; Order does not matter for label resolution (two-pass assembly); the guest program comes first so entry point 0 is guest code.
; Labels starting with `svc_` are reserved by the runtime; guest programs
; must not define them. (Labels may not start with R/r — the assembler
; parses those as register operands.)
;
; Why guest-side? The frozen ISA has no trap/syscall instruction and no
; reserved CALL target: every CALL target must satisfy
; `addr < code_size && addr % 8 == 0` (ISA §6.8, loader-enforced), and
; IN/OUT/OUTC/HALT semantics cannot be extended without altering the ISA
; (see D26). The compatible mechanism is therefore a calling convention
; over existing instructions. The host boundary stays exactly where the
; ISA puts it: IN ↔ stdin, OUT/OUTC ↔ stdout, HALT ↔ process exit.
; ============================================================================

; ----------------------------------------------------------------------------
; svc_exit — terminate the guest via the runtime.
;
;   Input:  R0 = exit status (only R0 & 0xFF reaches the process exit code)
;   Output: never returns
;
;   Termination: NORMAL (HALT), exit code = R0 & 0xFF  [D22].
;   A HALT is never a fatal error, for any R0 value.
; ----------------------------------------------------------------------------
svc_exit:
    HALT

; ----------------------------------------------------------------------------
; svc_write — structured byte output.
;
;   Input:  R0 = fd   (1 = stdout; the only logical destination in ABI v1)
;           R1 = buf  (guest virtual address of the first byte)
;           R2 = len  (number of bytes)
;   Output: R0 = bytes written (== len), or -1 (0xFFFFFFFFFFFFFFFF) on error
;
;   Recoverable errors (returned in R0, never fatal):
;     -1   fd != 1
;     -1   len > 0x10000, or [buf, buf+len) not fully inside [0, 0x10000)
;          (wraparound-safe check, same rule as ISA §5)
;
;   Notes:
;     - len == 0 returns 0 (fd is still validated).
;     - Bytes are emitted with OUTC, one per byte. A host write failure
;       raises IO_ERROR (fatal), exactly as if the guest had executed
;       OUTC itself [ISA §6.10]. The runtime adds no new fatal errors.
;     - The buffer is read with LOADB; reads from the code segment are
;       allowed by the ISA, so this path can never raise WRITE_TO_CODE.
;
;   Preserves: R3-R15, SP, FP (stack balanced; uses 16 bytes of guest stack,
;              so the caller needs SP >= 0xF000 + 16 or PUSH faults with
;              STACK_OVERFLOW, as for any nested call).
;   Clobbers:  R0 (return value), R1/R2 (argument/scratch registers), FLAGS
;              (the ISA has no FLAGS save/restore; any loop needs CMP/SUB,
;              so FLAGS are documented clobbered).
; ----------------------------------------------------------------------------
svc_write:
    PUSH R3
    PUSH R4
    CMP R0, 1
    JNE svc_write_err           ; fd != 1 -> -1
    CMP R2, 0
    JE svc_write_zero           ; len == 0 -> 0
    JL svc_write_err            ; len >= 2^63 (bit 63 set) -> -1
    ; Unsigned bounds check without wraparound: len <= 0x10000 and
    ; buf <= 0x10000 - len. len/buf with bit 63 set are rejected first, so
    ; the signed jumps below are exact for the remaining range.
    MOV R3, 0x10000
    CMP R2, R3
    JG svc_write_err            ; len > 0x10000 -> -1
    SUB R3, R2                  ; R3 = 0x10000 - len (cannot wrap now)
    CMP R1, 0
    JL svc_write_err            ; buf >= 2^63 -> -1
    CMP R1, R3
    JG svc_write_err            ; buf > 0x10000 - len -> -1
    MOV R4, R2                  ; R4 = remaining (R2 keeps original len)
svc_write_loop:
    LOADB R3, [R1]
    OUTC R3
    ADD R1, 1
    SUB R4, 1                   ; sets Z when the last byte was emitted
    JNE svc_write_loop
    MOV R0, R2                  ; bytes written == original len
    POP R4
    POP R3
    RET
svc_write_zero:
    MOV R0, 0
    POP R4
    POP R3
    RET
svc_write_err:
    MOV R0, -1
    POP R4
    POP R3
    RET

; ----------------------------------------------------------------------------
; svc_read — structured byte input.
;
;   Input:  R0 = fd   (0 = stdin; the only logical source in ABI v1)
;           R1 = buf  (guest virtual address to store into)
;           R2 = len  (max number of bytes)
;   Output: R0 = bytes actually read (0..len), or -1 on error
;
;   Recoverable errors (returned in R0, never fatal):
;     -1   fd != 0
;     -1   len > 0x10000, or [buf, buf+len) not fully inside [0, 0x10000)
;
;   Notes:
;     - len == 0 returns 0 without touching the buffer.
;     - EOF (IN yields 0xFFFFFFFFFFFFFFFF) ends the read; a short count —
;       possibly 0 — is returned. Empty stdin is NOT an error, matching
;       ISA §6.10 and the existing EOF tests.
;     - Bytes are stored with STOREB. A store intersecting the code segment
;       raises WRITE_TO_CODE (fatal), exactly as a direct guest STOREB
;       would [ISA §6.6]. The runtime does not mask ISA faults.
;     - A host read failure raises IO_ERROR (fatal), as for IN [ISA §6.10].
;
;   Preserves: R3-R15, SP, FP (16 bytes of guest stack).
;   Clobbers:  R0 (return value), R1/R2 (argument/scratch), FLAGS.
; ----------------------------------------------------------------------------
svc_read:
    PUSH R3
    PUSH R4
    CMP R0, 0
    JNE svc_read_err            ; fd != 0 -> -1
    CMP R2, 0
    JE svc_read_zero            ; len == 0 -> 0
    JL svc_read_err             ; len >= 2^63 -> -1
    MOV R3, 0x10000
    CMP R2, R3
    JG svc_read_err             ; len > 0x10000 -> -1
    SUB R3, R2                  ; R3 = 0x10000 - len
    CMP R1, 0
    JL svc_read_err             ; buf >= 2^63 -> -1
    CMP R1, R3
    JG svc_read_err             ; buf > 0x10000 - len -> -1
    MOV R4, R2                  ; R4 = remaining
svc_read_loop:
    CMP R4, 0
    JE svc_read_done
    IN R3                       ; R3 = byte, or 0xFFFF...FF on EOF
    CMP R3, -1
    JE svc_read_done            ; EOF -> short count
    STOREB [R1], R3
    ADD R1, 1
    SUB R4, 1
    JMP svc_read_loop
svc_read_done:
    MOV R0, R2
    SUB R0, R4                  ; bytes read = len - remaining
    POP R4
    POP R3
    RET
svc_read_zero:
    MOV R0, 0
    POP R4
    POP R3
    RET
svc_read_err:
    MOV R0, -1
    POP R4
    POP R3
    RET
