#!/usr/bin/env python3
"""Build a minimal ISO9660 image containing an ELF payload as /KERNEL.ELF."""

import struct
import sys


def write_both_endian_u32(buf: bytearray, offset: int, val: int) -> None:
    struct.pack_into("<I", buf, offset, val)
    struct.pack_into(">I", buf, offset + 4, val)


def write_both_endian_u16(buf: bytearray, offset: int, val: int) -> None:
    struct.pack_into("<H", buf, offset, val)
    struct.pack_into(">H", buf, offset + 2, val)


def build_iso(elf_bytes: bytes) -> bytes:
    sector_size = 2048
    elf_sectors = max(1, (len(elf_bytes) + sector_size - 1) // sector_size)
    total_sectors = 18 + elf_sectors
    iso = bytearray(total_sectors * sector_size)

    # Sector 16: Primary Volume Descriptor (PVD).
    pvd = 16 * sector_size
    iso[pvd] = 0x01
    iso[pvd + 1 : pvd + 6] = b"CD001"
    iso[pvd + 6] = 0x01
    sys_id = b"DIOSIX                          "
    vol_id = b"DIOSIX_LIVE                     "
    iso[pvd + 8 : pvd + 40] = sys_id
    iso[pvd + 40 : pvd + 72] = vol_id
    write_both_endian_u32(iso, pvd + 80, total_sectors)
    write_both_endian_u16(iso, pvd + 120, 1)
    write_both_endian_u16(iso, pvd + 124, 1)
    write_both_endian_u16(iso, pvd + 128, sector_size)

    # Root directory record in PVD (34 bytes at offset 156) -> Sector 17.
    root_rec = pvd + 156
    iso[root_rec] = 34
    write_both_endian_u32(iso, root_rec + 2, 17)
    write_both_endian_u32(iso, root_rec + 10, sector_size)
    iso[root_rec + 25] = 0x02
    write_both_endian_u16(iso, root_rec + 28, 1)
    iso[root_rec + 32] = 1
    iso[root_rec + 33] = 0

    # Sector 17: Volume Descriptor Set Terminator (0xFF) or Root Directory?
    # Keep Sector 17 as Root Directory (matching PVD root_rec LBA 17).
    dir_off = 17 * sector_size
    iso[dir_off] = 34
    write_both_endian_u32(iso, dir_off + 2, 17)
    write_both_endian_u32(iso, dir_off + 10, sector_size)
    iso[dir_off + 25] = 0x02
    write_both_endian_u16(iso, dir_off + 28, 1)
    iso[dir_off + 32] = 1
    iso[dir_off + 33] = 0

    dotdot = dir_off + 34
    iso[dotdot] = 34
    write_both_endian_u32(iso, dotdot + 2, 17)
    write_both_endian_u32(iso, dotdot + 10, sector_size)
    iso[dotdot + 25] = 0x02
    write_both_endian_u16(iso, dotdot + 28, 1)
    iso[dotdot + 32] = 1
    iso[dotdot + 33] = 1

    # Directory entry for "KERNEL.ELF;1" -> Sector 18.
    kern = dir_off + 68
    name = b"KERNEL.ELF;1"
    iso[kern] = 46
    write_both_endian_u32(iso, kern + 2, 18)
    write_both_endian_u32(iso, kern + 10, len(elf_bytes))
    iso[kern + 25] = 0x00
    write_both_endian_u16(iso, kern + 28, 1)
    iso[kern + 32] = len(name)
    iso[kern + 33 : kern + 33 + len(name)] = name

    # Sector 18+: ELF binary payload.
    elf_off = 18 * sector_size
    iso[elf_off : elf_off + len(elf_bytes)] = elf_bytes
    return bytes(iso)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.elf> <output.iso>", file=sys.stderr)
        return 1
    with open(sys.argv[1], "rb") as f:
        elf_bytes = f.read()
    iso_bytes = build_iso(elf_bytes)
    with open(sys.argv[2], "wb") as f:
        f.write(iso_bytes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
