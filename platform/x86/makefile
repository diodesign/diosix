#
# diosix microkernel 'menchi'
#
# Makefile for x86 machines
#

arch 		:= x86

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

# source code - find .s files in asm/ and map them to object files in build tree
asm_src := $(wildcard asm/*.s)
asm_obj := $(patsubst asm/%.s, $(build)/%.o, $(asm_src))

.PHONY: all clean run iso

# rules for building various components

all: $(kernel)

clean:
	@rm -r $(build) $(release)

run: $(iso)
	@qemu-system-x86_64 -curses -cdrom $(iso)

iso: $(iso)

$(iso): $(kernel) $(grubcfg)
	@mkdir -p $(kernel_in_isofs)
	@cp $(kernel) $(kernel_in_isofs)/kernel.bin
	@mkdir -p $(grubcfg_in_isofs)
	@cp $(grubcfg) $(grubcfg_in_isofs)/grub.cfg
	@grub-mkrescue -o $(iso) $(isofs) 2> /dev/null

$(kernel): $(asm_obj) $(ldscript)
	@ld -n -T $(ldscript) -o $(kernel) $(asm_obj)

$(build)/%.o: asm/%.s
	@mkdir -p $(build)
	@nasm -felf64 $< -o $@

