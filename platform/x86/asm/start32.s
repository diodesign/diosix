; diosix microkernel 'menchi'
;
; Boot an x86 machine
;
; Maintainer: Chris Williams <diodesign@gmail.com>
;

global gdt.kdata	   ; make sure other code can see kernel's data segment
global kernel_cs	   ; make sure the rust kernel can see kernel's code segment
global start32		   ; entry point for the kernel from the boot loader
global kernel_start_addr, kernel_end_addr

; make page tables visible to other code
global boot_pml4_ptr
global boot_pd_table, boot_pt0_table, boot_pt1_table

global multiboot_phys_addr ; phys address of multiboot structure

extern start64

; linker symbols
extern __kernel_start
extern __kernel_end

section .text
bits 32

; start32
;
; Entry point from the boot loader. Here's what we know:
;
; We're in 32-bit protected mode on an x86 core.
; The boot loader has set up a GDT somewhere.
; Interrupts are switched off.
; We need to initialize a known good environment.
;
start32:
; give us a stack to play with
  mov esp, boot_stack_top

; preserve pointer to physical address of multiboot structure
  mov [multiboot_phys_addr], ebx

; stash important addresses for the rust kernel to find
  mov ebx, __kernel_start
  mov [kernel_start_addr], ebx
  mov ebx, __kernel_end
  mov [kernel_end_addr], ebx
  mov ebx, boot_pml4_table
  mov [boot_pml4_ptr], ebx

; clear the screen and let the user know we're alive
  call boot_video_cls
  mov edx, boot_welcome_msg
  call boot_video_writeln

; perform some preflight tests to make sure this is a sane environment
  call test_multiboot_present
  call test_cpuid_present
  call test_x86_64_present
  call test_sse_present

; acknowledge we've got this far
  mov edx, boot_tests_complete_msg
  call boot_video_writeln
 
; set up paging, the GDT and jump into long mode
  call init_paging
  call init_gdt

; we've made it this far, let the user know
  mov edx, boot_mmu_init_msg
  call boot_video_writeln
  
; now we switch to the 64-bit GDT's selectors and bounce out of
; here into proper 64-bit long mode.
  mov ax, gdt.kdata
  mov ss, ax
  mov ds, ax
  mov es, ax

  jmp gdt.kcode:start64

  ; should never reach here
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
  jmp boot_early_error


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
  jmp boot_early_error


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
  jmp boot_early_error


; test_sse_present
;
; Test that the processor can handle SSE instructions, and if so,
; enable them. If not, bail out - Rust likes to bake in SSE code
;
test_sse_present:
  mov eax, 1
  cpuid		    ; get basic CPU features in edx and ecx
  test edx, 1 << 25 ; bit 25 = 1 if SSE support present 
  jz .missing_SSE

  ; switch on SSE instructions so we don't get hit by undefined
  ; instruction exceptions later on
  mov eax, cr0
  and ax, 0xfffb    ; clear CR0 bit 2 = hardware FPU present
  or ax, 2	    ; set bit 1 = monitor coprocessor
  mov cr0, eax
  
  ; enable OSFXSR (support for FXSAVE and FXRSTOR instructions),
  ; and OSXMMEXCPT (unmasked SSE exceptions) in CR4
  mov eax, cr4
  or ax, 3 << 9	    ; set bits 9 (OSFXSR) and 10 (OSXMMEXCPT) in CR4
  mov cr4, eax
  ret

.missing_SSE:
  mov edx, boot_error_no_sse
  jmp boot_early_error

; --------------------- set up paging ---------------------

; init_paging
;
; Identity map the first, lowest 1GB of kernel virtual memory
; to the lowest 1GB of physical memory.
;
; The level 4 table has 512 x 8-byte entries. Each entry covers
; a 512GB region. We point the lowest region at a level 3 table.
;
; The level 3 table, aka a PDP table, has 512 x 8-byte entries.
; Each entry covers a 1GB region. We point the lowest region
; at a level 2 table.
;
; The level 2 table, aka a page directory table, also has
; 512 x 8-byte entries. Each entry can cover a 2MB page.
; So we fill the level 2 page table with entries mapping
; the entire 1GB region of virtual memory to the lowest
; 1GB of physical memory.
;
init_paging:
  ; force paging off if it's been enabled by the boot loader.
  ; also prevent the kernel from writing over read-only pages
  mov eax, cr0
  and eax, 0x7fffffff ; clear bit 31 (paging enable)
  or eax, 0x10000     ; enable bit 16 (write protect)
  mov cr0, eax

  ; get address of the level 3 PDP table, set its present and
  ; writeable bits, and clear the others. Then point to
  ; this table from the first entry in the level 4 table
  mov eax, boot_pdp_table
  or eax, 0x7 ; present, writeable, user-allowed
  mov [boot_pml4_table], eax

  ; get the address of the level 2 page directory table,
  ; mark it as present and writeable, and point to it
  ; from the first entry of the level 3 table
  mov eax, boot_pd_table
  or eax, 0x7
  mov [boot_pdp_table], eax

  ; that's the easy bit done, linking tables to each other.
  ; now we have to fill the level 2 page table with entries.
  ; each entry describes a 2MB region of physical memory.
  ; so fill the table, entry by entry, pointing to successive
  ; 2MB pages of physical memory.
  
  xor ebx, ebx	; start entry index from zero

.map_2m_page:
  mov eax, (2 * 1024 * 1024)
  mul ebx	; eax = 2MB * index
  or eax, 0x83  ; present, writeable, kernel-only 'huge' 2MB page
  mov [boot_pd_table + ebx * 8], eax
  inc ebx
  cmp ebx, 512
  jne .map_2m_page ; keep going through all 512 entries
 
  ; time to enable paging. point the CPU's CR3 special
  ; register at our top-tier, level 4 page table
  mov eax, boot_pml4_table
  mov cr3, eax

  ; enable PAE (bit 5 in CR4) and global pages (bit 7)
  mov eax, cr4
  or eax, 1 << 5
  or eax, 1 << 7
  mov cr4, eax

  ; enable long mode (bit 8 of the EFER MSR)
  ; and no-execute security (bit 11)
  mov ecx, 0xc0000080
  rdmsr
  or eax, 1 << 8
  or eax, 1 << 11
  wrmsr

  ; flip the main switch: bit 31 in CR0
  mov eax, cr0
  or eax, 1 << 31
  mov cr0, eax

  ret

; -------------------- set up the GDT ---------------------

; init_gdt
;
; Initilize a 64-bit GDT for the system
;
init_gdt:
  lgdt [gdtptr]  ; tell processor where to find the GDT
  ret

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
  mov word [ebx], 0x0a20  ; write a blank green-on-black space
  add ebx, 2
  dec eax
  jnz .cls_loop           ; loop through all characters on screen

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
  db "Hey, it's diosix! Performing preflight checks...",0

boot_tests_complete_msg:
  db "[x86] Congrats, this system is good to boot.",0

boot_mmu_init_msg:
  db "[x86] Paging and GDT set up. Entering 64-bit mode...",0

boot_error_no_multiboot:
  db "Oh no. The boot loader isn't Multiboot 2 compatible.",0

boot_error_no_cpuid:
boot_error_no_sse:
boot_error_no_64bit:
  db "Oh no. This machine's processor is too old for this kernel.",0

boot_error_halting:
  db "Sorry! Can't go any further - halting boot process.",0

; -------------------- error handler ----------------------

; boot_early_error
;
; Print an error message on the screen and halt the CPU
; => edx = error string to print
; <= never returns
;
boot_early_error:
  call boot_video_writeln
  mov edx, boot_error_halting
  call boot_video_writeln
  hlt

; -----------------------------------------------------------------------------
; reserve a single-page stack while bringing up the system,
; page tables, and variables for writing to the screen
section .bss

align 4096
boot_pml4_table:
  resb 4096     ; reserve 4KB for page-map level 4 page table

boot_pdp_table:
  resb 4096     ; reserve 4KB of page directory pointers aka level 3 page table

boot_pd_table:
  resb 4096	; reserve 4KB for page directory aka level 2 page table

boot_pt0_table:
  resb 4096	; reserve 4KB for a page table aka level 1 page table

boot_pt1_table:
  resb 4096	; reserve 4KB for a page table aka level 1 page table

boot_stack_bottom:
  resb 2 * 4096	; reserve 2 x 4KB pages for the stack
boot_stack_top:

; stash a pointer to the boot PML4 table
boot_pml4_ptr:
  resb 8

; somewhere to stash a copy of start and end addresses of the kernel,
; according to the linker.
kernel_start_addr:
  resb 8

kernel_end_addr:
  resb 8

multiboot_phys_addr:
  resb 8	; this will be loaded as a 64-bit value by the rust kernel

boot_video_line_nr:
  resb 1

; -----------------------------------------------------------------------------
; define our 64-bit GDT
section .rodata

; table of segements in our 64-bit GDT
gdt:
.null: equ $ - gdt ; calc offset into table
  ; 0x00 NULL/empty entry
  dq 0

.kcode: equ $ - gdt ; calc offset into table
  ; 0x08 kernel code segment: executable code, present, ring 0, read-only, 64-bit
  dq (1<<44) | (1<<47) | (1<<41) | (1<<43) | (1<<53)

.kdata: equ $ - gdt ; calc offset into table
  ; 0x0c kernel data segment: data, present, ring 0, writeable, 64-bit
  dq (1<<44) | (1<<47) | (1<<41)

; must immediately follow gdt for the length calculation to work
gdtptr:
  dw $ - gdt - 1 ; size of the GDT - 1
  dq gdt	 ; pointer to the GDT

kernel_cs:
  dq gdt.kcode	 ; export code selector as a static variable

