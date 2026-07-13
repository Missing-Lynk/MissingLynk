ENTRY(_start)
SECTIONS {
  . = 0x00111000;
  .text   : { *(.text._start) *(.text*) }
  .rodata : { *(.rodata*) }
  .data   : { *(.data*) }
  . = ALIGN(16);
  .bss    : { *(.bss*) *(COMMON) }      /* NOBITS: not in the .bin, lives in RAM after the body */
  . = ALIGN(16);
  . = . + 0x8000;                       /* 32 KiB stack */
  . = ALIGN(16);
  _stack_top = .;
}
