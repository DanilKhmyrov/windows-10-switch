// 32-bit part of the test. A white screen means the CPU
// successfully switched to the mode Windows runs in (AArch32 EL1).
// r0 = 1 if the UART is available.

    .syntax unified
    .arch armv7-a
    .arm
    .text
_start:
    mov     r6, r0

    movw    r1, #0x0000
    movt    r1, #0xF5A0
    movw    r2, #(720 * 1280) & 0xFFFF
    movt    r2, #(720 * 1280) >> 16
    mvn     r3, #0
1:  str     r3, [r1], #4
    subs    r2, r2, #1
    bne     1b
    dsb     sy

    cmp     r6, #0
    beq     halt
    movw    r1, #0x6040
    movt    r1, #0x7000
    adr     r4, message
2:  ldrb    r0, [r4], #1
    cmp     r0, #0
    beq     halt
    movw    r3, #0
    movt    r3, #0x10
3:  ldr     r2, [r1, #0x14]
    tst     r2, #0x20
    bne     4f
    subs    r3, r3, #1
    bne     3b
    b       halt
4:  str     r0, [r1]
    b       2b

halt:
    wfe
    b       halt

message:
    .asciz "[wp-shim] AArch32 OK\r\n"
    .balign 4
