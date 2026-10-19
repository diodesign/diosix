#!/usr/bin/env python3
"""Build a minimal ISO9660 image containing an ELF payload as /KERNEL.ELF."""

import struct
import sys

SECTOR_SIZE = 2048
PVD_SECTOR = 16
VDST_SECTOR = 17
ROOT_DIR_SECTOR = 18
KERNEL_SECTOR = 19

VD_TYPE_PRIMARY = 0x01
VD_TYPE_TERMINATOR = 0xff
ISO_STD_ID = b"CD001"
ISO_STD_VER = 0x01

PVD_SYS_ID_OFF = 8
PVD_VOL_ID_OFF = 40
PVD_ID_LEN = 32
PVD_VOL_SPACE_OFF = 80
PVD_VOL_SET_SIZE_OFF = 120
PVD_VOL_SEQ_NUM_OFF = 124
PVD_LOGICAL_BLK_OFF = 128
PVD_ROOT_REC_OFF = 156

DIR_REC_MIN_LEN = 34
KERNEL_REC_LEN = 46
REC_EXTENT_OFF = 2
REC_SIZE_OFF = 10
REC_FLAGS_OFF = 25
REC_VOL_SEQ_OFF = 28
REC_NAME_LEN_OFF = 32
REC_NAME_OFF = 33
DIR_FLAG_FILE = 0x00
DIR_FLAG_DIRECTORY = 0x02


def write_both_endian_u32(buf: bytearray, offset: int, val: int) -> None:
    struct.pack_into("<I", buf, offset, val)
    struct.pack_into(">I", buf, offset + 4, val)


def write_both_endian_u16(buf: bytearray, offset: int, val: int) -> None:
    struct.pack_into("<H", buf, offset, val)
    struct.pack_into(">H", buf, offset + 2, val)


def build_iso(elf_bytes: bytes) -> bytes:
    elf_sectors = max(1, (len(elf_bytes) + SECTOR_SIZE - 1) // SECTOR_SIZE)
    total_sectors = KERNEL_SECTOR + elf_sectors
    iso = bytearray(total_sectors * SECTOR_SIZE)

    # Sector 16: Primary Volume Descriptor (PVD).
    pvd = PVD_SECTOR * SECTOR_SIZE
    iso[pvd] = VD_TYPE_PRIMARY
    iso[pvd + 1 : pvd + 6] = ISO_STD_ID
    iso[pvd + 6] = ISO_STD_VER
    sys_id = b"DIOSIX".ljust(PVD_ID_LEN, b" ")
    vol_id = b"DIOSIX_LIVE".ljust(PVD_ID_LEN, b" ")
    iso[pvd + PVD_SYS_ID_OFF : pvd + PVD_SYS_ID_OFF + PVD_ID_LEN] = sys_id
    iso[pvd + PVD_VOL_ID_OFF : pvd + PVD_VOL_ID_OFF + PVD_ID_LEN] = vol_id
    write_both_endian_u32(iso, pvd + PVD_VOL_SPACE_OFF, total_sectors)
    write_both_endian_u16(iso, pvd + PVD_VOL_SET_SIZE_OFF, 1)
    write_both_endian_u16(iso, pvd + PVD_VOL_SEQ_NUM_OFF, 1)
    write_both_endian_u16(iso, pvd + PVD_LOGICAL_BLK_OFF, SECTOR_SIZE)

    # Root directory record in PVD (34 bytes at offset 156) -> Sector 18.
    root_rec = pvd + PVD_ROOT_REC_OFF
    iso[root_rec] = DIR_REC_MIN_LEN
    write_both_endian_u32(iso, root_rec + REC_EXTENT_OFF, ROOT_DIR_SECTOR)
    write_both_endian_u32(iso, root_rec + REC_SIZE_OFF, SECTOR_SIZE)
    iso[root_rec + REC_FLAGS_OFF] = DIR_FLAG_DIRECTORY
    write_both_endian_u16(iso, root_rec + REC_VOL_SEQ_OFF, 1)
    iso[root_rec + REC_NAME_LEN_OFF] = 1
    iso[root_rec + REC_NAME_OFF] = 0

    # Sector 17: Volume Descriptor Set Terminator (0xff).
    vdst = VDST_SECTOR * SECTOR_SIZE
    iso[vdst] = VD_TYPE_TERMINATOR
    iso[vdst + 1 : vdst + 6] = ISO_STD_ID
    iso[vdst + 6] = ISO_STD_VER

    # Sector 18: Root Directory ("." and ".." entries).
    dir_off = ROOT_DIR_SECTOR * SECTOR_SIZE
    iso[dir_off] = DIR_REC_MIN_LEN
    write_both_endian_u32(iso, dir_off + REC_EXTENT_OFF, ROOT_DIR_SECTOR)
    write_both_endian_u32(iso, dir_off + REC_SIZE_OFF, SECTOR_SIZE)
    iso[dir_off + REC_FLAGS_OFF] = DIR_FLAG_DIRECTORY
    write_both_endian_u16(iso, dir_off + REC_VOL_SEQ_OFF, 1)
    iso[dir_off + REC_NAME_LEN_OFF] = 1
    iso[dir_off + REC_NAME_OFF] = 0

    dotdot = dir_off + DIR_REC_MIN_LEN
    iso[dotdot] = DIR_REC_MIN_LEN
    write_both_endian_u32(iso, dotdot + REC_EXTENT_OFF, ROOT_DIR_SECTOR)
    write_both_endian_u32(iso, dotdot + REC_SIZE_OFF, SECTOR_SIZE)
    iso[dotdot + REC_FLAGS_OFF] = DIR_FLAG_DIRECTORY
    write_both_endian_u16(iso, dotdot + REC_VOL_SEQ_OFF, 1)
    iso[dotdot + REC_NAME_LEN_OFF] = 1
    iso[dotdot + REC_NAME_OFF] = 1

    # Directory entry for "KERNEL.ELF;1" -> Sector 19.
    kern = dir_off + (2 * DIR_REC_MIN_LEN)
    name = b"KERNEL.ELF;1"
    iso[kern] = KERNEL_REC_LEN
    write_both_endian_u32(iso, kern + REC_EXTENT_OFF, KERNEL_SECTOR)
    write_both_endian_u32(iso, kern + REC_SIZE_OFF, len(elf_bytes))
    iso[kern + REC_FLAGS_OFF] = DIR_FLAG_FILE
    write_both_endian_u16(iso, kern + REC_VOL_SEQ_OFF, 1)
    iso[kern + REC_NAME_LEN_OFF] = len(name)
    iso[kern + REC_NAME_OFF : kern + REC_NAME_OFF + len(name)] = name

    # Sector 19+: ELF binary payload.
    elf_off = KERNEL_SECTOR * SECTOR_SIZE
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
