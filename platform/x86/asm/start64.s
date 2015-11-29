; diosix microkernel 'menchi'
;
; Continue booting an x86 machine in 64-bit long mode
;
; Maintainer: Chris Williams <diodesign@gmail.com>
;

global start64
extern kmain

section .text
bits 64

; start64
;
; Jumped to from the 32-bit startup code.
; Now running in 64-bit long mode with our own
; GDT and basic paging system enabled. Interrupts are off.
;
start64:
; write 'Done' to 4th line of video text to signal we're here
  mov rax, 0x0a650a6e0a6f0a44
  mov qword [0xb8000 + (3 * 160)], rax

; enter the Rust-level kernel
  call kmain

; write 'Halt' in red to 5th line of video text to signal we're done
  mov rax, 0x0c740c6c0c610c48
  mov qword [0xb8000 + (4 * 160)], rax
  hlt

