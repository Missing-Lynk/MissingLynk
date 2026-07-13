ENTRY(_start)
SECTIONS { . = 0x00111000; .text : { *(.text*) } .rodata : { *(.rodata*) } .data : { *(.data*) } }
