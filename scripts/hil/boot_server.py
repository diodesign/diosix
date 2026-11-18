"""Raspberry Pi TFTP, DTB bootargs, diskless HTTP, dnsmasq & ser2net helpers.

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import hashlib
import os
import posixpath
import shutil
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.dont_write_bytecode = True

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def _align4(buf):
    rem = len(buf) % 4
    if rem:
        buf.extend(b"\x00" * (4 - rem))


def _pad4(n):
    return (n + 3) & ~3


def _read_cstr(buf, off):
    end = buf.find(b"\x00", off)
    if end < 0:
        raise ValueError("unterminated FDT string")
    return buf[off:end].decode("utf-8", errors="replace"), end + 1


def patch_dtb_bootargs(dtb_bytes, new_bootargs):
    """Set or replace /chosen/bootargs in an FDT v17 blob without dtc."""
    hdr = struct.unpack(">10I", dtb_bytes[:40])
    magic, tot, off_st, off_str, off_rsv, ver, comp, boot_cpu, sz_str, sz_st = (
        hdr
    )
    if magic != FDT_MAGIC:
        raise ValueError(f"bad FDT magic: 0x{magic:x}")

    rsvmap = dtb_bytes[off_rsv:off_st]
    strings = bytearray(dtb_bytes[off_str : off_str + sz_str])
    struct_in = dtb_bytes[off_st : off_st + sz_st]

    def find_or_add_str(name_bytes):
        target = name_bytes + b"\x00"
        pos = strings.find(target)
        if pos >= 0 and (pos == 0 or strings[pos - 1] == 0):
            return pos
        pos = len(strings)
        strings.extend(target)
        return pos

    bootargs_str_off = find_or_add_str(b"bootargs")
    bootargs_val = new_bootargs.encode("utf-8") + b"\x00"

    out_st = bytearray()
    off = 0
    stack = []
    chosen_seen = False
    bootargs_written = False

    while off + 4 <= len(struct_in):
        tok = struct.unpack(">I", struct_in[off : off + 4])[0]
        off += 4
        if tok == FDT_BEGIN_NODE:
            name, next_off = _read_cstr(struct_in, off)
            off = _pad4(next_off)
            stack.append(name)
            if stack == ["", "chosen"]:
                chosen_seen = True
            out_st.extend(struct.pack(">I", FDT_BEGIN_NODE))
            out_st.extend(name.encode("utf-8") + b"\x00")
            _align4(out_st)
        elif tok == FDT_END_NODE:
            if stack == ["", "chosen"] and not bootargs_written:
                out_st.extend(
                    struct.pack(
                        ">3I", FDT_PROP, len(bootargs_val), bootargs_str_off
                    )
                )
                out_st.extend(bootargs_val)
                _align4(out_st)
                bootargs_written = True
            if stack == [""] and not chosen_seen:
                out_st.extend(struct.pack(">I", FDT_BEGIN_NODE))
                out_st.extend(b"chosen\x00")
                _align4(out_st)
                out_st.extend(
                    struct.pack(
                        ">3I", FDT_PROP, len(bootargs_val), bootargs_str_off
                    )
                )
                out_st.extend(bootargs_val)
                _align4(out_st)
                out_st.extend(struct.pack(">I", FDT_END_NODE))
                chosen_seen = True
                bootargs_written = True
            if stack:
                stack.pop()
            out_st.extend(struct.pack(">I", FDT_END_NODE))
        elif tok == FDT_PROP:
            plen, nameoff = struct.unpack(">2I", struct_in[off : off + 8])
            off += 8
            pval = struct_in[off : off + plen]
            off = _pad4(off + plen)
            pname, _ = _read_cstr(strings, nameoff)
            if stack == ["", "chosen"] and pname == "bootargs":
                out_st.extend(
                    struct.pack(
                        ">3I", FDT_PROP, len(bootargs_val), bootargs_str_off
                    )
                )
                out_st.extend(bootargs_val)
                _align4(out_st)
                bootargs_written = True
            else:
                out_st.extend(struct.pack(">3I", FDT_PROP, plen, nameoff))
                out_st.extend(pval)
                _align4(out_st)
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            out_st.extend(struct.pack(">I", FDT_END))
            break
        else:
            raise ValueError(f"unknown FDT token: {tok}")

    new_off_rsv = 40
    if len(rsvmap) < 16:
        rsvmap = b"\x00" * 16
    new_off_st = new_off_rsv + len(rsvmap)
    new_off_str = new_off_st + len(out_st)
    new_tot = new_off_str + len(strings)
    new_hdr = struct.pack(
        ">10I",
        FDT_MAGIC,
        new_tot,
        new_off_st,
        new_off_str,
        new_off_rsv,
        ver,
        comp,
        boot_cpu,
        len(strings),
        len(out_st),
    )
    return new_hdr + rsvmap + bytes(out_st) + bytes(strings)


def stage_tftp_host(tftp_root, mac, vmdiosix_bin, dtb_path, bootargs):
    """Populate per-MAC TFTP boot directory with binary and patched DTB."""
    mac_dir = mac.lower().replace(":", "-")
    dst_dir = os.path.join(tftp_root, mac_dir)
    os.makedirs(dst_dir, exist_ok=True)
    shutil.copy2(vmdiosix_bin, os.path.join(dst_dir, "vmdiosix.bin"))
    if dtb_path and os.path.exists(dtb_path):
        raw_dtb = open(dtb_path, "rb").read()
        patched = patch_dtb_bootargs(raw_dtb, bootargs)
        with open(os.path.join(dst_dir, "board.dtb"), "wb") as f:
            f.write(patched)
    return dst_dir


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            blk = f.read(65536)
            if not blk:
                break
            h.update(blk)
    return h.hexdigest()


class DisklessHttpServer:
    """Serves SHA256SUMS, images/diosix-node.elf, keys, and APK seeds."""

    def __init__(
        self,
        node_elf_path,
        keys_path=None,
        apk_dir=None,
        bind_host="127.0.0.1",
        port=0,
    ):
        self.node_elf_path = os.path.abspath(node_elf_path)
        self.keys_path = os.path.abspath(keys_path) if keys_path else None
        self.apk_dir = os.path.abspath(apk_dir) if apk_dir else None
        self.lock = threading.Lock()
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def _send_bytes(self, code, ctype, data):
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _send_file(self, fpath):
                if not os.path.isfile(fpath):
                    self._send_bytes(404, "text/plain", b"not found\n")
                    return
                sz = os.path.getsize(fpath)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(sz))
                self.end_headers()
                with open(fpath, "rb") as f:
                    while True:
                        blk = f.read(65536)
                        if not blk:
                            break
                        self.wfile.write(blk)

            def do_GET(self):
                clean = posixpath.normpath(self.path.split("?")[0])
                with outer.lock:
                    outer.requests.append(clean)
                if clean == "/SHA256SUMS":
                    lines = [
                        f"{_sha256_file(outer.node_elf_path)}  "
                        "images/diosix-node.elf\n"
                    ]
                    if outer.keys_path and os.path.isfile(outer.keys_path):
                        lines.append(
                            f"{_sha256_file(outer.keys_path)}  "
                            "keys/dev_authorized_keys\n"
                        )
                    body = "".join(lines).encode("utf-8")
                    self._send_bytes(200, "text/plain", body)
                    return
                if clean == "/images/diosix-node.elf":
                    self._send_file(outer.node_elf_path)
                    return
                if clean == "/keys/dev_authorized_keys" and outer.keys_path:
                    self._send_file(outer.keys_path)
                    return
                if clean.startswith("/apk/") and outer.apk_dir:
                    rel = clean[len("/apk/") :]
                    if ".." in rel.split("/"):
                        self._send_bytes(403, "text/plain", b"forbidden\n")
                        return
                    self._send_file(os.path.join(outer.apk_dir, rel))
                    return
                self._send_bytes(404, "text/plain", b"not found\n")

        self.srv = ThreadingHTTPServer((bind_host, int(port)), Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(
            target=self.srv.serve_forever, daemon=True
        )
        self.thread.start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def render_dnsmasq_conf(
    iface, gateway_ip, range_start, range_end, tftp_root, hosts
):
    lines = [
        f"interface={iface}",
        "bind-interfaces",
        f"dhcp-range={range_start},{range_end},12h",
        f"dhcp-option=3,{gateway_ip}",
        f"dhcp-option=6,{gateway_ip}",
        "enable-tftp",
        f"tftp-root={tftp_root}",
    ]
    for h in hosts:
        mac = h["mac"].lower()
        ip = h["ip"].split("/")[0]
        name = h["name"]
        lines.append(f"dhcp-host={mac},{ip},{name},12h")
    return "\n".join(lines) + "\n"


def render_ser2net_yaml(hosts):
    lines = ["%YAML 1.1", "---"]
    for idx, h in enumerate(hosts):
        port = int(h.get("ser2net_port", 7001 + idx))
        dev = h["serial"]
        name = h["name"]
        lines.extend(
            [
                f"connection: &{name}",
                f"  accepter: tcp,127.0.0.1,{port}",
                "  enable: on",
                f"  connector: serialdev,{dev},115200n81,local",
                "  options:",
                "    kickolduser: true",
            ]
        )
    return "\n".join(lines) + "\n"
