#
# just makefile for the diosix project
#
# You will need just to go any further. install it using:
# cargo install --force just
#
# Build and run diosix in Qemu, using the defaults:
# just
#
# Build and run diosix in Spike, using the defaults:
# just spike
#
# Only build diosix using the defaults:
# just build
# 
# A link is created at src/hypervisor/target/diosix pointing to the location
# of the built ELF executable package containing the hypervisor, its services, and guests.
# A flat binary of this ELF is created at src/hypervisor/target/diosix.bin
#
# Repartition a disk, typically an SD card, and install diosix on it (requires root via sudo)
# just install
#
# set vendor to a supported vendor. eg: as sifive for SiFive Unleashed boards
# set disk to the device to erase and install diosix on. eg: /dev/sdb
# 
# Eg:
# just vendor=sifive disk=/dev/sdb install

# You can control the workflow by setting parameters. These must go after just and before
# the command, such as build. Eg, for a verbose build-only process:
# just quiet=no build
#
# Supported parameters
#
# Set target to the architecture you want to build for. Eg:
# just target=riscv64imac-unknown-none-elf
#
# Set qemubin to the path of the Qemu system emulator binary you want to use to run diosix, Eg:
# just qemubin=qemu-system-riscv64
#
# Set spikebin to the path of the Spike binary you want to use to run diosix, Eg:
# just spikebin=$HOME/src/riscv-isa-sim/build/spike
#
# Set spikeisa to the RISC-V ISA to use with Spike, eg:
# just spikeisa=RV64IMAC
#
# Set objcopybin to the objcopy suitable for the target architecture. Eg:
# just objcopybin=riscv64-linux-gnu-objcopy install
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
# Set cpus to the number of CPU cores to run within qemu and spike, eg:
# just cpus=1
#
# Force debug text output via Qemu's serial port by setting qemuprint to yes, eg:
# just qemuprint=yes
# 
# Force debug text output via SiFive's serial port by setting sifiveprint to yes, eg:
# just sifiveprint=yes
#
# Force debug text output via Spike's HTIF by setting htifprint to yes, eg:
# just htifprint=yes
#
# Disable hypervisor's regular integrity checks by setting integritychecks to no, eg:
# just integritychecks=no
#
# Disable including services by setting services to no, eg:
# just services=no
# 
# Disable including guest OSes by setting quests to no, eg:
# just guests=no
# 
# Disable downlaoding guest OS images by setting guests-download to no, eg:
# just guests-download=no
# 
# Disable building guest OSes using buildroot by setting guests-build to no, eg:
# just guests-build=no 
#
# The defaults are:
# qemubin          qemu-system-riscv64
# spikebin         spike
# spikeisa         RV64IMAFDC
# target           riscv64gc-unknown-none-elf
# objcopybin       riscv64-linux-gnu-objcopy
# quality          debug
# quiet            yes
# cpus             4
# qemuprint        no
# sifiveprint      no
# htifprint        no
# integritychecks  yes
# services         yes
# guests           yes
# guests-download  yes
# guests-build     yes
# vendor           sifive
#
# Author: Chris Williams <chrisw@diosix.org>
# See LICENSE for usage and distribution
# See README for further instructions
#

# let the user know what we're up to
msgprefix  := "--> "
buildmsg   := msgprefix + "Building"
cleanmsg   := msgprefix + "Cleaning build tree"
rustupmsg  := msgprefix + "Ensuring Rust can build for"
builtmsg   := msgprefix + "Diosix built and ready to use at"
qemumsg    := msgprefix + "Running Diosix in Qemu"
spikemsg   := msgprefix + "Running Diosix in Spike"
installmsg := msgprefix + "Installing"
installedmsg := msgprefix + "Diosix installed on disk"

# define defaults, these are overriden by the command line
target          := "riscv64gc-unknown-none-elf"
qemubin         := "qemu-system-riscv64"
spikebin        := "spike"
spikeisa        := "RV64IMAFDC"
objcopybin      := "riscv64-linux-gnu-objcopy"
quality         := "debug"
quiet           := "yes"
cpus            := "4"
qemuprint       := "no"
sifiveprint     := "no"
htifprint       := "no"
integritychecks := "yes"
services        := "yes"
guests          := "yes"
guests-download := "yes"
guests-build    := "yes"
final-exe-path  := "src/hypervisor/target/diosix"
vendor          := "sifive"
disk            := "/dev/null"

# generate cargo switches
quality_sw      := if quality == "debug" { "debug" } else { "release" }
release_sw      := if quality == "release" { "--release " } else { "" }
quiet_sw        := if quiet == "yes" { "--quiet " } else { "" }
quiet_redir_sw  := if quiet == "yes" { "> /dev/null " } else { "" }
verbose_sw      := if quiet == "no" { "--verbose " } else { "" }
qemuprint_sw    := if qemuprint == "yes" { "--features qemuprint" } else { "" }
sifiveprint_sw  := if sifiveprint == "yes" { "--features sifiveprint" } else { "" }
htifprint_sw    := if htifprint == "yes" { "--features htifprint" } else { "" }
cargo_sw        := quiet_sw + release_sw + "--target " + target
integritychecks_sw := if integritychecks == "yes" { "--features integritychecks" } else { "" }
services_sw     := if services == "no" { "--skip-services" } else { "" }
guests_sw       := if guests == "no" { "--skip-guests" } else { "" }
downloads_sw    := if guests-download == "no" { "--skip-downloads" } else { "" }
builds_sw       := if guests-build == "no" { "--skip-buildroot" } else { "" }

# use rustc's nightly build
cargo_cmd       := "cargo +nightly"

# the default recipe
# build diosix with its components, and run it within qemu
@qemu: build
    echo "{{qemumsg}}"
    {{qemubin}} -bios none -nographic -machine virt -smp {{cpus}} -m 1G -kernel {{final-exe-path}}

# build diosix, and run it within spike
@spike: build
    echo "{{spikemsg}}"
    {{spikebin}} --isa={{spikeisa}} -p{{cpus}} -m1024 {{final-exe-path}}

# build and install diosix with its components onto a disk (requires root via sudo)
@install: build
    {{objcopybin}} -O binary {{final-exe-path}} {{final-exe-path}}.bin {{quiet_redir_sw}}
    echo "{{installmsg}} {{final-exe-path}}.bin on {{disk}}"
    sudo sgdisk --clear --new=1:2048:65536 --change-name=1:bootloader --typecode=1:2E54B353-1271-4842-806F-E436D6AF6985 -g {{disk}} {{quiet_redir_sw}}
    sudo dd if={{final-exe-path}}.bin of={{disk}}1 bs=512 {{quiet_redir_sw}} 2>&1
    echo "{{installedmsg}}"

# the core workflow for building diosix and its components
# a link is created at final-exe-path to the final packaged executable
@build: _descr _rustup _itsylinker _hypervisor
    ln -fs {{target}}/{{quality_sw}}/hypervisor {{final-exe-path}}
    echo "{{builtmsg}} {{final-exe-path}}"

# let the user know what's going to happen
@_descr:
    echo "{{buildmsg}} {{quality_sw}}-grade Diosix for {{target}} systems"

# build the itsy-bitsy linker ready for use
@_itsylinker:
    echo "{{buildmsg}} linker"
    cd src/itsylinker && {{cargo_cmd}} build {{quiet_sw}}

# build the hypervisor after ensuring it has a boot file system to include
@_hypervisor: _mkdmfs
    echo "{{buildmsg}} hypervisor"
    cd src/hypervisor && {{cargo_cmd}} build {{cargo_sw}} {{qemuprint_sw}} {{sifiveprint_sw}} {{htifprint_sw}} {{integritychecks_sw}}

# build and run the dmfs generator to include banners and system services.
# mkdmfs is configured by manifest.toml in the project root directory.
# the output fs image is linked in the hypervisor and unpacked at run-time.
#
# the target directory stores the dmfs image file
@_mkdmfs: _services
    echo "{{buildmsg}} dmfs image"
    cd src/mkdmfs && {{cargo_cmd}} run {{quiet_sw}} --release -- -t {{target}} -q {{quality_sw}} {{verbose_sw}} {{services_sw}} {{guests_sw}} {{downloads_sw}} {{builds_sw}}

# build the system services
@_services: 
    echo "{{buildmsg}} system services"
    cd src/services && {{cargo_cmd}} build {{cargo_sw}}

# make sure we've got the cross-compiler installed and setup
@_rustup:
    echo "{{rustupmsg}} {{target}}"
    rustup {{quiet_sw}} toolchain install nightly
    rustup {{quiet_sw}} target install {{target}} --toolchain nightly

# delete intermediate build files and update cargo dependencies to start afresh
@clean:
    echo "{{cleanmsg}}"
    -cd src/hypervisor && {{cargo_cmd}} {{quiet_sw}} clean && {{cargo_cmd}} {{quiet_sw}} update
    -cd src/services && {{cargo_cmd}} {{quiet_sw}} clean && {{cargo_cmd}} {{quiet_sw}} update
    -cd src/mkdmfs && {{cargo_cmd}} {{quiet_sw}} clean && {{cargo_cmd}} {{quiet_sw}} update

# FIXME: the framework for this is broken.
# run unit tests for each major component
# @_test:
#    -cd src/hypervisor && {{cargo_cmd}} {{quiet_sw}} test
#    -cd src/services && {{cargo_cmd}} {{quiet_sw}} test
#    -cd src/mkdmfs && {{cargo_cmd}} {{quiet_sw}} test

# are we allowed one easter egg?
@_incredible:
    echo "No, you're incredible."