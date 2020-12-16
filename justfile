#
# just makefile for the diosix project
#
# You will need just to go any further. install it using:
# cargo install --force just
#
# Build and run diosix in Qemu, using the defaults:
# just
#
# Only build diosix using the defaults:
# just build
#
# Set target to the architecture you want to build for. Eg:
# just target=riscv32imac-unknown-none-elf
#
# Set emubin to the Qemu system emulator binary you want to use to run diosix, Eg:
# just emubin=qemu-system-riscv32
#
# Set quality to release or debug to build a release or debug-grade build respectively. Eg:
# just quality=release
# just quality=debug
#
# Set quiet to no to see mkdmfs and cargo's usual output.
# Set to yes to only report warnings and errors. Eg:
# just quiet=no
# just quiet=yes
#
# The defaults are:
# emubin    qemu-system-riscv64
# target    riscv64gc-unknown-none-elf
# quality   debug
# quiet     yes
#
# Author: Chris Williams <diodesign@tuta.io>
# See LICENSE for usage and distribution
# See README for further instructions
#

# let the user know what we're up to
msgprefix := "--> "
buildmsg  := msgprefix + "Building"
cleanmsg  := msgprefix + "Cleaning build tree"
rustupmsg := msgprefix + "Ensuring Rust can build for"
builtmsg  := msgprefix + "Diosix built and ready for use"
qemumsg   := msgprefix + "Running Diosix in Qemu"

# define defaults, these are overriden by the command line
target  := "riscv64gc-unknown-none-elf"
emubin  := "qemu-system-riscv64"
quality := "debug"
quiet   := "yes"

# generate cargo switches
quality_sw := if quality == "debug" { "debug" } else { "release" }
release_sw := if quality == "release" { "--release " } else { "" }
quiet_sw   := if quiet == "yes" { "--quiet " } else { "" }
verbose_sw := if quiet == "no" { "--verbose " } else { "" }
cargo_sw   := quiet_sw + release_sw + "--target " + target

# TODO/FIXME: substituting base_arch doesn't seem to work, so we'll hardwire it in for now
# base_arch := `echo {{target}} | grep -o -E "(riscv)" | head -n 1`

# set location of the dmfs image file
dmfsimg := "target/dmfs.img"

# the default recipe
# build diosix with its components, and run it within qemu
@qemu: build
    echo "{{qemumsg}}"
    {{emubin}} -bios none -nographic -machine virt -smp 4 -m 512M -kernel hypervisor/target/{{target}}/{{quality_sw}}/hypervisor

# build diosix and its components
@build: _descr _rustup _hypervisor
    echo "{{builtmsg}}"

# let the user know what's going to happen
@_descr:
    echo "{{buildmsg}} {{quality_sw}}-grade Diosix for {{target}}"

# build the hypervisor and ensure it has a boot file system to include
@_hypervisor: _mkdmfs
    echo "{{buildmsg}} hypervisor"
    cd hypervisor && MASON_FILES=../{{dmfsimg}} MASON_ASM_DIRS=src/platform-`echo {{target}} | grep -o -E "(riscv)" | head -n 1`/asm cargo build {{cargo_sw}}

# build and run the dmfs generator to include banners and system services.
# mkdmfs is configured by manifest.toml in the project root directory.
# the output fs image is linked in the hypervisor and unpacked at run-time
#
# the target directory stores the dmfs image file
@_mkdmfs: _services
    echo "{{buildmsg}} dmfs image"
    mkdir -p target
    cd mkdmfs && cargo run {{quiet_sw}} -- -t {{target}} -q {{quality_sw}} {{verbose_sw}}

# build the system services
@_services: 
    echo "{{buildmsg}} system services"
    cd services && MASON_ASM_DIRS=supervisor-`echo {{target}} | grep -o -E "(riscv)" | head -n 1`/asm cargo build {{cargo_sw}}

# make sure we've got the cross-compiler installed and setup
@_rustup:
    echo "{{rustupmsg}} {{target}}"
    rustup {{quiet_sw}} target install {{target}}

# delete intermediate build files and update cargo dependencies to start afresh
@clean:
    echo "{{cleanmsg}}"
    -cd hypervisor && cargo {{quiet_sw}} clean && cargo {{quiet_sw}} update
    -cd services && cargo {{quiet_sw}} clean && cargo {{quiet_sw}} update
    -cd mkdmfs && cargo {{quiet_sw}} clean && cargo {{quiet_sw}} update
    -rm {{dmfsimg}}
