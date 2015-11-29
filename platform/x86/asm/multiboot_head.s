;
; diosix microkernel 'menchi'
;
; Multiboot header for x86 machines
;
; Maintainer: Chris Williams <diodesign@gmail.com>
;

section .multiboot_head
header_start:
    dd 0xe85250d6                ; magic number for multiboot 2
    dd 0                         ; architecture 0 = protected mode i386
    dd header_end - header_start ; header length
    ; checksum
    dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start))

    ; terminating tag
    dw 0    ; type
    dw 0    ; flags
    dd 8    ; size
header_end:

