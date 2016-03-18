; diosix microkernel 'menchi'
;
; Handle interrupts - exceptions and hardware IRQs
;
; Maintainer: Chris Williams (diosix.org)
;

global initialize_interrupts
global boot_idtr
global boot_idt

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

; create interrupt entry points for CPU exceptions
interrupt_entry 		0  ; divide-by-zero
interrupt_entry 		1  ; debug
interrupt_entry 		2  ; NMI
interrupt_entry 		3  ; breakpoint
interrupt_entry 		4  ; overflow
interrupt_entry 		5  ; bound range exceeded
interrupt_entry 		6  ; invalid opcode
interrupt_entry 		7  ; device not available
interrupt_entry_with_error   	8  ; double fault 

interrupt_entry_with_error   	10 ; invalid TSS
interrupt_entry_with_error   	11 ; segment not present
interrupt_entry_with_error   	12 ; stack-segment fault
interrupt_entry_with_error   	13 ; general protection fault
interrupt_entry_with_error   	14 ; page fault

interrupt_entry 		16 ; x87 FPU exception
interrupt_entry_with_error 	17 ; alignment check
interrupt_entry 		18 ; machine check
interrupt_entry 		19 ; SIMD FPU exception
interrupt_entry 		20 ; virtualization fault

; create interrupt entry points for reserved exceptions
%assign exception 21
%rep 9
  interrupt_entry exception
  %assign exception exception+1
%endrep

interrupt_entry_with_error 	30 ; security fault

; create 16 entry points for legacy IRQs
%assign irq 32
%rep 16
  interrupt_entry irq
  %assign irq irq+1
%endrep

; create interrupt entry points for APIC IRQs
interrupt_entry 48 ; timer
interrupt_entry 49 ; lint0
interrupt_entry 50 ; lint1
interrupt_entry 51 ; pcint
interrupt_entry 53 ; thermal sensor
interrupt_entry 54 ; error
interrupt_entry 63 ; spurious int

; create interrupt entry points for IOAPIC IRQs
%assign ioapic_irq 64
%rep 24
  interrupt_entry ioapic_irq
  %assign ioapic_irq ioapic_irq+1
%endrep

; create an entry point for software interrupts (SWI)
interrupt_entry 127 ; 0x7f

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
  push rax			; preserve ds
  push 0			; align this point in the stack to 16-byte boundary

  mov ax, gdt.kdata		; kernel data segment
  mov ds, ax			; select this segment
  mov ss, ax
  mov es, ax
  
  mov rdi, rsp			; give Rust kernel visibility to interrupted state
  call kernel_interrupt_handler

  pop rax			; discard the stack alignment word
  pop rax
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

section .rodata

; pointer to the interrupt descriptor table
boot_idtr:
  dw (16 * 256) - 1		; size of the IDT in bytes - 1
  dq boot_idt

section .bss

; the interrupt descriptor table, 256 16-byte entries 
boot_idt:
  resb 16 * 256

