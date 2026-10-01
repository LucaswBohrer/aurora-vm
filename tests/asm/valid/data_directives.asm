; DB/DW/DD/DQ data, string escapes, label addressing.
    MOV R0, msg
    LOADB R1, [R0]       ; 'A'
    OUTC R1
    MOV R0, tab
    LOAD R1, [R0]        ; 8 bytes at tab
    OUT R1
    MOV R0, num
    LOAD R1, [R0]        ; 8 bytes at num (crosses into big)
    OUT R1
    MOV R0, big
    LOAD R1, [R0]        ; DQ -2
    OUT R1               ; prints "-2"
    MOV R0, 0
    HALT

msg: DB "A", 10, 0
tab: DW 0x1234, -1
num: DD -1
big: DQ -2
