/* C-payload entry: set up a stack (the BootROM blr's us with no sp), call payload_main, hang. */
.section .text._start
.global _start
_start:
    adrp    x0, _stack_top
    add     x0, x0, #:lo12:_stack_top
    mov     sp, x0
    bl      payload_main
hang:
    b       hang
