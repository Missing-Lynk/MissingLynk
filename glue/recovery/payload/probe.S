/* Freestanding aarch64 probe: print "PROBE-OK" via the goggle UART @0x01500000 CONTINUOUSLY.
   The UART is left at the BootROM's 115200 (we do NOT reconfigure baud), so monitor at 115200.
   Confirms the BootROM validates + executes our custom .GMI image. Load/entry = 0x00111000.
*/
.section .text
.global _start
_start:
restart:
    adr     x19, msg
charloop:
    ldrb    w0, [x19], #1
    cbz     w0, restart           /* end of string -> print it again (continuous) */
    bl      putc
    b       charloop
putc:
    movz    x9, #0x0150, lsl #16  /* UART base 0x01500000 */
1:  ldr     w10, [x9, #0x14]      /* TX status (reg+0x14) */
    tbz     w10, #5, 1b           /* wait TX-ready (bit5) */
    str     w0, [x9]              /* data reg (reg+0) */
    ret
msg: .asciz "PROBE-OK "
