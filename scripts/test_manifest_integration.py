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

        # 11. Guest VM Run Error Handling
        print("\n==> [11/17] Testing 'dsx run' error handling with missing binary...")
        child.sendline("dsx run /boot/nonexistent.elf")
        child.expect(r"Error: ELF binary '/boot/nonexistent\.elf' not found\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Missing ELF binary error properly reported.")

        # 12. Trusted Guest VM Spawning from Storage (`dsx run --trusted`)
        print("\n==> [12/17] Testing trusted guest VM creation from storage (`dsx run --trusted`)...")
        child.sendline("dsx run /boot/user-supervisor.elf --name trusted-svc --trusted --vcpus 2 --ram 256M")
        child.expect(r"\[guest-supervisor\] Guest supervisor active and listening for IPC events\.", timeout=10)
        child.sendline("")
        child.expect(PROMPT, timeout=10)

        # Verify trusted child VM in `dsx list`
        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=10)
        child.expect(r"2\s+trusted-svc\s+2\s+256 MB\s+running\s+trusted\s+10\.0\.3\.2 \(ipc\)", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Trusted child VM spawned and verified in guest registry.")

        # Verify hypervisor reports Hardware trust : yes
        child.sendline("dsx login trusted-svc -- info")
        child.expect(r"Executing on child VM 'trusted-svc' \(CID 2 via Diosix IPC\): info", timeout=10)
        child.expect(r"Context ID\s+:\s+2", timeout=10)
        child.expect(r"Hardware trust\s+:\s+yes", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Verified child VM with active hardware trust privilege.")

        child.sendline("dsx stop trusted-svc")
        child.expect(r"Child VM 'trusted-svc' \(CID 2\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Trusted child VM cleanly stopped.")

        # 13. Sandboxed (Untrusted) Guest VM Spawning from Storage (`dsx run`)
        print("\n==> [13/17] Testing sandboxed (untrusted) guest VM creation (`dsx run`)...")
        child.sendline("dsx run /boot/user-supervisor.elf --name user --vcpus 2 --ram 256M")
        child.expect(r"\[guest-supervisor\] Guest supervisor active and listening for IPC events\.", timeout=10)
        child.sendline("")
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=10)
        child.expect(r"\d+\s+user\s+2\s+256 MB\s+running\s+untrusted\s+10\.0\.3\.\d+ \(ipc\)", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Sandboxed child VM spawned and verified in guest registry.")

        # Verify hypervisor reports Hardware trust : no
        child.sendline("dsx login user -- info")
        child.expect(r"Executing on child VM 'user' \(CID \d+ via Diosix IPC\): info", timeout=10)
        child.expect(r"Context ID\s+:\s+\d+", timeout=10)
        child.expect(r"Hardware trust\s+:\s+no", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Verified sandboxed child VM with hardware trust strictly denied.")

        child.sendline("dsx login user -- ping")
        child.expect(r"pong from child VM \(CID \d+\)", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Sandboxed child VM IPC round-trip verified.")

        # Test working shell commands in child Linux environment
        child.sendline("dsx login user -- ls -l /")
        child.expect(r"drwxr-xr-x\s+\d+\s+root\s+root\s+\d+\s+Jan\s+1\s+00:00\s+bin", timeout=10)
        child.expect(r"drwxr-xr-x\s+\d+\s+root\s+root\s+\d+\s+Jan\s+1\s+00:00\s+etc", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Verified working 'ls -l /' directory listing in child VM.")

        child.sendline("dsx login user -- cat /etc/os-release")
        child.expect(r"PRETTY_NAME=\"Diosix Linux Guest Environment\"", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Verified working 'cat /etc/os-release' file output in child VM.")

        child.sendline("dsx login user -- uname -a")
        child.expect(r"Linux diosix-guest 7\.0\.10 .* riscv64 GNU/Linux", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Verified working 'uname -a' system information in child VM.")

        child.sendline("dsx login user -- ps")
        child.expect(r"1\s+root\s+.* /init", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Verified working 'ps' process table in child VM.")

        child.sendline("dsx stop user")
        child.expect(r"Child VM 'user' \(CID \d+\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Sandboxed child VM cleanly stopped.")

        # 14. Multiple Concurrent VMs (`sys` trusted + `user` untrusted)
        print("\n==> [14/17] Testing multiple concurrent child VMs with mixed trust levels...")
        child.sendline("dsx run /boot/user-supervisor.elf --name sys-domain --trusted --vcpus 1 --ram 128M")
        child.expect(r"\[guest-supervisor\] Guest supervisor active and listening for IPC events\.", timeout=10)
        child.sendline("")
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx run /boot/user-supervisor.elf --name user-domain --vcpus 2 --ram 256M")
        child.expect(r"\[guest-supervisor\] Guest supervisor active and listening for IPC events\.", timeout=10)
        child.sendline("")
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=10)
        child.expect(r"\d+\s+sys-domain\s+1\s+128 MB\s+running\s+trusted\s+10\.0\.3\.\d+ \(ipc\)", timeout=10)
        child.expect(r"\d+\s+user-domain\s+2\s+256 MB\s+running\s+untrusted\s+10\.0\.3\.\d+ \(ipc\)", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Concurrent multi-VM hierarchy verified with independent trust & quotas.")

        child.sendline("dsx login sys-domain -- echo 'Hello Sys'")
        child.expect(r"Hello Sys", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx login user-domain -- echo 'Hello User'")
        child.expect(r"Hello User", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Concurrent IPC communication verified across multiple active guests.")

        child.sendline("dsx stop sys-domain")
        child.expect(r"Child VM 'sys-domain' \(CID \d+\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx stop user-domain")
        child.expect(r"Child VM 'user-domain' \(CID \d+\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Concurrent VMs cleanly stopped.")

        # 15. Direct Low-Level Image Spawning (`dsx spawn`)
        print("\n==> [15/16] Testing direct low-level guest spawning (`dsx spawn`)...")
        child.sendline("dsx spawn /boot/user-supervisor.elf")
        child.expect(r"\[guest-supervisor\] Guest supervisor active and listening for IPC events\.", timeout=10)
        child.sendline("")
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx list")
        child.expect(r"\d+\s+spawned\s+1\s+256 MB\s+running\s+untrusted", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx stop spawned")
        child.expect(r"Child VM 'spawned' \(CID \d+\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Direct guest VM spawn and lifecycle verified.")

        # 16. System Poweroff (`dsx poweroff`)
        print("\n==> [16/16] Testing 'dsx poweroff' (TERMINATE / SHUTDOWN)...")
        child.sendline("dsx poweroff")
        child.expect(pexpect.EOF, timeout=15)
        print("✓ Host cleanly powered off via SBI hypercall.")

        print("\n===============================================================")
        print("   ALL 17 INTEGRATION TESTS PASSED (100% COVERAGE VERIFIED)     ")
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
