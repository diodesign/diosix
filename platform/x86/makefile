#
# diosix microkernel 'menchi'
#
# Makefile for x86 machines
#
# Maintainer: Chris Williams (diosix.org)
#

arch 		:= x86
target		:= x86_64-unknown-linux-gnu

# set up directories to find stuff
release		:= ../../release/$(arch)
build 		:= ../../build/$(arch)
isofs 		:= $(release)/isofs

# crucial files needed to boot the kernel
kernel 		:= $(build)/kernel.bin
iso 		:= $(release)/boot.iso
ldscript 	:= linker.ld
grubcfg 	:= grub.cfg

# where to store the kernel and boot scipt in the ISO image's filesystem
kernel_in_isofs	 := $(isofs)/boot/
grubcfg_in_isofs := $(isofs)/boot/grub/

# where cargo hides our kernel's rust code library
libkernel	 := ../../target/$(target)/debug/libdiosix.a

# source code - find .s files in asm/ and map them to object files in build tree
asm_src := $(wildcard asm/*.s)
asm_obj := $(patsubst asm/%.s, $(build)/%.o, $(asm_src))

.PHONY: all clean cargo run run-headless iso gdb

# rules for building various components

all: $(kernel)

clean:
	@rm -rf $(build) $(release)
	@cargo clean

run: $(iso)
	@timeout --preserve-status --foreground 10s qemu-system-x86_64 -cpu qemu64 -curses -cdrom $(iso) -no-reboot

run-headless: $(iso)
	@timeout --preserve-status --foreground 10s qemu-system-x86_64 -cpu qemu64 -nographic -cdrom $(iso) -no-reboot

gdb: $(iso)
	@qemu-system-x86_64 -nographic -s -S -cdrom $(iso) -no-reboot

iso: $(iso)

$(iso): $(kernel) $(grubcfg)
	@mkdir -p $(kernel_in_isofs)
	@cp $(kernel) $(kernel_in_isofs)/kernel.bin
	@mkdir -p $(grubcfg_in_isofs)
	@cp $(grubcfg) $(grubcfg_in_isofs)/grub.cfg
	@grub-mkrescue -o $(iso) $(isofs) 2> /dev/null

$(kernel): cargo $(libkernel) $(asm_obj) $(ldscript)
	@ld --gc-sections -n -T $(ldscript) -o $(kernel) $(asm_obj) $(libkernel)

cargo: $(rust_src) $(kernel_src)
	@cargo rustc --target $(target) -- -Z no-landing-pads -C no-redzone -C target-feature=-mmx,-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2,-3dnow,-3dnowa,-avx,-avx2

$(build)/%.o: asm/%.s
	@mkdir -p $(build)
	@nasm -felf64 $< -o $@

