; diosix microkernel 'menchi'
;
; Continue booting an x86 machine in 64-bit long mode
;
; Maintainer: Chris Williams (diosix.org)
;

global start64
global serial_write_byte
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

; enable the COM1 serial port for kernel debugging.
; it's easier to capture and analyze debugging info from
; the serial port than reading numbers off a screen.
; we've used video to this point to show the system is
; alive and running. but detailed info should be logged
; to the serial port.
  call serial_init

; enter the Rust-level kernel
  call kmain

; try firing an interrupt
  int 0x3

; nowhere else to go
  cli
  hlt


; serial_init
; 
; Initialize the first serial port (COM1) for kernel debugging.
; the IO port number for the serial port is 0x3f8
; TODO: check this initialization sequence - it may fail on real hardware
;
serial_init:

serial_port equ 0x3f8

  mov ax, 0x00      ; disable interrupts
  mov dx, serial_port + 1
  out dx, al
  
  mov ax, 0x80      ; prepare to set baud rate divisor
  mov dx, serial_port + 3
  out dx, al

  mov ax, 0x03      ; set baud rate divisor (low byte) to 0x3
  mov dx, serial_port + 0
  out dx, al
  
  mov ax, 0x00      ; set baud rate divisor (high byte) to 0x0
  mov dx, serial_port + 1
  out dx, al
  
  mov ax, 0x03      ; 8 bits, no parity, one stop bit
  mov dx, serial_port + 3
  out dx, al

  ret


; serial_write_byte
; 
; Write a byte to the serial port
; => rdi = character to write; lowest byte is sent to the serial port
;    rax, rdx corrupted. all other registers preserved.
;    Can be called externally from Rust.
;
serial_write_byte:
  mov dx, serial_port + 5 ; get serial port status
.tx_loop:
  in al, dx  		  ; read in flags
  and al, 1 << 5          ; check if transmit buffer is empty (bit 5 set)
  jz .tx_loop	 	  ; loop until it is empty (bit 5 is set)

  mov rax, rdi
  mov dx, serial_port + 0
  out dx, al              ; write byte out to the data port
  ret

