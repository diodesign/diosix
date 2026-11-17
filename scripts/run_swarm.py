#!/usr/bin/env python3
"""Diosix Multi-Host Autonomous Swarm QEMU Orchestrator & E2E Verifier.

Connects N QEMU riscv64 Diosix hosts over an in-process Ethernet socket hub
and verifies multi-host sharding, recursive parent LLM proxy queries, and
democratic + M-mode rejection of compromised-Principal ransomware updates.

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import argparse
import os
import selectors
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import pexpect

DEFAULT_VDIOSIX = "zig-out/guest-riscv64/bin/vmdiosix"
DEFAULT_STORAGE = "zig-out/storage.img"


class FrameSwitch:
    """Broadcasts QEMU 4-byte length-prefixed Ethernet frames across peers."""

    def __init__(self):
        self.sel = selectors.DefaultSelector()
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(16)
        self.srv.setblocking(False)
        self.port = self.srv.getsockname()[1]
        self.sel.register(self.srv, selectors.EVENT_READ, data="accept")
        self.clients = {}
        self.stop_ev = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _drop_client(self, conn):
        self.clients.pop(conn, None)
        try:
            self.sel.unregister(conn)
        except Exception:
            pass
        try:
            conn.close()
        except Exception:
            pass

    def _run(self):
        while not self.stop_ev.is_set():
            events = self.sel.select(timeout=0.1)
            for key, _ in events:
                if key.data == "accept":
                    try:
                        conn, _ = self.srv.accept()
                        conn.setblocking(False)
                        self.clients[conn] = bytearray()
                        self.sel.register(conn, selectors.EVENT_READ, data=conn)
                    except OSError:
                        pass
                else:
                    conn = key.fileobj
                    try:
                        chunk = conn.recv(65536)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        self._drop_client(conn)
                        continue
                    buf = self.clients.get(conn)
                    if buf is None:
                        continue
                    buf.extend(chunk)
                    while len(buf) >= 4:
                        plen = struct.unpack("!I", buf[:4])[0]
                        if plen == 0 or plen > 65536:
                            self._drop_client(conn)
                            break
                        if len(buf) < 4 + plen:
                            break
                        pkt = bytes(buf[: 4 + plen])
                        del buf[: 4 + plen]
                        for peer in list(self.clients.keys()):
                            if peer is conn:
                                continue
                            try:
                                peer.sendall(pkt)
                            except OSError:
                                self._drop_client(peer)

    def close(self):
        self.stop_ev.set()
        self.thread.join(timeout=2)
        for conn in list(self.clients.keys()):
            self._drop_client(conn)
        try:
            self.sel.unregister(self.srv)
        except Exception:
            pass
        self.srv.close()
        self.sel.close()


def prepare_host_disk(idx, storage_img):
    os.makedirs(".zig-cache", exist_ok=True)
    disk_path = f".zig-cache/swarm-host-{idx}.img"
    if os.path.exists(disk_path):
        os.unlink(disk_path)
    qimg = shutil.which("qemu-img")
    if qimg:
        subprocess.run(
            [
                qimg,
                "create",
                "-q",
                "-f",
                "qcow2",
                "-F",
                "raw",
                "-b",
                os.path.abspath(storage_img),
                disk_path,
            ],
            check=True,
        )
        return "qcow2", disk_path
    shutil.copyfile(storage_img, disk_path)
    return "raw", disk_path


def spawn_host(idx, num_hosts, switch_port, kernel, disk_fmt, disk_path):
    mac = f"52:54:00:12:34:{idx + 1:02x}"
    ip_cidr = f"10.0.2.{11 + idx}/24"
    peers = ",".join(f"10.0.2.{11 + j}" for j in range(num_hosts) if j != idx)
    append_str = f"diosix.mode=dev diosix.swarm_ip={ip_cidr}"
    if peers:
        append_str += f" diosix.swarm_peers={peers}"
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
        "-drive",
        f"file={disk_path},if=none,format={disk_fmt},id=hd0",
        "-device",
        "virtio-blk-device,drive=hd0",
        "-netdev",
        f"socket,id=net0,connect=127.0.0.1:{switch_port}",
        "-device",
        f"virtio-net-device,netdev=net0,mac={mac}",
        "-append",
        append_str,
        "-bios",
        "none",
        "-kernel",
        kernel,
    ]
    child = pexpect.spawn(argv[0], argv[1:], timeout=120, encoding="utf-8")
    child.delaybeforesend = 0.1
    return child


def login_host(child, name):
    child.expect(r"login:\s*", timeout=120)
    child.sendline("root")
    child.expect(r"#[ \t]*", timeout=30)
    child.sendline(f"export PS1='{name}# '")
    prompt = rf"{name}#\s*"
    child.expect(prompt, timeout=10)
    return prompt


def run_cmd(child, prompt, cmd, *pats, timeout=30):
    child.sendline(cmd)
    for pat in pats:
        child.expect(pat, timeout=timeout)
    child.expect(prompt, timeout=timeout)


def write_charter(child, prompt, path, version, min_r, tgt_r, encrypt_str):
    lines = [
        "[charter]",
        'id = "swarm-db"',
        f"version = {version}",
        "stake_quorum_pct = 67",
        "[spec]",
        'goal = "Maintain replicated swarm database"',
        'mode = "swarm"',
        "fleet_hosts = 2",
        f"encrypt_volumes = {encrypt_str}",
        "[invariants]",
        "max_simultaneous_unit_termination_pct = 34",
        "forbid_zero_replicas = true",
        "forbid_unratified_encryption = true",
        "[[units]]",
        'id = "db"',
        'artifact = "diosix-node.elf"',
        'packages = "none"',
        f"min_instances = {min_r}",
        f"target_instances = {tgt_r}",
        "max_instances = 4",
        "vcpus = 1",
        'ram = "256M"',
    ]
    joined = "\\n".join(lines)
    run_cmd(child, prompt, f"printf '{joined}\\n' > {path}")


def run_self_test(kernel, storage_img):
    print("===============================================================")
    print("  Diosix Multi-Host Swarm & Anti-Ransomware E2E Verification   ")
    print("===============================================================")
    sw = FrameSwitch()
    disks = []
    hosts = []
    try:
        for i in range(2):
            fmt, dpath = prepare_host_disk(i, storage_img)
            disks.append(dpath)
            h = spawn_host(i, 2, sw.port, kernel, fmt, dpath)
            hosts.append(h)

        h1, h2 = hosts[0], hosts[1]
        h1.logfile_read = sys.stdout
        p1 = login_host(h1, "host1")
        p2 = login_host(h2, "host2")
        print("\n[1/8] Both QEMU Diosix hosts booted on shared socket LAN.")

        run_cmd(h2, p2, "dsx swarm serve --daemon || true")
        run_cmd(
            h1,
            p1,
            "dsx swarm join 10.0.2.12 --json",
            r'"status":"joined"',
            r'"peer_endpoint":"10\.0\.2\.12:8486"',
        )
        print("\n[2/8] Multi-host Ed25519 peer mesh verified.")

        run_cmd(h1, p1, "dsx charter keygen --priv /tmp/p.key --pub /tmp/p.pub")
        write_charter(h1, p1, "/tmp/v1.toml", 1, 2, 2, "false")
        run_cmd(
            h1,
            p1,
            "dsx charter sign --file /tmp/v1.toml --key /tmp/p.key --json",
            r'"status":"signed"',
        )
        run_cmd(
            h1,
            p1,
            "dsx charter deploy --file /tmp/v1.toml --json",
            r'"status":"sealed"',
            r'"mode":"mission"',
        )
        run_cmd(
            h2,
            p2,
            "dsx swarm join 10.0.2.11 --json",
            r'"adopted_charter":true',
        )
        run_cmd(h2, p2, "dsx charter status --json", r'"mission_sealed":true')
        print("\n[3/8] Principal-signed v1 sealed & adopted across fleet.")

        run_cmd(
            h1,
            p1,
            "dsx agent step --json",
            r'"replicas_spawned":1',
            timeout=45,
        )
        run_cmd(
            h2,
            p2,
            "dsx agent step --json",
            r'"replicas_spawned":1',
            timeout=45,
        )
        print("\n[4/8] Autonomous agents sharded replicas across 2 hosts.")

        run_cmd(
            h1,
            p1,
            "for i in $(seq 1 20); do "
            "dsx ssh db-1 -- dsx info >/dev/null 2>&1 && "
            "echo SSH_OK && break; sleep 2; done",
            r"SSH_OK",
            timeout=60,
        )
        run_cmd(
            h1,
            p1,
            'dsx ssh db-1 -- dsx agent ask "health check" --json',
            r'"provider":"parent"',
            r"approve",
            timeout=30,
        )
        print("\n[5/8] WAN-isolated child queried parent LLM proxy (:8081).")

        # Attack: validly signed ransomware drops replicas to 0 + encrypt.
        write_charter(h1, p1, "/tmp/ransom.toml", 2, 0, 0, "true")
        run_cmd(
            h1,
            p1,
            "dsx charter sign --file /tmp/ransom.toml --key /tmp/p.key",
            r"Signed Charter",
        )
        run_cmd(
            h1,
            p1,
            "dsx swarm propose --file /tmp/ransom.toml --json",
            r'"local_allowed":false',
        )
        run_cmd(
            h1,
            p1,
            "dsx ssh db-1 -- dsx agent step --json",
            r'"votes_rejected":1',
            timeout=30,
        )
        run_cmd(
            h1,
            p1,
            "dsx charter deploy --file /tmp/ransom.toml 2>&1 || true",
            r"Error:",
        )
        run_cmd(h1, p1, "dsx charter status --json", r'"mission_version":1')
        print("\n[6/8] Compromised-Principal ransomware vetoed cleanly.")

        # Benign amendment: scale target 2 -> 4, preserving min=2 & no encrypt.
        write_charter(h1, p1, "/tmp/v2.toml", 2, 2, 4, "false")
        run_cmd(
            h1,
            p1,
            "dsx charter sign --file /tmp/v2.toml --key /tmp/p.key",
            r"Signed Charter",
        )
        run_cmd(
            h1,
            p1,
            "dsx swarm propose --file /tmp/v2.toml --json",
            r'"local_allowed":true',
        )
        run_cmd(
            h1,
            p1,
            "dsx ssh db-1 -- dsx agent step --json",
            r'"votes_approved":1',
            timeout=30,
        )
        run_cmd(
            h1,
            p1,
            "dsx agent step --json",
            r'"sealed_version":2',
            r'"replicas_spawned":1',
            timeout=45,
        )
        run_cmd(h1, p1, "dsx charter status --json", r'"mission_version":2')
        print("\n[7/8] Signed scale-up v2 ratified by stake quorum & sealed.")

        h1.sendline("dsx host poweroff")
        h2.sendline("dsx host poweroff")
        time.sleep(1)
        print("\n[8/8] ALL MULTI-HOST SWARM CHECKS PASSED.")
        return 0
    finally:
        for h in hosts:
            try:
                if h.isalive():
                    h.terminate(force=True)
            except Exception:
                pass
        sw.close()
        for d in disks:
            if os.path.exists(d):
                os.unlink(d)


def main():
    parser = argparse.ArgumentParser(description="Diosix QEMU swarm runner")
    parser.add_argument("--hosts", type=int, default=2, help="Host count")
    parser.add_argument("--kernel", default=DEFAULT_VDIOSIX)
    parser.add_argument("--storage", default=DEFAULT_STORAGE)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run automated multi-host E2E verification",
    )
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test(args.kernel, args.storage))

    sw = FrameSwitch()
    disks = []
    hosts = []
    try:
        for i in range(args.hosts):
            fmt, dpath = prepare_host_disk(i, args.storage)
            disks.append(dpath)
            h = spawn_host(i, args.hosts, sw.port, args.kernel, fmt, dpath)
            hosts.append(h)
        print(
            f"Started {args.hosts} swarm hosts on switch port {sw.port}. "
            "Attaching to Host 1 serial (Ctrl-C exits cluster)..."
        )
        hosts[0].logfile_read = None
        hosts[0].interact()
    except KeyboardInterrupt:
        pass
    finally:
        for h in hosts:
            try:
                h.terminate(force=True)
            except Exception:
                pass
        sw.close()
        for d in disks:
            if os.path.exists(d):
                os.unlink(d)


if __name__ == "__main__":
    main()
