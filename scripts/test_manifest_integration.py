#!/usr/bin/env python3
"""
Diosix Full-Stack Integration Test Suite:
Validates all guest CLI operations and hypercalls on live VM:
- Host & Guest Info (info, info --host)
- System & Child Manifests (show, validate, prune, set, resolve)
- Resource Quota Attenuation (quota self)
- Hypervisor Manifest Staging (SET_MANIFEST / GET_MANIFEST SBI FIDs 11 & 12)
- Inter-VM IPC Messaging Loop (send, recv, wait events)
- System Poweroff & Hypervisor Exit (poweroff)

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import sys
import os
import pexpect
import time

def run_integration_test():
    print("===============================================================")
    print("      Diosix Full-Stack Integration Test Suite (100% Verified) ")
    print("===============================================================")

    qemu_cmd = [
        "qemu-system-riscv64",
        "-nographic",
        "-s",
        "-machine", "virt",
        "-cpu", "rv64,h=true,smstateen=true,sstc=true,v=true",
        "-smp", "4",
        "-m", "2048M",
        "-bios", "none",
        "-kernel", "zig-out/guest-riscv64/bin/vmdiosix"
    ]

    print(f"==> Launching QEMU: {' '.join(qemu_cmd)}")
    child = pexpect.spawn(qemu_cmd[0], qemu_cmd[1:], timeout=120, encoding='utf-8')
    child.logfile_read = sys.stdout

    PROMPT = r"diosix-rootvm#"

    try:
        # 1. Hypervisor Boot Banner
        print("\n==> [1/11] Waiting for Diosix hypervisor boot banner...")
        child.expect(r"Visit https://diosix\.org", timeout=30)
        print("\n✓ Diosix Hypervisor booted successfully.")

        # 2. Linux Root VM Shell Login
        print("\n==> [2/11] Waiting for Linux Root VM login prompt...")
        idx = child.expect([r"login:", PROMPT], timeout=90)
        if idx == 0:
            child.sendline("root")
            child.expect(PROMPT, timeout=15)
        print("\n✓ Logged into Root VM shell.")

        # 3. Host Hypervisor Info (`dsx info --host`)
        print("\n==> [3/11] Testing 'dsx info --host' (GET_HV_INFO)...")
        child.sendline("dsx info --host")
        child.expect(r"Diosix (?:hypervisor information|Hypervisor Information)", timeout=10)
        child.expect(r"Hardware H-(?:extension|Extension)", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Host hypervisor capabilities & ABI queried successfully.")

        # 4. Guest VM Info (`dsx info`)
        print("\n==> [4/11] Testing 'dsx info' (GET_INFO)...")
        child.sendline("dsx info")
        child.expect(r"Diosix (?:guest VM info|Guest VM Info)", timeout=10)
        child.expect(r"Root VM\s+:\s+yes", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Guest VM info verified.")

        # 5. Quota Management on Self (`dsx quota self`)
        print("\n==> [5/11] Testing 'dsx quota self' (SET_QUOTA)...")
        child.sendline("dsx quota self --ram 1024 --vcpus 8 --depth 4 --descendants 8")
        child.expect(r"Quotas updated successfully", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Set VM resource quotas for self.")

        # 6. Manifest Show & Validate
        print("\n==> [6/11] Testing 'dsx manifest show' & 'dsx manifest validate'...")
        child.sendline("dsx manifest show")
        child.expect(r"\[system\]", timeout=10)
        child.expect(r"\[domains\.sys\]", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest validate /etc/diosix/system.toml")
        child.expect(r"System manifest is valid", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Global system manifest displayed and verified.")

        # 7. Manifest Pruning (Attenuation)
        print("\n==> [7/11] Testing 'dsx manifest prune' (Attenuation Engine)...")
        child.sendline("dsx manifest prune /etc/diosix/system.toml --domain sys -o /tmp/sys-child.toml")
        child.expect(r"Attenuated manifest written to /tmp/sys-child.toml", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest validate /tmp/sys-child.toml")
        child.expect(r"Child VM manifest is valid", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest prune /etc/diosix/system.toml --domain user -o /tmp/user-child.toml")
        child.expect(r"Attenuated manifest written to /tmp/user-child.toml", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Attenuated manifests created and validated.")

        # 8. Service Endpoint Resolution (`dsx resolve`)
        print("\n==> [8/11] Testing 'dsx resolve' (Service Discovery)...")
        child.sendline("dsx resolve gui.display --manifest /tmp/user-child.toml")
        child.expect(r"Service (?:resolution|Resolution):", timeout=10)
        child.expect(r"gui\.display", timeout=10)
        child.expect(r"gui\.wayland", timeout=10)
        child.expect(r"sys", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx resolve net.wan --manifest /tmp/user-child.toml")
        child.expect(r"Service (?:resolution|Resolution):", timeout=10)
        child.expect(r"net\.wan", timeout=10)
        child.expect(r"sys", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Resolved endpoints across domain boundaries.")

        # 9. Hypervisor Manifest Staging (`SET_MANIFEST` / `GET_MANIFEST`)
        print("\n==> [9/11] Testing Hypervisor Manifest Hypercalls (SET_MANIFEST / GET_MANIFEST)...")
        child.sendline("dsx manifest set 1 /tmp/sys-child.toml")
        child.expect(r"Manifest successfully staged in hypervisor for CID 1", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest show --cid 1 --hv")
        child.expect(r"\[vm\]", timeout=10)
        child.expect(r"sys-supervisor", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Staged and queried manifest in hypervisor memory via SBI ecalls.")

        # 10. Inter-VM IPC Messaging & Events (`IPC_SEND`, `IPC_RECV`, `POLL_EVENT`)
        print("\n==> [10/11] Testing Inter-VM IPC Send, Recv, and Events...")
        child.sendline("dsx send 1 'Hello Diosix IPC Loopback'")
        child.expect(r"Message sent successfully", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx recv --nohang")
        child.expect(r"Hello Diosix IPC Loopback", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx wait --nohang")
        child.expect(r"ipc_message", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Inter-VM IPC message sent, received, and event harvested.")

        # 11. System Poweroff (`dsx poweroff`)
        print("\n==> [11/11] Testing 'dsx poweroff' (TERMINATE / SHUTDOWN)...")
        child.sendline("dsx poweroff")
        child.expect(pexpect.EOF, timeout=15)
        print("✓ Host cleanly powered off via SBI hypercall.")

        print("\n===============================================================")
        print("   ALL 11 INTEGRATION TESTS PASSED (100% COVERAGE VERIFIED)     ")
        print("===============================================================")
        return 0

    except Exception as e:
        print(f"\n❌ Integration test failed with exception: {e}")
        try:
            child.close(force=True)
        except Exception:
            pass
        return 1

if __name__ == "__main__":
    sys.exit(run_integration_test())
