# U-Boot Diskless M-Mode Network Boot Script for Raspberry Pi TFTP Server.
# Compile into boot.scr on board microSD/SPI flash via:
#   mkimage -A riscv -O linux -T script -C none -d boot.cmd boot.scr
#
# Defaults assume DRAM base 0x80000000 (use 0x40200000 on Allwinner D1 R-01).

setenv autoload no
if test "${ethaddr}" = ""; then
    usb start
fi
dhcp
setenv mac_dash "${ethaddr}"
# Replace ':' with '-' when U-Boot supports setexpr, or set board_dir explicitly
if test "${board_dir}" = ""; then
    setenv board_dir "${mac_dash}"
fi
if test "${hv_addr}" = ""; then
    setenv hv_addr 0x80000000
fi
if test "${fdt_addr}" = ""; then
    setenv fdt_addr 0x88000000
fi
echo "Fetching Diosix M-mode hypervisor from ${serverip}:${board_dir}..."
tftpboot ${hv_addr} ${board_dir}/vmdiosix.bin
tftpboot ${fdt_addr} ${board_dir}/board.dtb
fdt addr ${fdt_addr}
echo "Jumping to M-mode hypervisor at ${hv_addr} (DTB ${fdt_addr})..."
mexec ${hv_addr} ${fdt_addr}
