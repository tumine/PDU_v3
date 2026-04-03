L0: # Randomly initialize GPR
    lui         x0, 0x70089
    jal         x31, nop_block
    addi        x0, x0, 0xFFFFF800
    jal         x31, nop_block
    lui         x1, 0x5B2BD
    jal         x31, nop_block
    addi        x1, x1, 0xFFFFFEDA
    jal         x31, nop_block
    lui         x2, 0x32C89
    jal         x31, nop_block
    addi        x2, x2, 0xFFFFFC42
    jal         x31, nop_block
    lui         x3, 0x8E257
    jal         x31, nop_block
    addi        x3, x3, 0x3D2
    jal         x31, nop_block
    lui         x4, 0x97C3C
    jal         x31, nop_block
    addi        x4, x4, 0xFFFFFF83
    jal         x31, nop_block
    lui         x5, 0x2A114
    jal         x31, nop_block
    addi        x5, x5, 0xFFFFFE05
    jal         x31, nop_block
    lui         x6, 0xAE515
    jal         x31, nop_block
    addi        x6, x6, 0xFFFFFC21
    jal         x31, nop_block
    lui         x7, 0xBC80F
    jal         x31, nop_block
    addi        x7, x7, 0x494
    jal         x31, nop_block
    lui         x8, 0xEFC5
    jal         x31, nop_block
    addi        x8, x8, 0xFFFFFFE6
    jal         x31, nop_block
    lui         x9, 0xC1D0D
    jal         x31, nop_block
    addi        x9, x9, 0xFFFFF9F0
    jal         x31, nop_block
    lui         x10, 0x985AE
    jal         x31, nop_block
    addi        x10, x10, 0x3BC
    jal         x31, nop_block
    lui         x11, 0x751E8
    jal         x31, nop_block
    addi        x11, x11, 0x52F
    jal         x31, nop_block
    lui         x12, 0x4C10F
    jal         x31, nop_block
    addi        x12, x12, 0x25E
    jal         x31, nop_block
    lui         x13, 0x85969
    jal         x31, nop_block
    addi        x13, x13, 0x62D
    jal         x31, nop_block
    lui         x14, 0xE29B1
    jal         x31, nop_block
    addi        x14, x14, 0x519
    jal         x31, nop_block
    lui         x15, 0xE577E
    jal         x31, nop_block
    addi        x15, x15, 0x5BA
    jal         x31, nop_block
    lui         x16, 0x443E1
    jal         x31, nop_block
    addi        x16, x16, 0x746
    jal         x31, nop_block
    lui         x17, 0x2D2AD
    jal         x31, nop_block
    addi        x17, x17, 0xFFFFF95A
    jal         x31, nop_block
    lui         x18, 0xB0F45
    jal         x31, nop_block
    addi        x18, x18, 0x6D4
    jal         x31, nop_block
    lui         x19, 0x2634C
    jal         x31, nop_block
    addi        x19, x19, 0x5E7
    jal         x31, nop_block
    lui         x20, 0x1697F
    jal         x31, nop_block
    addi        x20, x20, 0xFFFFF9A6
    jal         x31, nop_block
    lui         x21, 0x3DC8
    jal         x31, nop_block
    addi        x21, x21, 0xFFFFF91B
    jal         x31, nop_block
    lui         x22, 0xC58FF
    jal         x31, nop_block
    addi        x22, x22, 0x797
    jal         x31, nop_block
    lui         x23, 0x5C44B
    jal         x31, nop_block
    addi        x23, x23, 0x1A7
    jal         x31, nop_block
    lui         x24, 0x738B7
    jal         x31, nop_block
    addi        x24, x24, 0x3CE
    jal         x31, nop_block
    lui         x25, 0x60CFA
    jal         x31, nop_block
    addi        x25, x25, 0x49E
    jal         x31, nop_block
    lui         x26, 0x8F197
    jal         x31, nop_block
    addi        x26, x26, 0x62
    jal         x31, nop_block
    lui         x27, 0x658B9
    jal         x31, nop_block
    addi        x27, x27, 0xFFFFFB15
    jal         x31, nop_block
    lui         x28, 0x4B2AD
    jal         x31, nop_block
    addi        x28, x28, 0xFFFFFBF0
    jal         x31, nop_block
    lui         x29, 0xAA312
    jal         x31, nop_block
    addi        x29, x29, 0xFFFFFA1A
    jal         x31, nop_block
    lui         x30, 0x36906
    jal         x31, nop_block
    addi        x30, x30, 0x274
    jal         x31, nop_block
    #lui         x31, 0xD2C2A
    #jal         x31, nop_block
    #addi        x31, x31, 0xFFFFFBB5
    #jal         x31, nop_block
L1: # Test 0-0: add
    add         x25, x14, x7
    jal         x31, nop_block
    lui         x24, 0x9F1C1
    jal         x31, nop_block
    addi        x24, x24, 0xFFFFF9AD
    jal         x31, nop_block
    bne         x25, x24, fail
    jal         x31, nop_block
L2: # Test 0-1: add
    add         x24, x27, x20
    jal         x31, nop_block
    lui         x28, 0x7C237
    jal         x31, nop_block
    addi        x28, x28, 0x4BB
    jal         x31, nop_block
    bne         x24, x28, fail
    jal         x31, nop_block
L3: # Test 0-2: add
    add         x29, x2, x29
    jal         x31, nop_block
    lui         x14, 0xDCF9A
    jal         x31, nop_block
    addi        x14, x14, 0x65C
    jal         x31, nop_block
    bne         x29, x14, fail
    jal         x31, nop_block
L4: # Test 1-0: sub
    sub         x27, x6, x18
    jal         x31, nop_block
    lui         x22, 0xFD5CF
    jal         x31, nop_block
    addi        x22, x22, 0x54D
    jal         x31, nop_block
    bne         x27, x22, fail
    jal         x31, nop_block
L5: # Test 1-1: sub
    sub         x13, x7, x11
    jal         x31, nop_block
    lui         x26, 0x47627
    jal         x31, nop_block
    addi        x26, x26, 0xFFFFFF65
    jal         x31, nop_block
    bne         x13, x26, fail
    jal         x31, nop_block
L6: # Test 1-2: sub
    sub         x23, x6, x0
    jal         x31, nop_block
    lui         x15, 0xAE515
    jal         x31, nop_block
    addi        x15, x15, 0xFFFFFC21
    jal         x31, nop_block
    bne         x23, x15, fail
    jal         x31, nop_block
L7: # Test 2-0: sll
    sll         x26, x20, x10
    jal         x31, nop_block
    lui         x25, 0x60000
    jal         x31, nop_block
    addi        x25, x25, 0x0
    jal         x31, nop_block
    bne         x26, x25, fail
    jal         x31, nop_block
L8: # Test 2-1: sll
    sll         x0, x15, x29
    jal         x31, nop_block
    lui         x19, 0x0
    jal         x31, nop_block
    addi        x19, x19, 0x0
    jal         x31, nop_block
    bne         x0, x19, fail
    jal         x31, nop_block
L9: # Test 2-2: sll
    sll         x24, x14, x6
    jal         x31, nop_block
    lui         x4, 0xB9F35
    jal         x31, nop_block
    addi        x4, x4, 0xFFFFFCB8
    jal         x31, nop_block
    bne         x24, x4, fail
    jal         x31, nop_block
L10: # Test 3-0: srl
    srl         x18, x3, x4
    jal         x31, nop_block
    lui         x22, 0x0
    jal         x31, nop_block
    addi        x22, x22, 0x8E
    jal         x31, nop_block
    bne         x18, x22, fail
    jal         x31, nop_block
L11: # Test 3-1: srl
    srl         x2, x10, x12
    jal         x31, nop_block
    lui         x28, 0x0
    jal         x31, nop_block
    addi        x28, x28, 0x2
    jal         x31, nop_block
    bne         x2, x28, fail
    jal         x31, nop_block
L12: # Test 3-2: srl
    srl         x27, x23, x9
    jal         x31, nop_block
    lui         x22, 0xB
    jal         x31, nop_block
    addi        x22, x22, 0xFFFFFE51
    jal         x31, nop_block
    bne         x27, x22, fail
    jal         x31, nop_block
L13: # Test 4-0: sra
    sra         x11, x25, x3
    jal         x31, nop_block
    lui         x21, 0x2
    jal         x31, nop_block
    addi        x21, x21, 0xFFFFF800
    jal         x31, nop_block
    bne         x11, x21, fail
    jal         x31, nop_block
L14: # Test 4-1: sra
    sra         x5, x4, x4
    jal         x31, nop_block
    lui         x7, 0x0
    jal         x31, nop_block
    addi        x7, x7, 0xFFFFFFB9
    jal         x31, nop_block
    bne         x5, x7, fail
    jal         x31, nop_block
L15: # Test 4-2: sra
    sra         x30, x4, x21
    jal         x31, nop_block
    lui         x11, 0xB9F35
    jal         x31, nop_block
    addi        x11, x11, 0xFFFFFCB8
    jal         x31, nop_block
    bne         x30, x11, fail
    jal         x31, nop_block
L16: # Test 5-0: slt
    slt         x27, x3, x20
    jal         x31, nop_block
    lui         x19, 0x0
    jal         x31, nop_block
    addi        x19, x19, 0x1
    jal         x31, nop_block
    bne         x27, x19, fail
    jal         x31, nop_block
L17: # Test 5-1: slt
    slt         x16, x2, x10
    jal         x31, nop_block
    lui         x3, 0x0
    jal         x31, nop_block
    addi        x3, x3, 0x0
    jal         x31, nop_block
    bne         x16, x3, fail
    jal         x31, nop_block
L18: # Test 5-2: slt
    slt         x12, x16, x20
    jal         x31, nop_block
    lui         x16, 0x0
    jal         x31, nop_block
    addi        x16, x16, 0x1
    jal         x31, nop_block
    bne         x12, x16, fail
    jal         x31, nop_block
L19: # Test 5-3: slt
    slt         x28, x12, x22
    jal         x31, nop_block
    lui         x8, 0x0
    jal         x31, nop_block
    addi        x8, x8, 0x1
    jal         x31, nop_block
    bne         x28, x8, fail
    jal         x31, nop_block
L20: # Test 6-0: sltu
    sltu        x6, x25, x14
    jal         x31, nop_block
    lui         x11, 0x0
    jal         x31, nop_block
    addi        x11, x11, 0x1
    jal         x31, nop_block
    bne         x6, x11, fail
    jal         x31, nop_block
L21: # Test 6-1: sltu
    sltu        x29, x3, x8
    jal         x31, nop_block
    lui         x15, 0x0
    jal         x31, nop_block
    addi        x15, x15, 0x1
    jal         x31, nop_block
    bne         x29, x15, fail
    jal         x31, nop_block
L22: # Test 6-2: sltu
    sltu        x27, x16, x25
    jal         x31, nop_block
    lui         x2, 0x0
    jal         x31, nop_block
    addi        x2, x2, 0x1
    jal         x31, nop_block
    bne         x27, x2, fail
    jal         x31, nop_block
L23: # Test 6-3: sltu
    sltu        x11, x10, x7
    jal         x31, nop_block
    lui         x25, 0x0
    jal         x31, nop_block
    addi        x25, x25, 0x1
    jal         x31, nop_block
    bne         x11, x25, fail
    jal         x31, nop_block
L24: # Test 7-0: and
    and         x20, x3, x7
    jal         x31, nop_block
    lui         x14, 0x0
    jal         x31, nop_block
    addi        x14, x14, 0x0
    jal         x31, nop_block
    bne         x20, x14, fail
    jal         x31, nop_block
L25: # Test 7-1: and
    and         x9, x14, x5
    jal         x31, nop_block
    lui         x13, 0x0
    jal         x31, nop_block
    addi        x13, x13, 0x0
    jal         x31, nop_block
    bne         x9, x13, fail
    jal         x31, nop_block
L26: # Test 7-2: and
    #and         x11, x11, x9
    #jal         x31, nop_block
    #lui         x31, 0x0
    #jal         x31, nop_block
    #addi        x31, x31, 0x0
    #jal         x31, nop_block
    #bne         x11, x31, fail
    #jal         x31, nop_block
L27: # Test 8-0: or
    or          x17, x15, x27
    jal         x31, nop_block
    lui         x30, 0x0
    jal         x31, nop_block
    addi        x30, x30, 0x1
    jal         x31, nop_block
    bne         x17, x30, fail
    jal         x31, nop_block
L28: # Test 8-1: or
    or          x20, x15, x5
    jal         x31, nop_block
    lui         x19, 0x0
    jal         x31, nop_block
    addi        x19, x19, 0xFFFFFFB9
    jal         x31, nop_block
    bne         x20, x19, fail
    jal         x31, nop_block
L29: # Test 8-2: or
    or          x3, x14, x13
    jal         x31, nop_block
    lui         x11, 0x0
    jal         x31, nop_block
    addi        x11, x11, 0x0
    jal         x31, nop_block
    bne         x3, x11, fail
    jal         x31, nop_block
L30: # Test 9-0: xor
    xor         x14, x15, x0
    jal         x31, nop_block
    lui         x18, 0x0
    jal         x31, nop_block
    addi        x18, x18, 0x1
    jal         x31, nop_block
    bne         x14, x18, fail
    jal         x31, nop_block
L31: # Test 9-1: xor
    xor         x6, x15, x29
    jal         x31, nop_block
    lui         x24, 0x0
    jal         x31, nop_block
    addi        x24, x24, 0x0
    jal         x31, nop_block
    bne         x6, x24, fail
    jal         x31, nop_block
L32: # Test 9-2: xor
    xor         x16, x26, x20
    jal         x31, nop_block
    lui         x5, 0xA0000
    jal         x31, nop_block
    addi        x5, x5, 0xFFFFFFB9
    jal         x31, nop_block
    bne         x16, x5, fail
    jal         x31, nop_block
L33: # Test 10-0: addi
    #addi        x28, x12, 0x3A1
    #jal         x31, nop_block
    #lui         x31, 0x0
    #jal         x31, nop_block
    #addi        x31, x31, 0x3A2
    #jal         x31, nop_block
    #bne         x28, x31, fail
    #jal         x31, nop_block
L34: # Test 10-1: addi
    addi    x15, x15, 0xFFFFFE71
    jal         x31, nop_block
    lui         x30, 0x0
    jal         x31, nop_block
    addi        x30, x30, 0xFFFFFE72
    jal         x31, nop_block
    bne         x15, x30, fail
    jal         x31, nop_block
L35: # Test 10-2: addi
    #addi        x31, x2, 0x4A1
    #jal         x31, nop_block
    #lui         x19, 0x0
    #jal         x31, nop_block
    #addi        x19, x19, 0x4A2
    #jal         x31, nop_block
    #bne         x31, x19, fail
    #jal         x31, nop_block
L36: # Test 10-3: addi
    addi        x30, x28, 0xFFFFFEB3
    jal         x31, nop_block
    lui         x28, 0x0
    jal         x31, nop_block
    addi        x28, x28, 0x255
    jal         x31, nop_block
    bne         x30, x28, fail
    jal         x31, nop_block
L37: # Test 11-0: slli
    slli        x1, x20, 0xB
    jal         x31, nop_block
    lui         x27, 0xFFFDD
    jal         x31, nop_block
    addi        x27, x27, 0xFFFFF800
    jal         x31, nop_block
    bne         x1, x27, fail
    jal         x31, nop_block
L38: # Test 11-1: slli
    slli        x13, x16, 0x4
    jal         x31, nop_block
    lui         x12, 0x0
    jal         x31, nop_block
    addi        x12, x12, 0xFFFFFB90
    jal         x31, nop_block
    bne         x13, x12, fail
    jal         x31, nop_block
L39: # Test 11-2: slli
    slli        x30, x2, 0x1
    jal         x31, nop_block
    lui         x23, 0x0
    jal         x31, nop_block
    addi        x23, x23, 0x2
    jal         x31, nop_block
    bne         x30, x23, fail
    jal         x31, nop_block
L40: # Test 11-3: slli
    slli        x25, x24, 0x11
    jal         x31, nop_block
    lui         x30, 0x0
    jal         x31, nop_block
    addi        x30, x30, 0x0
    jal         x31, nop_block
    bne         x25, x30, fail
    jal         x31, nop_block
L41: # Test 11-4: slli
    slli        x27, x27, 0x1A
    jal         x31, nop_block
    lui         x21, 0x0
    jal         x31, nop_block
    addi        x21, x21, 0x0
    jal         x31, nop_block
    bne         x27, x21, fail
    jal         x31, nop_block
L42: # Test 12-0: srli
    srli        x10, x23, 0x19
    jal         x31, nop_block
    lui         x18, 0x0
    jal         x31, nop_block
    addi        x18, x18, 0x0
    jal         x31, nop_block
    bne         x10, x18, fail
    jal         x31, nop_block
L43: # Test 12-1: srli
    srli        x23, x1, 0x1F
    jal         x31, nop_block
    lui         x27, 0x0
    jal         x31, nop_block
    addi        x27, x27, 0x1
    jal         x31, nop_block
    bne         x23, x27, fail
    jal         x31, nop_block
L44: # Test 12-2: srli
    srli        x2, x17, 0x0
    jal         x31, nop_block
    lui         x25, 0x0
    jal         x31, nop_block
    addi        x25, x25, 0x1
    jal         x31, nop_block
    bne         x2, x25, fail
    jal         x31, nop_block
L45: # Test 12-3: srli
    srli        x9, x20, 0x13
    jal         x31, nop_block
    lui         x4, 0x2
    jal         x31, nop_block
    addi        x4, x4, 0xFFFFFFFF
    jal         x31, nop_block
    bne         x9, x4, fail
    jal         x31, nop_block
L46: # Test 12-4: srli
    srli        x6, x10, 0x18
    jal         x31, nop_block
    lui         x18, 0x0
    jal         x31, nop_block
    addi        x18, x18, 0x0
    jal         x31, nop_block
    bne         x6, x18, fail
    jal         x31, nop_block
L47: # Test 13-0: srai
    srai        x28, x13, 0x1C
    jal         x31, nop_block
    lui         x8, 0x0
    jal         x31, nop_block
    addi        x8, x8, 0xFFFFFFFF
    jal         x31, nop_block
    bne         x28, x8, fail
    jal         x31, nop_block
L48: # Test 13-1: srai
    #srai        x25, x31, 0x1F
    #jal         x31, nop_block
    #lui         x13, 0x0
    #jal         x31, nop_block
    #addi        x13, x13, 0x0
    #jal         x31, nop_block
    #bne         x25, x13, fail
    #jal         x31, nop_block
L49: # Test 13-2: srai
    srai        x22, x9, 0x2
    jal         x31, nop_block
    lui         x9, 0x0
    jal         x31, nop_block
    addi        x9, x9, 0x7FF
    jal         x31, nop_block
    bne         x22, x9, fail
    jal         x31, nop_block
L50: # Test 13-3: srai
    srai        x15, x24, 0x1D
    jal         x31, nop_block
    lui         x10, 0x0
    jal         x31, nop_block
    addi        x10, x10, 0x0
    jal         x31, nop_block
    bne         x15, x10, fail
    jal         x31, nop_block
L51: # Test 13-4: srai
    srai        x12, x15, 0x19
    jal         x31, nop_block
    lui         x29, 0x0
    jal         x31, nop_block
    addi        x29, x29, 0x0
    jal         x31, nop_block
    bne         x12, x29, fail
    jal         x31, nop_block
L52: # Test 14-0: slti
    slti        x1, x30, 0xFFFFF801
    jal         x31, nop_block
    lui         x30, 0x0
    jal         x31, nop_block
    addi        x30, x30, 0x0
    jal         x31, nop_block
    bne         x1, x30, fail
    jal         x31, nop_block
L53: # Test 14-1: slti
    slti        x1, x19, 0x52D
    jal         x31, nop_block
    lui         x18, 0x0
    jal         x31, nop_block
    addi        x18, x18, 0x1
    jal         x31, nop_block
    bne         x1, x18, fail
    jal         x31, nop_block
L54: # Test 14-2: slti
    slti        x19, x8, 0x36
    jal         x31, nop_block
    lui         x13, 0x0
    jal         x31, nop_block
    addi        x13, x13, 0x1
    jal         x31, nop_block
    bne         x19, x13, fail
    jal         x31, nop_block
L55: # Test 14-3: slti
    slti        x30, x18, 0x482
    jal         x31, nop_block
    lui         x8, 0x0
    jal         x31, nop_block
    addi        x8, x8, 0x1
    jal         x31, nop_block
    bne         x30, x8, fail
    jal         x31, nop_block
L56: # Test 14-4: slti
    slti        x25, x11, 0xFFFFFC93
    jal         x31, nop_block
    lui         x4, 0x0
    jal         x31, nop_block
    addi        x4, x4, 0x0
    jal         x31, nop_block
    bne         x25, x4, fail
    jal         x31, nop_block
L57: # Test 15-0: sltiu
    sltiu       x28, x5, 0xFFFFFF37
    jal         x31, nop_block
    lui         x11, 0x0
    jal         x31, nop_block
    addi        x11, x11, 0x1
    jal         x31, nop_block
    bne         x28, x11, fail
    jal         x31, nop_block
L58: # Test 15-1: sltiu
    sltiu       x25, x7, 0x313
    jal         x31, nop_block
    lui         x19, 0x0
    jal         x31, nop_block
    addi        x19, x19, 0x0
    jal         x31, nop_block
    bne         x25, x19, fail
    jal         x31, nop_block
L59: # Test 15-2: sltiu
    sltiu       x10, x22, 0x74
    jal         x31, nop_block
    lui         x6, 0x0
    jal         x31, nop_block
    addi        x6, x6, 0x0
    jal         x31, nop_block
    bne         x10, x6, fail
    jal         x31, nop_block
L60: # Test 15-3: sltiu
    sltiu       x22, x20, 0x309
    jal         x31, nop_block
    lui         x9, 0x0
    jal         x31, nop_block
    addi        x9, x9, 0x0
    jal         x31, nop_block
    bne         x22, x9, fail
    jal         x31, nop_block
L61: # Test 15-4: sltiu
    sltiu       x2, x17, 0xFFFFFF70
    jal         x31, nop_block
    lui         x28, 0x0
    jal         x31, nop_block
    addi        x28, x28, 0x1
    jal         x31, nop_block
    bne         x2, x28, fail
    jal         x31, nop_block
L62: # Test 16-0: andi
    andi        x12, x6, 0x2E5
    jal         x31, nop_block
    lui         x4, 0x0
    jal         x31, nop_block
    addi        x4, x4, 0x0
    jal         x31, nop_block
    bne         x12, x4, fail
    jal         x31, nop_block
L63: # Test 16-1: andi
    andi        x7, x6, 0xFFFFFE7C
    jal         x31, nop_block
    lui         x13, 0x0
    jal         x31, nop_block
    addi        x13, x13, 0x0
    jal         x31, nop_block
    bne         x7, x13, fail
    jal         x31, nop_block
L64: # Test 16-2: andi
    andi        x21, x17, 0xFFFFFA65
    jal         x31, nop_block
    lui         x20, 0x0
    jal         x31, nop_block
    addi        x20, x20, 0x1
    jal         x31, nop_block
    bne         x21, x20, fail
    jal         x31, nop_block
L65: # Test 16-3: andi
    andi        x16, x29, 0x697
    jal         x31, nop_block
    lui         x2, 0x0
    jal         x31, nop_block
    addi        x2, x2, 0x0
    jal         x31, nop_block
    bne         x16, x2, fail
    jal         x31, nop_block
L66: # Test 16-4: andi
    andi        x28, x20, 0x300
    jal         x31, nop_block
    lui         x16, 0x0
    jal         x31, nop_block
    addi        x16, x16, 0x0
    jal         x31, nop_block
    bne         x28, x16, fail
    jal         x31, nop_block
L67: # Test 17-0: ori
    ori         x2, x7, 0xFFFFF831
    jal         x31, nop_block
    lui         x27, 0x0
    jal         x31, nop_block
    addi        x27, x27, 0xFFFFF831
    jal         x31, nop_block
    bne         x2, x27, fail
    jal         x31, nop_block
L68: # Test 17-1: ori
    ori         x26, x28, 0x56D
    jal         x31, nop_block
    lui         x11, 0x0
    jal         x31, nop_block
    addi        x11, x11, 0x56D
    jal         x31, nop_block
    bne         x26, x11, fail
    jal         x31, nop_block
L69: # Test 17-2: ori
    ori         x24, x20, 0x73B
    jal         x31, nop_block
    lui         x2, 0x0
    jal         x31, nop_block
    addi        x2, x2, 0x73B
    jal         x31, nop_block
    bne         x24, x2, fail
    jal         x31, nop_block
L70: # Test 17-3: ori
    ori         x28, x0, 0xFFFFFB79
    jal         x31, nop_block
    lui         x21, 0x0
    jal         x31, nop_block
    addi        x21, x21, 0xFFFFFB79
    jal         x31, nop_block
    bne         x28, x21, fail
    jal         x31, nop_block
L71: # Test 17-4: ori
    ori         x11, x10, 0x5B8
    jal         x31, nop_block
    lui         x10, 0x0
    jal         x31, nop_block
    addi        x10, x10, 0x5B8
    jal         x31, nop_block
    bne         x11, x10, fail
    jal         x31, nop_block
L72: # Test 18-0: xori
    xori        x22, x4, 0xFFFFFBB7
    jal         x31, nop_block
    lui         x24, 0x0
    jal         x31, nop_block
    addi        x24, x24, 0xFFFFFBB7
    jal         x31, nop_block
    bne         x22, x24, fail
    jal         x31, nop_block
L73: # Test 18-1: xori
    xori        x22, x21, 0x1A7
    jal         x31, nop_block
    lui         x12, 0x0
    jal         x31, nop_block
    addi        x12, x12, 0xFFFFFADE
    jal         x31, nop_block
    bne         x22, x12, fail
    jal         x31, nop_block
L74: # Test 18-2: xori
    xori        x28, x26, 0xFFFFFE82
    jal         x31, nop_block
    lui         x24, 0x0
    jal         x31, nop_block
    addi        x24, x24, 0xFFFFFBEF
    jal         x31, nop_block
    bne         x28, x24, fail
    jal         x31, nop_block
L75: # Test 18-3: xori
    xori        x21, x26, 0x511
    jal         x31, nop_block
    lui         x22, 0x0
    jal         x31, nop_block
    addi        x22, x22, 0x7C
    jal         x31, nop_block
    bne         x21, x22, fail
    jal         x31, nop_block
L76: # Test 18-4: xori
    xori        x7, x14, 0x402
    jal         x31, nop_block
    lui         x14, 0x0
    jal         x31, nop_block
    addi        x14, x14, 0x403
    jal         x31, nop_block
    bne         x7, x14, fail
    jal         x31, nop_block
L77: # Test 19-0: lui
    lui         x20, 0xEC775
    jal         x31, nop_block
    lui         x14, 0xEC775
    jal         x31, nop_block
    addi        x14, x14, 0x0
    jal         x31, nop_block
    bne         x20, x14, fail
    jal         x31, nop_block
L78: # Test 19-1: lui
    lui         x13, 0x1D5EA
    jal         x31, nop_block
    lui         x14, 0x1D5EA
    jal         x31, nop_block
    addi        x14, x14, 0x0
    jal         x31, nop_block
    bne         x13, x14, fail
    jal         x31, nop_block
L79: # Test 19-2: lui
    lui         x7, 0x85528
    jal         x31, nop_block
    lui         x3, 0x85528
    jal         x31, nop_block
    addi        x3, x3, 0x0
    jal         x31, nop_block
    bne         x7, x3, fail
    jal         x31, nop_block
L80: # Test 19-3: lui
    lui         x4, 0x6F627
    jal         x31, nop_block
    lui         x7, 0x6F627
    jal         x31, nop_block
    addi        x7, x7, 0x0
    jal         x31, nop_block
    bne         x4, x7, fail
    jal         x31, nop_block
L81: # Test 19-4: lui
    lui         x24, 0xEBB3A
    jal         x31, nop_block
    lui         x17, 0xEBB3A
    jal         x31, nop_block
    addi        x17, x17, 0x0
    jal         x31, nop_block
    bne         x24, x17, fail
    jal         x31, nop_block
L82: # Test 20-0: auipc
    auipc       x27, 0xC8173
    jal         x31, nop_block
    lui         x14, 0xC8573
    jal         x31, nop_block
    addi        x14, x14, 0x610
    jal         x31, nop_block
    bne         x27, x14, fail
    jal         x31, nop_block
L83: # Test 20-1: auipc
    auipc       x3, 0x15FB9
    jal         x31, nop_block
    lui         x1, 0x163B9
    jal         x31, nop_block
    addi        x1, x1, 0x620
    jal         x31, nop_block
    bne         x3, x1, fail
    jal         x31, nop_block
L84: # Test 20-2: auipc
    auipc       x14, 0xDCB52
    jal         x31, nop_block
    lui         x2, 0xDCF52
    jal         x31, nop_block
    addi        x2, x2, 0x630
    jal         x31, nop_block
    bne         x14, x2, fail
    jal         x31, nop_block
L85: # Test 20-3: auipc
    auipc       x7, 0x79FEC
    jal         x31, nop_block
    lui         x5, 0x7A3EC
    jal         x31, nop_block
    addi        x5, x5, 0x640
    jal         x31, nop_block
    bne         x7, x5, fail
    jal         x31, nop_block
L86: # Test 20-4: auipc
    auipc       x22, 0x4736D
    jal         x31, nop_block
    lui         x20, 0x4776D
    jal         x31, nop_block
    addi        x20, x20, 0x650
    jal         x31, nop_block
    bne         x22, x20, fail
    jal         x31, nop_block
win: # Win label
    lui         x4, 0x0
    jal         x31, nop_block
    addi        x4, x4, 0x0
    jal         x31, nop_block
    j           end
fail: # Fail label
    lui         x4, 0x0
    jal         x31, nop_block
    addi        x4, x4, 0xFFFFFFFF
    jal         x31, nop_block
    j           end
end:
    ebreak

# 10个NOP组成的指令块
nop_block:
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    jalr        x0, x31, 0