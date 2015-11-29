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
; give us a stack to play with
  mov esp, boot_stack_top

; clear the screen and let the user know we're alive
  call boot_video_cls
  mov edx, boot_welcome_msg
  call boot_video_writeln

; perform some preflight tests to make sure this is a sane environment
  call test_multiboot_present
  call test_cpuid_present
  call test_x86_64_present

; acknowledge we've got this far
  mov edx, boot_tests_complete_msg
  call boot_video_writeln
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
  mov edx, boot_error_no_multiboot
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
  mov edx, boot_error_no_cpuid
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
  mov edx, boot_error_no_64bit
  jmp early_boot_err


; ------------------- basic video code --------------------

; boot_video_cls
;
; Clear the screen and reset the cursor to the top left
; corner of the display. Assumes screen is an 80 x 25 text display
;
boot_video_cls:
  push eax
  push ebx
  mov eax, 80 * 25
  mov ebx, 0xb8000
  
.cls_loop:
  mov word [ebx], 0x2720  ; write a blank grey-on-green space
  add ebx, 2
  dec eax
  jnz .cls_loop           ; loop through all screen words

  ; reset line position
  mov byte [boot_video_line_nr], 0

  pop ebx
  pop eax
  ret


; boot_video_writeln
;
; Write a null-terminated string to screen. A newline is automatically added.
; Don't forget that each character is stored as two bytes - the first is the
; color byte, and the second is the ASCII code.
; => edx = pointer to string in memory
; <= edx = incrememnted to end of string
;
boot_video_writeln:
  push eax
  push ebx
  
  ; calculate start of line in memory based on current text line index
  xor eax, eax
  mov ebx, 80
  mov al, byte [boot_video_line_nr]
  mul bl
  shl eax, 1
  add eax, 0xb8000	; eax = (index * 80 * 2) + 1 + 0xb8000 base

.writeln_loop:
  mov bl, byte [edx]
  cmp bl, 0
  jz .writeln_loop_done ; bail out when we hit the null term
  mov byte [eax], bl
  add edx, 1
  add eax, 2
  jmp .writeln_loop

.writeln_loop_done:
  xor eax, eax
  mov al, byte [boot_video_line_nr]
  add eax, 1
  mov byte [boot_video_line_nr], al ; increment line index

  pop ebx
  pop eax
  ret

; -------------------- boot messages ----------------------

boot_welcome_msg:
  db "Woo - it's diosix! Now performing preflight checks...",0
boot_tests_complete_msg:
  db "Tests complete. Congrats, this system is good to boot.",0

boot_error_no_multiboot:
  db "Oh no. The boot loader isn't Multiboot compatible. Sorry! Halting.",0
boot_error_no_cpuid:
  db "Oh no. This machine's processor is too old to boot. Sorry! Halting.",0
boot_error_no_64bit:
  db "Oh no. This machine's processor doesn't support 64-bit x86. Halting.",0

; -------------------- error handler ----------------------

; early_boot_err
;
; Print an error message on the screen and halt the CPU
; => edx = error string to print
; <= never returns
;
early_boot_err:
  call boot_video_writeln
  hlt

; reserve a tiny stack while bringing up the system
; and variables for writing to the screen
section .bss

boot_video_line_nr: resb 1

boot_stack_bottom:
  resb 64
boot_stack_top:

