; diosix microkernel 'menchi'
;
; Handle interrupts - exceptions and hardware IRQs
;
; Maintainer: Chris Williams (diosix.org)
;

global initialize_interrupts

extern gdt.kdata
extern kernel_interrupt_handler

section .text
bits 64

; define an entry landing point for an exception with an
; error code already stacked by the processor
%macro interrupt_entry_with_error 1
  global interrupt_%1_handler
  interrupt_%1_handler:
    push byte %1		; push the interrupt number
    jmp interrupt_to_kernel
%endmacro

; define an entry landing point for an exception without an
; error code already stacked by the processor, or a hardware IRQ
%macro interrupt_entry 1
  global interrupt_%1_handler
  interrupt_%1_handler:
    push 0			; push a dummy value
    push byte %1		; push the interrupt number
    jmp interrupt_to_kernel
%endmacro

; interrupt_to_kernel
;
; Prepare the environment for calling a Rust kernel
; handler function 
;
interrupt_to_kernel:
  ; need to preserve all the registers we're likely to clobber.
  ; no need to save the SSE/FP registers because we've told rustc 
  ; to not use them. there's no need for them in a microkernel.
  ; if we're switching to another thread, we'll save/restore
  ; the FP state as required.
  push rax
  push rbx
  push rcx
  push rdx
  push rbp
  push rsi
  push rdi
  push r8
  push r9
  push r10
  push r11
  push r12
  push r13
  push r14
  push r15
  
  mov ax, ds
  push ax			; preserve ds

  mov ax, gdt.kdata		; kernel data segment
  mov ds, ax			; select this segment
  mov ss, ax
  mov es, ax
  
  mov rdi, rsp			; give Rust kernel visibility to interrupted state
  call kernel_interrupt_handler

  pop ax
  mov ds, ax
  mov ss, ax
  mov es, ax

  ; restore the bank of registers
  pop r15
  pop r14
  pop r13
  pop r12
  pop r11
  pop r10
  pop r9
  pop r8
  pop rdi
  pop rsi
  pop rbp
  pop rdx
  pop rcx
  pop rbx
  pop rax

  add rsp, 16			; fix up the stack for the two 64-bit words pushed on entry
  iretq

section .bss

; pointer to the interrupt descriptor table
idtr:
  resb 10

; the interrupt descriptor table, 256 16-byte entries 
idt:
  resb 16 * 256

