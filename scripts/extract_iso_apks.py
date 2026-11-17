#!/usr/bin/env python3
"""
Extract /apks/riscv64/*.apk and APKINDEX.tar.gz from an Alpine ISO.

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import os
import struct
import sys

SECTOR_SIZE = 2048


def parse_rr_name(fp, su_bytes):
    parts = []
    stack = [su_bytes]
    while stack:
        su = stack.pop(0)
        pos = 0
        while pos + 4 <= len(su):
            sig = su[pos : pos + 2]
            slen = su[pos + 2]
            if slen < 4 or pos + slen > len(su):
                break
            if sig == b"NM" and slen >= 5:
                chunk = su[pos + 5 : pos + slen].decode("utf-8", "replace")
                parts.append(chunk)
            elif sig == b"CE" and slen >= 28:
                ce_lba = struct.unpack("<I", su[pos + 4 : pos + 8])[0]
                ce_off = struct.unpack("<I", su[pos + 12 : pos + 16])[0]
                ce_len = struct.unpack("<I", su[pos + 20 : pos + 24])[0]
                fp.seek(ce_lba * SECTOR_SIZE + ce_off)
                stack.append(fp.read(ce_len))
            pos += slen
    return "".join(parts)


def list_iso_dir(fp, lba, size):
    fp.seek(lba * SECTOR_SIZE)
    buf = fp.read(size)
    pos = 0
    entries = {}
    while pos < len(buf):
        rlen = buf[pos]
        if rlen == 0:
            pos = ((pos // SECTOR_SIZE) + 1) * SECTOR_SIZE
            continue
        rec = buf[pos : pos + rlen]
        if len(rec) < 34:
            break
        elba = struct.unpack("<I", rec[2:6])[0]
        elen = struct.unpack("<I", rec[10:14])[0]
        flags = rec[25]
        nlen = rec[32]
        raw_name = rec[33 : 33 + nlen].decode("latin1")
        su_off = 33 + nlen + (1 if nlen % 2 == 0 else 0)
        rr_name = parse_rr_name(fp, rec[su_off:])
        fname = rr_name if rr_name else raw_name.split(";")[0]
        if fname not in ("\x00", "\x01", ".", "..") and "/" not in fname:
            entries[fname] = (elba, elen, bool(flags & 2))
        pos += rlen
    return entries


def extract_apks(iso_path, dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    with open(iso_path, "rb") as fp:
        fp.seek(16 * SECTOR_SIZE)
        pvd = fp.read(SECTOR_SIZE)
        if pvd[:6] != b"\x01CD001":
            raise RuntimeError("Not an ISO9660 image")
        rrec = pvd[156 : 156 + 34]
        root_lba, root_len = struct.unpack("<II", rrec[2:6] + rrec[10:14])
        root_ents = list_iso_dir(fp, root_lba, root_len)
        apks_ent = root_ents.get("apks")
        if not apks_ent or not apks_ent[2]:
            raise RuntimeError("ISO missing /apks directory")
        apks_ents = list_iso_dir(fp, apks_ent[0], apks_ent[1])
        arch_ent = apks_ents.get("riscv64")
        if not arch_ent or not arch_ent[2]:
            raise RuntimeError("ISO missing /apks/riscv64 directory")
        arch_ents = list_iso_dir(fp, arch_ent[0], arch_ent[1])
        count = 0
        for name, (lba, size, is_dir) in arch_ents.items():
            if is_dir:
                continue
            if name != "APKINDEX.tar.gz" and not name.endswith(".apk"):
                continue
            fp.seek(lba * SECTOR_SIZE)
            data = fp.read(size)
            out_path = os.path.join(dest_dir, name)
            with open(out_path, "wb") as out_f:
                out_f.write(data)
            count += 1
        return count


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <iso_path> <dest_dir>", file=sys.stderr)
        sys.exit(1)
    n = extract_apks(sys.argv[1], sys.argv[2])
    print(f"Extracted {n} APK repo files to {sys.argv[2]}")


if __name__ == "__main__":
    main()
