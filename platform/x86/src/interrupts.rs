/*
 * diosix microkernel 'menchi'
 *
 * Handle interrupts for x86 systems
 *
 * Maintainer: Chris Williams (diosix.org)
 *
 */

use ::hardware::pic;
use ::hardware::exceptions;
use errors::KernelInternalError;

const MAX_IDT_ENTRY: usize = 255;

extern
{
    static kernel_cs: u64; /* kernel code selector */
    static boot_idtr: u64; /* pointer to boot IDTR */
    static mut boot_idt: [idt_entry; MAX_IDT_ENTRY + 1]; /* table of 256 IDT entries */
}

/* when an interrupt happens, we take a snapshot of the
 * running thread's registers and stack them along with
 * the interrupt number and error code. this struct
 * can be used to access the stacked information. */
#[repr(C, packed)]
pub struct interrupted_thread_registers
{
    ds: u64,

    r15: u64, r14: u64, r13: u64, r12: u64, r11: u64,
    r10: u64,  r9: u64,  r8: u64, rdi: u64, rsi: u64,
    rbp: u64, rdx: u64, rcx: u64, rbx: u64, rax: u64,

    interrupt_number: u64,
    error_code: u64,
    rip: u64, cs: u64, flags: u64, rsp: u64, ss: u64
}

/* a 64-bit mode IDT entry */
#[repr(C, packed)]
struct idt_entry
{
    offset_low: u16,        /* bits 0 to 15 of handler address */
    gdt_select: u16,        /* GDT selector for the handler code */
    reserved_zero_byte: u8, /* must be zero */
    flags: u8,              /* type and attribute bits */
    offset_middle: u16,     /* bits 16 to 31 of handler address */
    offset_high: u32,       /* bits 32 to 63 of handler address */
    reserved_zero_word: u32 /* must be zero */
}

/* init()
 *
 * Initialize the interrupt system with basic exception
 * and interrupt handling.
 * <= returns error code if a failure happens
 *
 */
pub fn init() -> Result<(), KernelInternalError>
{
    try!(exceptions::init());
    try!(pic::init());

    kprintln!("[x86] using boot interrupt table at {:p} (idtr: {:p})", unsafe{&boot_idt}, &boot_idtr);

    /* load a pointer to the IDT into the CPU and
     * enable interrupts. */
    unsafe
    {
        asm!("lidt (%rax)" : : "{rax}"(&boot_idtr));
        asm!("sti");
    }

    kprintln!("[x86] interrupts and exceptions enabled");

    Ok(())
}

/* set_boot_idt_gate
 *
 * Set the interrupt vector entry for the boot IDT.
 * This is set up early on before the rest of the system
 * is initialized.
 * => vector = vector number to set up (0 to 255)
 *    handler = pointer to low-level interrupt handler
 * <= returns error on failure
 */
pub fn set_boot_idt_gate(vector: usize, handler: unsafe extern "C" fn()) -> Result<(), KernelInternalError>
{
    /* bail out if vector isn't sane */
    if vector > MAX_IDT_ENTRY
    {
        kprintln!("[x86] BUG! set_idt_gate() called with vector {}", vector);
        return Err(KernelInternalError::BadIndex);
    }

    let handler_addr = handler as u64;
    
    /* this bit is unsafe because we're fiddling with a global mutable variable.
     * but this function should only be called by the boot processor core
     * during system startup, so therefore no races. */
    unsafe
    {
        let entry = &mut boot_idt[vector];     
        entry.offset_low = (handler_addr & 0xffff) as u16; /* leave just lowest 16 bits */
        entry.gdt_select = kernel_cs as u16;
        entry.reserved_zero_byte = 0;
        entry.flags = 0x8e; /* present, interrupt gate, only kernel or hw can trigger */
        entry.offset_middle = ((handler_addr & 0xffff0000) >> 16) as u16;
        entry.offset_high = ((handler_addr & 0xffffffff00000000) >> 32) as u32;
        entry.reserved_zero_word = 0;
    }

    Ok(())
}

/* kernel_interrupt_handler
 *
 * Entry point to the kernel from an interrupt/exception
 * => stack = pointer to stack containing interrupted
 *            thread's registers plus interrupt number and
 *            error code.
 */
#[no_mangle]
pub extern "C" fn kernel_interrupt_handler(stack: interrupted_thread_registers)
{
    kprintln!("interrupt! {}", stack.interrupt_number);
}

