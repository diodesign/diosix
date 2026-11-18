#!/usr/bin/env python3
"""Raspberry Pi HIL Runner, Shelly Chaos Harness & Diskless Boot Self-Test.

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import argparse
import os
import socket
import struct
import sys
import threading
import time
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import pexpect
from pexpect import fdpexpect

sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hil.boot_server import (  # noqa: E402
    DisklessHttpServer,
    FDT_BEGIN_NODE,
    FDT_END,
    FDT_END_NODE,
    FDT_MAGIC,
    patch_dtb_bootargs,
    render_dnsmasq_conf,
    render_ser2net_yaml,
    stage_tftp_host,
)
from hil.shelly import ShellyPlug  # noqa: E402
from lib.swarm_harness import DEFAULT_VDIOSIX, login_host, run_cmd  # noqa: E402

DEFAULT_NODE_ELF = "zig-out/guest-riscv64/bin/diosix-node.elf"


def _build_synthetic_dtb():
    st = bytearray()
    st.extend(struct.pack(">I", FDT_BEGIN_NODE) + b"\x00\x00\x00\x00")
    st.extend(struct.pack(">I", FDT_BEGIN_NODE) + b"chosen\x00\x00")
    st.extend(struct.pack(">I", FDT_END_NODE))
    st.extend(struct.pack(">I", FDT_END_NODE))
    st.extend(struct.pack(">I", FDT_END))
    rsv = b"\x00" * 16
    strings = b"model\x00"
    off_rsv = 40
    off_st = off_rsv + len(rsv)
    off_str = off_st + len(st)
    tot = off_str + len(strings)
    hdr = struct.pack(
        ">10I",
        FDT_MAGIC,
        tot,
        off_st,
        off_str,
        off_rsv,
        17,
        16,
        0,
        len(strings),
        len(st),
    )
    return hdr + rsv + bytes(st) + strings


def _test_shelly_mocks():
    state = {"gen3": False, "gen1": False}

    class Gen3Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            if self.path == "/rpc/Shelly.GetDeviceInfo":
                body = b'{"id":"shellyplusplugus","gen":3}'
            elif self.path.startswith("/rpc/Switch.GetStatus"):
                on_s = "true" if state["gen3"] else "false"
                body = f'{{"id":0,"output":{on_s},"apower":12.4}}'.encode()
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            ln = int(self.headers.get("Content-Length", "0"))
            req = json_loads(self.rfile.read(ln))
            was = state["gen3"]
            state["gen3"] = bool(req.get("on", False))
            body = (
                f'{{"was_on":{"true" if was else "false"}}}'
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    class Gen1Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            if self.path == "/rpc/Shelly.GetDeviceInfo" or self.path.startswith(
                "/rpc/Switch."
            ):
                self.send_response(404)
                self.end_headers()
                return
            if "turn=on" in self.path:
                state["gen1"] = True
            elif "turn=off" in self.path:
                state["gen1"] = False
            on_s = "true" if state["gen1"] else "false"
            body = f'{{"ison":{on_s},"power":8.0}}'.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    import json

    json_loads = lambda b: json.loads(b.decode("utf-8"))
    s3 = ThreadingHTTPServer(("127.0.0.1", 0), Gen3Handler)
    s1 = ThreadingHTTPServer(("127.0.0.1", 0), Gen1Handler)
    for srv in (s3, s1):
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        p3 = ShellyPlug("127.0.0.1", port=s3.server_address[1])
        assert p3.device_info()["gen"] == 3
        p3.power_cycle(0.05)
        assert p3.get_status()["output"] is True
        p3.set_power(False)
        assert p3.get_status()["output"] is False

        p1 = ShellyPlug("127.0.0.1", port=s1.server_address[1])
        p1.power_cycle(0.05)
        assert p1.get_status()["output"] is True
        assert p1.get_status()["gen"] == 1
    finally:
        for srv in (s3, s1):
            srv.shutdown()
            srv.server_close()


def _test_dtb_patcher():
    raw = _build_synthetic_dtb()
    p1 = patch_dtb_bootargs(raw, "diosix.mode=diskless console=ttyS0")
    hdr = struct.unpack(">10I", p1[:40])
    assert hdr[0] == FDT_MAGIC and hdr[1] == len(p1)
    assert b"diosix.mode=diskless console=ttyS0\x00" in p1
    p2 = patch_dtb_bootargs(
        p1, "diosix.mode=diskless diosix.swarm_ip=10.42.0.11"
    )
    assert b"diosix.swarm_ip=10.42.0.11\x00" in p2
    assert b"console=ttyS0" not in p2


def _test_diskless_qemu(kernel, node_elf):
    if not os.path.exists(node_elf):
        raise FileNotFoundError(f"missing node ELF: {node_elf}")
    dev_pub = ".zig-cache/dev_id_ed25519.pub"
    keys_p = dev_pub if os.path.exists(dev_pub) else None
    srv = DisklessHttpServer(node_elf, keys_path=keys_p, bind_host="127.0.0.1")
    h = None
    try:
        append_s = (
            "diosix.mode=diskless diosix.dev_keys=1 "
            f"diosix.boot_server=http://10.0.2.2:{srv.port}"
        )
        argv = [
            "qemu-system-riscv64",
            "-nographic",
            "-machine",
            "virt",
            "-cpu",
            "rv64,h=true,smstateen=true,sstc=true,v=true",
            "-smp",
            "4",
            "-m",
            "2048M",
            "-netdev",
            "user,id=net0",
            "-device",
            "virtio-net-device,netdev=net0",
            "-append",
            append_s,
            "-bios",
            "none",
            "-kernel",
            kernel,
        ]
        h = pexpect.spawn(argv[0], argv[1:], timeout=120, encoding="utf-8")
        h.delaybeforesend = 0.1
        h.logfile_read = sys.stdout
        p = login_host(h, "diskless")

        run_cmd(h, p, "mount | grep '/var/lib/diosix'", r"tmpfs")
        run_cmd(
            h,
            p,
            "test -s /var/lib/diosix/images/diosix-node.elf && echo ELF_OK",
            r"ELF_OK",
        )
        run_cmd(
            h,
            p,
            "grep -qE '^BOOT_SERVER=http://10\\.0\\.2\\.2:[0-9]+$' "
            "/run/diosix/node-env && echo ENV_OK",
            r"ENV_OK",
        )
        run_cmd(
            h,
            p,
            "dsx run diosix-node.elf --name ram-leaf --ram 128M --leaf",
            r"started in background",
            timeout=60,
        )
        run_cmd(h, p, "dsx list", r"ram-leaf", r"10\.0\.3\.2")
        run_cmd(h, p, "dsx stop ram-leaf", r"terminated")
        with srv.lock:
            reqs = list(srv.requests)
        assert "/SHA256SUMS" in reqs, f"missing SHA256SUMS fetch: {reqs}"
        assert "/images/diosix-node.elf" in reqs, f"missing ELF fetch: {reqs}"
        h.sendline("dsx host poweroff")
        time.sleep(1)
    finally:
        if h is not None and h.isalive():
            h.terminate(force=True)
        srv.close()


def run_self_test(kernel, node_elf):
    print("===============================================================")
    print("  Diosix HIL (Shelly, FDT & Zero-Drive Diskless Boot) Check    ")
    print("===============================================================")
    _test_shelly_mocks()
    print("[1/3] Mock Shelly Gen3 RPC & Gen1 fallback plug controls passed.")
    _test_dtb_patcher()
    print("[2/3] Pure-Python FDT /chosen/bootargs patcher passed.")
    _test_diskless_qemu(kernel, node_elf)
    print("\n[3/3] Zero-drive diskless QEMU HTTP boot & RAM leaf passed.")
    return 0


def _host_bootargs(lab_cfg, hosts, h):
    gw = lab_cfg["gateway_ip"]
    port = int(lab_cfg.get("http_port", 8088))
    ip_cidr = h["ip"]
    my_ip = ip_cidr.split("/")[0]
    peers = ",".join(
        p["ip"].split("/")[0] for p in hosts if p["name"] != h["name"]
    )
    cons = h.get("console_args", "console=ttyS0,115200 earlycon")
    args = (
        f"{cons} diosix.mode=diskless diosix.dev_keys=1 "
        f"diosix.boot_server=http://{gw}:{port} diosix.swarm_ip={ip_cidr}"
    )
    if peers:
        args += f" diosix.swarm_peers={peers}"
    return args


def cmd_setup_pi(lab_path, out_dir):
    cfg = tomllib.loads(open(lab_path).read())
    lab = cfg["lab"]
    hosts = cfg["hosts"]
    os.makedirs(out_dir, exist_ok=True)
    tftp_root = lab.get("tftp_root", "/srv/tftp")
    for h in hosts:
        bargs = _host_bootargs(lab, hosts, h)
        stage_tftp_host(
            tftp_root,
            h["mac"],
            h["vmdiosix_bin"],
            h.get("dtb"),
            bargs,
        )
    dns_c = render_dnsmasq_conf(
        lab.get("interface", "eth0"),
        lab["gateway_ip"],
        lab.get("dhcp_start", "10.42.0.100"),
        lab.get("dhcp_end", "10.42.0.200"),
        tftp_root,
        hosts,
    )
    with open(os.path.join(out_dir, "dnsmasq.conf"), "w") as f:
        f.write(dns_c)
    s2n_c = render_ser2net_yaml(hosts)
    with open(os.path.join(out_dir, "ser2net.yaml"), "w") as f:
        f.write(s2n_c)
    print(f"Wrote {out_dir}/dnsmasq.conf, {out_dir}/ser2net.yaml & {tftp_root}")
    return 0


def _open_ser2net(port, log_path):
    s = socket.create_connection(("127.0.0.1", int(port)), timeout=15)
    c = fdpexpect.fdspawn(s, timeout=180, encoding="utf-8")
    c._sock = s
    if log_path:
        c.logfile_read = open(log_path, "w", encoding="utf-8")
    return c


def _close_ser2net(c):
    try:
        if getattr(c, "logfile_read", None):
            c.logfile_read.close()
    except Exception:
        pass
    try:
        c._sock.close()
    except Exception:
        pass


def cmd_run_lab(lab_path, suite, log_dir):
    cfg = tomllib.loads(open(lab_path).read())
    lab = cfg["lab"]
    hosts = cfg["hosts"]
    os.makedirs(log_dir, exist_ok=True)
    for h in hosts:
        stage_tftp_host(
            lab.get("tftp_root", "/srv/tftp"),
            h["mac"],
            h["vmdiosix_bin"],
            h.get("dtb"),
            _host_bootargs(lab, hosts, h),
        )
    srv = DisklessHttpServer(
        lab.get("node_elf", DEFAULT_NODE_ELF),
        keys_path=lab.get("dev_keys"),
        apk_dir=lab.get("apk_dir"),
        bind_host=lab["gateway_ip"],
        port=int(lab.get("http_port", 8088)),
    )
    conns = []
    plugs = []
    try:
        for h in hosts:
            pl = ShellyPlug(
                h["plug_host"],
                switch_id=int(h.get("plug_switch", 0)),
                username=h.get("plug_user", "admin"),
                password=h.get("plug_password", ""),
            )
            plugs.append((h, pl))
            c = _open_ser2net(
                h["ser2net_port"], os.path.join(log_dir, f"{h['name']}.log")
            )
            conns.append(c)
            pl.power_cycle(2.0)

        prompts = [login_host(c, h["name"]) for c, (h, _) in zip(conns, plugs)]
        for c, p in zip(conns, prompts):
            run_cmd(c, p, "mount | grep '/var/lib/diosix'", r"tmpfs")
        if suite == "smoke":
            run_cmd(
                conns[0],
                prompts[0],
                "dsx run diosix-node.elf --name smoke-leaf --ram 128M --leaf",
                r"started in background",
                timeout=60,
            )
            run_cmd(conns[0], prompts[0], "dsx stop smoke-leaf", r"terminated")
        elif suite in ("swarm", "chaos-powerloss") and len(conns) >= 2:
            peer_ip = plugs[1][0]["ip"].split("/")[0]
            run_cmd(conns[1], prompts[1], "dsx swarm serve --daemon || true")
            run_cmd(
                conns[0],
                prompts[0],
                f"dsx swarm join {peer_ip} --json",
                r'"status":"joined"',
            )
            if suite == "chaos-powerloss":
                plugs[0][1].set_power(False)
                time.sleep(2.0)
                run_cmd(
                    conns[1],
                    prompts[1],
                    "dsx swarm status --json",
                    r"live_hosts",
                )
                plugs[0][1].set_power(True)
                p0 = login_host(conns[0], plugs[0][0]["name"])
                run_cmd(
                    conns[0],
                    p0,
                    f"dsx swarm join {peer_ip} --json",
                    r'"status":"joined"',
                )
        print(f"HIL suite '{suite}' completed across {len(conns)} hosts.")
        return 0
    finally:
        for c in conns:
            _close_ser2net(c)
        srv.close()


def main():
    parser = argparse.ArgumentParser(description="Diosix Raspberry Pi HIL tool")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--kernel", default=DEFAULT_VDIOSIX)
    parser.add_argument("--node-elf", default=DEFAULT_NODE_ELF)
    sub = parser.add_subparsers(dest="cmd")

    sp = sub.add_parser("setup-pi", help="Render dnsmasq/ser2net and TFTP")
    sp.add_argument("--lab", required=True)
    sp.add_argument("--out-dir", default="/etc/diosix-hil")

    rn = sub.add_parser("run", help="Execute suite on physical RV64 hosts")
    rn.add_argument("--lab", required=True)
    rn.add_argument(
        "--suite",
        choices=("smoke", "swarm", "chaos-powerloss"),
        default="smoke",
    )
    rn.add_argument("--log-dir", default=".zig-cache/hil-logs")

    args = parser.parse_args()
    if args.self_test:
        return run_self_test(args.kernel, args.node_elf)
    if args.cmd == "setup-pi":
        return cmd_setup_pi(args.lab, args.out_dir)
    if args.cmd == "run":
        return cmd_run_lab(args.lab, args.suite, args.log_dir)
    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
