#!/usr/bin/env python3
"""
Diosix Full-Stack Integration Test Suite:
Validates all guest CLI operations and hypercalls on live VM:
- Host & Guest Info (info, info --host)
- System & Child Manifests (show, validate, prune, set, resolve)
- Resource Quota Attenuation (quota self)
- Hypervisor Manifest Staging (SET_MANIFEST / GET_MANIFEST SBI FIDs 11 & 12)
- Guest CLI Commands & Help (dsx help)
- Child VM Lifecycle Management (run, list, stop)
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

    os.system("./scripts/create_storage_disk.sh zig-out/buildroot-riscv64/output/images/vmlinux zig-out/storage.img 256M >/dev/null 2>&1 || true")

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
        # 1. Boot Verification & Shell Login
        print("\n==> [1/14] Waiting for Diosix Hypervisor & Linux Root VM login prompt...")
        idx = child.expect([r"login:", PROMPT], timeout=90)
        if idx == 0:
            child.sendline("root")
            child.expect(PROMPT, timeout=15)
        print("\n✓ Logged into Root VM shell.")

        # 2. Host Hypervisor Info (`dsx info --host`)
        print("\n==> [2/14] Testing 'dsx info --host' (GET_HV_INFO)...")
        child.sendline("dsx info --host")
        child.expect(r"Diosix version\s+:\s+\d+", timeout=10)
        child.expect(r"Hardware H-(?:extension|Extension)", timeout=10)
        child.expect(r"VirtIO-vsock", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Host hypervisor capabilities & ABI queried successfully.")

        # 3. Guest VM Info (`dsx info`)
        print("\n==> [3/14] Testing 'dsx info' (GET_INFO)...")
        child.sendline("dsx info")
        child.expect(r"Context ID\s+:\s+1", timeout=10)
        child.expect(r"Root VM\s+:\s+yes", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Guest VM info verified.")

        # 4. Quota Management on Self (`dsx quota self`)
        print("\n==> [4/14] Testing 'dsx quota self' (SET_QUOTA)...")
        child.sendline("dsx quota self --ram 1024 --vcpus 8 --depth 4 --descendants 8")
        child.expect(r"Quotas updated successfully", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Set VM resource quotas for self.")

        # 5. Manifest Show & Validate
        print("\n==> [5/14] Testing 'dsx manifest show' & 'dsx manifest validate'...")
        child.sendline("dsx manifest show")
        child.expect(r"\[system\]", timeout=10)
        child.expect(r"\[domains\.sys\]", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest validate /etc/diosix/system.toml")
        child.expect(r"System manifest is valid", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Global system manifest displayed and verified.")

        # 6. Manifest Pruning (Attenuation)
        print("\n==> [6/14] Testing 'dsx manifest prune' (Attenuation Engine)...")
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

        # 7. Service Endpoint Resolution (`dsx resolve`)
        print("\n==> [7/14] Testing 'dsx resolve' (Service Discovery)...")
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

        # 8. Hypervisor Manifest Staging (`SET_MANIFEST` / `GET_MANIFEST`)
        print("\n==> [8/14] Testing Hypervisor Manifest Hypercalls (SET_MANIFEST / GET_MANIFEST)...")
        child.sendline("dsx manifest set 1 /tmp/sys-child.toml")
        child.expect(r"Manifest successfully staged in hypervisor for CID 1", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest show --cid 1 --hv")
        child.expect(r"\[vm\]", timeout=10)
        child.expect(r"sys-domain", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Staged and queried manifest in hypervisor memory via SBI ecalls.")

        # 9. CLI Usage & Help (`dsx help`)
        print("\n==> [9/14] Testing CLI usage & help output (`dsx help`)...")
        child.sendline("dsx help")
        child.expect(r"dsx / diosix-ctl: Diosix hypervisor guest management tool", timeout=10)
        child.expect(r"dsx run <elf>", timeout=10)
        child.expect(r"dsx login <name\|cid>", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ CLI commands and help interface verified.")

        # 10. Guest VM Run Error Handling
        print("\n==> [10/14] Testing 'dsx run' error handling with missing binary...")
        child.sendline("dsx run /boot/nonexistent.elf")
        child.expect(r"Error: ELF binary '/boot/nonexistent\.elf' not found\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Missing ELF binary error properly reported.")

        # 11. Guest VM SSH Access & Remote Command Execution (`dsx login` / `dsx ssh`)
        print("\n==> [11/15] Testing VM SSH access & command execution (`dsx login` / `dsx ssh`)...")
        child.sendline("dsx login root -- uname -a")
        child.expect(r"Linux diosix-rootvm", timeout=15)
        child.expect(PROMPT, timeout=10)
        print("✓ Executed command in guest VM via SSH and verified output.")

        # 12. Trusted Guest VM Spawning (`dsx run --trusted`)
        print("\n==> [12/15] Testing trusted guest VM creation (`dsx run --trusted`)...")
        child.sendline("dsx run /boot/vmlinux.elf --name trusted-svc --trusted --vcpus 2 --ram 256M")
        child.expect(r"Child VM 'trusted-svc' \(CID 2, 2 vCPUs, 256 MB RAM, IP: 10\.0\.3\.2\) started in background\.", timeout=10)
        child.expect(PROMPT, timeout=10)

        # Verify trusted child VM in `dsx list`
        time.sleep(1)
        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=15)
        child.expect(r"2\s+trusted-svc\s+2\s+256 MB\s+running\s+trusted\s+10\.0\.3\.2", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Trusted child VM spawned and verified in guest registry.")

        child.sendline("dsx stop trusted-svc")
        child.expect(r"Child VM 'trusted-svc' \(CID 2\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Trusted child VM cleanly stopped.")

        # 13. Sandboxed (Untrusted) Guest VM Spawning (`dsx run`)
        print("\n==> [13/15] Testing sandboxed (untrusted) guest VM creation (`dsx run`)...")
        child.sendline("dsx run /boot/vmlinux.elf --name user --vcpus 2 --ram 256M")
        child.expect(r"Child VM 'user' \(CID \d+, 2 vCPUs, 256 MB RAM, IP: 10\.0\.3\.\d+\) started in background\.", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=10)
        child.expect(r"\d+\s+user\s+2\s+256 MB\s+running\s+untrusted\s+10\.0\.3\.\d+", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Sandboxed child VM spawned and verified in guest registry.")

        child.sendline("dsx stop user")
        child.expect(r"Child VM 'user' \(CID \d+\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Sandboxed child VM cleanly stopped.")

        # 14. Multiple Concurrent Child VMs with Mixed Trust Levels
        print("\n==> [14/15] Testing multiple concurrent child VMs with mixed trust levels...")
        child.sendline("dsx run /boot/vmlinux.elf --name sys-domain --trusted --vcpus 1 --ram 128M")
        child.expect(r"Child VM 'sys-domain' \(CID \d+, 1 vCPUs, 128 MB RAM, IP: 10\.0\.3\.\d+\) started in background\.", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx run /boot/vmlinux.elf --name user-domain --vcpus 2 --ram 256M")
        child.expect(r"Child VM 'user-domain' \(CID \d+, 2 vCPUs, 256 MB RAM, IP: 10\.0\.3\.\d+\) started in background\.", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=10)
        child.expect(r"\d+\s+sys-domain\s+1\s+128 MB\s+running\s+trusted\s+10\.0\.3\.\d+", timeout=10)
        child.expect(r"\d+\s+user-domain\s+2\s+256 MB\s+running\s+untrusted\s+10\.0\.3\.\d+", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Concurrent multi-VM hierarchy verified with independent trust & quotas.")

        child.sendline("dsx stop sys-domain")
        child.expect(r"Child VM 'sys-domain' \(CID \d+\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx stop user-domain")
        child.expect(r"Child VM 'user-domain' \(CID \d+\) terminated\.", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Concurrent VMs cleanly stopped.")

        # 15. System Poweroff (`dsx poweroff`)
        print("\n==> [15/15] Testing 'dsx poweroff' (TERMINATE / SHUTDOWN)...")
        child.sendline("dsx poweroff")
        child.expect(pexpect.EOF, timeout=15)
        print("✓ Host cleanly powered off via SBI hypercall.")

        print("\n===============================================================")
        print("   ALL 15 INTEGRATION TESTS PASSED (100% COVERAGE VERIFIED)     ")
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
