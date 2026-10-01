; Forward label references (two-pass resolution).
    JMP end
    MOV R0, 99
end:
    MOV R0, 7
    OUT R0
    HALT
