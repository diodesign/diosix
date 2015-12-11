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

.request_info_tag_start:
    ; request information from the boot loader
    dw 1	; type: Multiboot information request
    dw 0	; flags: All information must be supplied
    dd .request_info_tag_end - .request_info_tag_start ; size of this tag in bytes
    
    ; array of info types we want to know about. the boot loader
    ; will fail to start us if it cannot provide any of the requested
    ; info - so be warned.
    dd 6	; memory map information
    dd 0	; end of list
.request_info_tag_end:

    ; terminating tag
    dw 0    	; type must be zero to terminate the list
    dw 0    	; flags ignored
    dd 8    	; size must be 8
header_end:

