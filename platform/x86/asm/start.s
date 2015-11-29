; diosix microkernel 'menchi'
;
; Boot an x86 machine
;
; Maintainer: Chris Williams <diodesign@gmail.com>
;

global start

section .text
bits 32

; start
;
; Entry point from the boot loader. Here's what we know:
;
; We're in 32-bit protected mode on an x86 core.
; The boot loader has set up a GDT somewhere.
; We need to initialize a known good environment.
;
start:
; print 'GO' to screen to show we've been booted
  mov dword [0xb8000], 0x2f4f2f47

; give us a stack to play with
  mov esp, boot_stack_top

; perform some preflight tests to make sure this is a sane environment
  call test_multiboot_present
  call test_cpuid_present
  call test_x86_64_present

; print 'OK' to screen to acknowledge we've got this far
  mov dword [0xb8000], 0x2f4b2f4f
  hlt

; -------------------- preflight checks ----------------------

; test_multiboot_present
; 
; Test that we were booted by a multiboot loader. The magic
; word 0x36d76289 should be in eax. Only returns if the
; magic word is present, or bails out via the early boot
; error handler
;
test_multiboot_present:
  cmp eax, 0x36d76289
  jne .no_multiboot
  ret
.no_multiboot:
  mov al, "0"
  jmp early_boot_err

; test_cpuid_present
; 
; Test this processor has the CPUID instruction. See here
; http://wiki.osdev.org/CPUID for details. If we can modify
; the ID bit in the flags then we can use the CPUID instruction.
; Never returns if the instruction is missing.
;
test_cpuid_present:
  pushfd		; copy CPU flags to the stack
  pop eax		; copy flags to eax
  mov ecx, eax		; preserve the flags to ecx
  xor eax, 1 << 21	; flip bit 21, the ID bit
  push eax		; copy modified flags to stack
  popfd			; copy modified flags to the CPU
  pushfd		; copy the CPU flags back to the stack
  pop eax		; copy the flags to eax
  push ecx		; restore the original flags to the stack
  popfd			; copy the original flags to the CPU
  xor eax, ecx		; see if it was possible to modify the ID bit
  jz .no_cpuid		; if not, bail out to error handler
  ret			; if yes, then let's get out of here
.no_cpuid:
  mov al, "1"
  jmp early_boot_err

; test_x86_64_present
;
; Test that this processor can actually get us into 64-bit mode.
; Never returns if the CPU doesn't support long mode.
;
test_x86_64_present:
  mov eax, 0x80000000	; check to see if we can probe extended functions
  cpuid
  cmp eax, 0x80000001	; if eax isn't >0x80000000 then no extended functions
  jb .no_x86_64		; and no extended functions means no long mode
  mov eax, 0x80000001   ; get the supported extended functions bitmask
  test edx, 1 << 29	; check if bit 29 (long mode) is set
  jz .no_x86_64		; if not, then it isn't available so bail out
  ret			; if yes, then let's go
.no_x86_64:
  mov al, "2"
  jmp early_boot_err

; -------------------- error handler ----------------------

; early_boot_err
;
; Print an error code on screen if something goes
; wrong unexpectedly during first stages of boot
; => al = error character to print
; <= never returns
;
early_boot_err:
  mov dword [0xb8000], 0x4f524f45 ; write 'ERR:  ' to screen
  mov dword [0xb8004], 0x4f3a4f52
  mov dword [0xb8008], 0x4f204f20
  mov byte  [0xb800a], al	  ; overwrite last char with error code
  hlt


; reserve a tiny stack while bringing up the system
section .bss
boot_stack_bottom:
  resb 64
boot_stack_top:

