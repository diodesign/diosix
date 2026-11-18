"""Shared QEMU multi-host Ethernet hub and SSH test harness helpers."""

import os
import selectors
import shutil
import socket
import struct
import subprocess
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
        import threading
        self.stop_ev = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _drop_client(self, conn):
        self.clients.pop(conn, None)
        for fn in (lambda: self.sel.unregister(conn), conn.close):
            try:
                fn()
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
