#!/usr/bin/env python3
"""
Diosix External Guest Workload Launcher & End-to-End Verifier.

Stages the SHA-256-verified Alpine Linux RISC-V ISO from
/etc/diosix/catalog.toml, boots Diosix in QEMU (graphical window by default,
or headless with --headless-verify), and launches two unmodified external
Linux guests running live workloads without manual copy-pasting:
  1. alpine-web (non-desktop): nginx HTTP server verified over VirtIO-Net
  2. alpine-desktop (desktop): Weston Wayland compositor + weston-terminal
     (running htop) rendered onto Diosix's emulated VirtIO-GPU 2D scanout

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import time
import tomllib
import urllib.request
import pexpect

CATALOG_PATH = "tools/overlay-common/etc/diosix/catalog.toml"
LAYOUT_PATH = "build/layout.zon"
CATALOG_IMAGE_ID = "alpine-riscv64"


def parse_zon_string(content, key):
    match = re.search(rf'\.{re.escape(key)}\s*=\s*"([^"]+)"', content)
    if not match:
        raise RuntimeError(f"Missing .{key} in {LAYOUT_PATH}")
    return match.group(1)


def parse_zon_int(content, key):
    match = re.search(rf"\.{re.escape(key)}\s*=\s*(\d+)", content)
    if not match:
        raise RuntimeError(f"Missing .{key} in {LAYOUT_PATH}")
    return int(match.group(1))


def load_layout():
    with open(LAYOUT_PATH, "r", encoding="utf-8") as f:
        raw = f.read()
    arch = parse_zon_string(raw, "default_arch")
    install_dir = parse_zon_string(raw, "install_dir_fmt").replace("{s}", arch)
    hv_name = parse_zon_string(raw, "name")
    elf_out = parse_zon_string(raw, "elf_out_fmt").replace("{s}", arch)
    return {
        "qemu_bin": parse_zon_string(raw, "system_bin"),
        "storage_script": parse_zon_string(raw, "storage_script"),
        "storage_img": parse_zon_string(raw, "storage_img"),
        "storage_size": parse_zon_string(raw, "storage_size"),
        "iso_cache_dir": parse_zon_string(raw, "iso_cache_dir"),
        "display_w": parse_zon_int(raw, "display_width"),
        "display_h": parse_zon_int(raw, "display_height"),
        "rootvm_elf": elf_out,
        "vmdiosix": os.path.join("zig-out", install_dir, hv_name),
    }


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def ensure_verified_iso(cache_dir):
    with open(CATALOG_PATH, "rb") as f:
        catalog = tomllib.load(f)
    entry = None
    for item in catalog.get("image", []):
        if item.get("id") == CATALOG_IMAGE_ID:
            entry = item
            break
    if entry is None:
        raise RuntimeError(f"Entry {CATALOG_IMAGE_ID} missing in catalog")

    filename = entry["filename"]
    url = entry["url"]
    expected_sha = entry["sha256"].lower()
    os.makedirs(cache_dir, exist_ok=True)
    iso_path = os.path.join(cache_dir, filename)

    if os.path.isfile(iso_path):
        actual = sha256_file(iso_path)
        if actual == expected_sha:
            print(f"✓ Verified cached ISO: {iso_path}")
            return filename
        print(f"! Cached ISO digest mismatch; re-fetching {filename}...")
        os.remove(iso_path)

    print(f"==> Downloading {url} ...")
    tmp_path = iso_path + ".part"
    urllib.request.urlretrieve(url, tmp_path)
    actual = sha256_file(tmp_path)
    if actual != expected_sha:
        os.remove(tmp_path)
        raise RuntimeError(
            f"SHA-256 mismatch for {filename}: got {actual}, "
            f"expected {expected_sha}"
        )
    os.replace(tmp_path, iso_path)
    print(f"✓ Downloaded and verified {iso_path}")
    return filename


def build_qemu_cmd(layout, args):
    cmd = [
        layout["qemu_bin"],
        "-machine",
        "virt",
        "-cpu",
        "rv64,h=true,smstateen=true,sstc=true,v=true",
        "-smp",
        str(args.smp),
        "-m",
        args.mem,
        "-drive",
        f"file={layout['storage_img']},if=none,format=raw,id=hd0",
        "-device",
        "virtio-blk-device,drive=hd0",
        "-netdev",
        "user,id=net0",
        "-device",
        "virtio-net-device,netdev=net0",
    ]
    if args.headless_verify:
        cmd.append("-nographic")
    else:
        w = layout["display_w"]
        h = layout["display_h"]
        cmd.extend(
            [
                "-serial",
                "mon:stdio",
                "-display",
                "gtk,zoom-to-fit=off",
                "-device",
                f"virtio-gpu-pci,xres={w},yres={h}",
                "-device",
                "virtio-keyboard-pci",
                "-device",
                "virtio-tablet-pci",
            ]
        )
    cmd.extend(
        [
            "-append",
            "diosix.mode=dev",
            "-bios",
            "none",
            "-kernel",
            layout["vmdiosix"],
        ]
    )
    return cmd


def run_cmd(child, prompt, cmd, *patterns, timeout=60):
    child.sendline(cmd)
    chunks = []
    for pat in patterns:
        child.expect(pat, timeout=timeout)
        chunks.append(child.before + (child.after or ""))
    child.expect(prompt, timeout=timeout)
    chunks.append(child.before)
    return "".join(chunks)


def attach_guest_root(child, vm_name, timeout=180):
    child.sendline(f"dsx console {vm_name}")
    child.expect(r"Connected to guest", timeout=20)
    deadline = time.monotonic() + timeout
    while True:
        rem = max(5.0, deadline - time.monotonic())
        idx = child.expect(
            [r"login:\s*", pexpect.TIMEOUT],
            timeout=min(12.0, rem),
        )
        if idx == 0:
            break
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Timed out waiting for {vm_name} login prompt")
        child.send("\r")
    child.sendline("root")
    child.expect(r"#[ \t]*", timeout=30)
    guest_prompt = f"{vm_name}-sh# "
    child.sendline(f"export PS1='{vm_name}-sh''# '")
    child.expect(re.escape(guest_prompt), timeout=15)
    return re.escape(guest_prompt)


def detach_guest(child, root_prompt):
    child.send("\x1d")
    child.expect(r"Detached from serial console", timeout=15)
    child.send("\r")
    child.expect(root_prompt, timeout=15)


def extract_guest_ip(list_out, vm_name):
    for line in list_out.splitlines():
        if vm_name in line:
            ip_m = re.search(r"\b(\d+\.\d+\.\d+\.\d+)\b", line)
            if ip_m:
                return ip_m.group(1)
    raise RuntimeError(f"Could not find IP for {vm_name} in:\n{list_out}")


def setup_alpine_repos(child, gprompt):
    repo_cmd = (
        "grep -q dl-cdn.alpinelinux.org /etc/apk/repositories || "
        "printf 'http://dl-cdn.alpinelinux.org/alpine/v3.24/main\\n"
        "http://dl-cdn.alpinelinux.org/alpine/v3.24/community\\n' "
        ">> /etc/apk/repositories"
    )
    run_cmd(child, gprompt, repo_cmd, timeout=20)


def provision_web_guest(child, root_prompt, iso_guest_path):
    print("\n==> [2/5] Booting external non-desktop guest 'alpine-web'...")
    run_cmd(
        child,
        root_prompt,
        f"dsx run {iso_guest_path} --name alpine-web "
        "--vcpus 2 --ram 512M --pcpu 25 --net wan",
        r"Started|CID",
        timeout=60,
    )
    list_out = run_cmd(child, root_prompt, "dsx list", r"alpine-web")
    web_ip = extract_guest_ip(list_out, "alpine-web")

    gprompt = attach_guest_root(child, "alpine-web")
    run_cmd(child, gprompt, "uname -m", r"riscv64", timeout=15)
    setup_alpine_repos(child, gprompt)

    print("\n==> [3/5] Installing & starting nginx inside 'alpine-web'...")
    run_cmd(
        child,
        gprompt,
        "apk add --no-cache nginx && printf '%s_%s\\n' APK_NGINX DONE",
        r"APK_NGINX_DONE",
        timeout=240,
    )
    for line in (
        "mkdir -p /var/www/html /run/nginx",
        "printf 'server { listen 80 default_server; "
        "root /var/www/html; index index.html; }\\n' "
        "> /etc/nginx/http.d/default.conf",
        "printf 'DIOSIX_ALPINE_WEB_OK host=%s kernel=%s arch=%s\\n' "
        "\"$(hostname)\" \"$(uname -sr)\" \"$(uname -m)\" "
        "> /var/www/html/index.html",
    ):
        run_cmd(child, gprompt, line, timeout=20)
    run_cmd(
        child,
        gprompt,
        "nginx && printf '%s_%s\\n' NGINX_STARTED OK",
        r"NGINX_STARTED_OK",
        timeout=30,
    )
    detach_guest(child, root_prompt)

    run_cmd(
        child,
        root_prompt,
        f"wget -qO- http://{web_ip}/",
        r"DIOSIX_ALPINE_WEB_OK",
        timeout=30,
    )
    print(f"\n✓ Verified live HTTP workload at http://{web_ip}/")
    return web_ip


def provision_desktop_guest(child, root_prompt, iso_guest_path):
    print("\n==> [4/5] Booting external graphical guest 'alpine-desktop'...")
    run_cmd(
        child,
        root_prompt,
        f"dsx run {iso_guest_path} --name alpine-desktop "
        "--vcpus 2 --ram 1024M --pcpu 35 --net wan",
        r"Started|CID",
        timeout=60,
    )
    gprompt = attach_guest_root(child, "alpine-desktop")
    setup_alpine_repos(child, gprompt)

    print("\n==> [5/5] Installing Weston Wayland desktop + htop workload...")
    pkg_cmd = (
        "apk add --no-cache eudev weston weston-backend-drm "
        "weston-shell-desktop weston-clients weston-terminal "
        "seatd font-dejavu htop && printf '%s_%s\\n' APK_WESTON DONE"
    )
    run_cmd(child, gprompt, pkg_cmd, r"APK_WESTON_DONE", timeout=300)

    for line in (
        "modprobe virtio-gpu virtio_input 2>/dev/null || true",
        "udevd -d 2>/dev/null || true",
        "udevadm trigger --type=subsystems --action=add 2>/dev/null || true",
        "udevadm trigger --type=devices --action=add 2>/dev/null || true",
        "udevadm settle 2>/dev/null || mdev -s 2>/dev/null || true",
        "mkdir -p /run/user/0 /root/.config && chmod 700 /run/user/0",
        "printf '[core]\\nuse-pixman=true\\nrequire-input=false\\n"
        "idle-time=0\\n\\n[shell]\\nbackground-color=0xff1b2432\\n"
        "panel-position=top\\nlocking=false\\n' > /root/.config/weston.ini",
    ):
        run_cmd(child, gprompt, line, timeout=25)

    run_cmd(
        child,
        gprompt,
        "test -e /dev/dri/card0 && cat /sys/class/drm/card0-Virtual-1/status",
        r"connected",
        timeout=20,
    )
    run_cmd(child, gprompt, "seatd -u root >/tmp/seatd.log 2>&1 &", timeout=15)
    run_cmd(child, gprompt, "sleep 1", timeout=15)
    run_cmd(
        child,
        gprompt,
        "XDG_RUNTIME_DIR=/run/user/0 SEATD_SOCK=/run/seatd.sock "
        "weston -B drm --use-pixman >/tmp/weston.log 2>&1 &",
        timeout=15,
    )
    run_cmd(
        child,
        gprompt,
        "for i in $(seq 1 30); do "
        "ls /run/user/0/wayland-* >/dev/null 2>&1 && break; sleep 1; done",
        timeout=45,
    )
    run_cmd(
        child,
        gprompt,
        "SOCK=$(basename $(ls /run/user/0/wayland-* 2>/dev/null | head -n1)) "
        "&& test -n \"$SOCK\" && "
        "XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=$SOCK "
        "weston-terminal --shell=/usr/bin/htop >/tmp/term.log 2>&1 &",
        timeout=20,
    )
    run_cmd(child, gprompt, "sleep 2", timeout=15)
    run_cmd(
        child,
        gprompt,
        "if pgrep -x weston >/dev/null && "
        "pgrep -x weston-terminal >/dev/null && "
        "grep -qx enabled /sys/class/drm/card0-Virtual-1/enabled; then "
        "printf '%s_%s\\n' DIOSIX_ALPINE DESKTOP_OK; "
        "else cat /tmp/weston.log /tmp/term.log 2>/dev/null; fi",
        r"DIOSIX_ALPINE_DESKTOP_OK",
        timeout=20,
    )
    detach_guest(child, root_prompt)
    print("\n✓ Verified Weston Wayland compositor + htop on VirtIO-GPU!")


def main():
    parser = argparse.ArgumentParser(
        description="Boot and verify external non-desktop & desktop guests."
    )
    parser.add_argument(
        "--headless-verify",
        action="store_true",
        help="Run headless, verify workloads, and power off cleanly.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--desktop-only",
        action="store_true",
        help="Boot and provision only the graphical 'alpine-desktop' guest.",
    )
    mode.add_argument(
        "--web-only",
        action="store_true",
        help="Boot and provision only the headless 'alpine-web' guest.",
    )
    parser.add_argument("--smp", type=int, default=6, help="QEMU SMP harts")
    parser.add_argument("--mem", default="4096M", help="QEMU RAM allocation")
    args = parser.parse_args()

    layout = load_layout()
    for req in (layout["vmdiosix"], layout["rootvm_elf"]):
        if not os.path.isfile(req):
            print(f"Missing {req}; run './scripts/build.sh' first.")
            return 1

    iso_filename = ensure_verified_iso(layout["iso_cache_dir"])
    iso_guest_path = f"/var/lib/diosix/iso/{iso_filename}"

    subprocess.run(
        ["pkill", "-9", "-x", layout["qemu_bin"]],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    subprocess.run(
        [
            "bash",
            layout["storage_script"],
            layout["rootvm_elf"],
            layout["storage_img"],
            layout["storage_size"],
            layout["iso_cache_dir"],
        ],
        check=True,
    )

    qemu_cmd = build_qemu_cmd(layout, args)
    print(f"==> Launching QEMU: {' '.join(qemu_cmd)}")
    child = pexpect.spawn(
        qemu_cmd[0], qemu_cmd[1:], timeout=180, encoding="utf-8"
    )
    child.logfile_read = sys.stdout
    child.delaybeforesend = 0.08

    try:
        print("\n==> [1/5] Waiting for Diosix Hypervisor & Root VM login...")
        child.expect(r"login:\s*", timeout=120)
        child.sendline("root")
        child.expect(r"#[ \t]*", timeout=30)
        child.sendline(
            "bind 'set enable-bracketed-paste off' 2>/dev/null || true"
        )
        child.expect(r"#[ \t]*", timeout=10)
        root_prompt = r"diosix-rootvm#\s*"
        child.sendline("export PS1='diosix-rootvm''# '")
        child.expect(root_prompt, timeout=10)

        web_ip = None
        expected_vms = []
        if not args.desktop_only:
            web_ip = provision_web_guest(child, root_prompt, iso_guest_path)
            expected_vms.append(r"alpine-web")
        if not args.web_only:
            provision_desktop_guest(child, root_prompt, iso_guest_path)
            expected_vms.append(r"alpine-desktop")
        run_cmd(child, root_prompt, "dsx list", *expected_vms)

        if args.headless_verify:
            print("\n==> Headless verification passed! Powering off...")
            child.sendline("dsx host poweroff")
            child.expect(pexpect.EOF, timeout=30)
            print("\n✓ External guest workload(s) verified cleanly.")
            return 0

        print("\n" + "=" * 68)
        print("  EXTERNAL GUEST WORKLOADS ARE LIVE!")
        if web_ip is not None:
            print(f"  - Web guest     : wget -qO- http://{web_ip}/")
        if not args.web_only:
            print("  - Desktop guest : In the QEMU GUI window, click:")
            print("                    Guests -> alpine-desktop ->")
            print("                    Open guest display")
        console_vm = "alpine-desktop" if args.desktop_only else "alpine-web"
        print(f"  - Serial shell  : dsx console {console_vm}  (Ctrl+] exit)")
        print("  - Shut down     : dsx host poweroff")
        print("=" * 68 + "\n")
        child.logfile_read = None
        child.send("\r")
        child.interact()
        return 0
    except Exception as exc:
        print(f"\n❌ External guest run failed: {exc}", file=sys.stderr)
        child.terminate(force=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
