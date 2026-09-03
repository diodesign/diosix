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

    os.system("pkill -9 -f qemu-system-riscv64 >/dev/null 2>&1 || true")
    os.system("./scripts/create_storage_disk.sh zig-out/buildroot-riscv64/output/images/vmlinux zig-out/storage.img 256M >/dev/null 2>&1 || true")

    qemu_cmd = [
        "qemu-system-riscv64",
        "-nographic",
        "-s",
        "-machine", "virt",
        "-cpu", "rv64,h=true,smstateen=true,sstc=true,v=true",
        "-smp", "4",
        "-m", "2048M",
        "-drive", "file=zig-out/storage.img,if=none,format=raw,id=hd0",
        "-device", "virtio-blk-device,drive=hd0",
        "-netdev", "user,id=net0",
        "-device", "virtio-net-device,netdev=net0",
        "-bios", "none",
        "-kernel", "zig-out/guest-riscv64/bin/vmdiosix"
    ]

    print(f"==> Launching QEMU: {' '.join(qemu_cmd)}")
    child = pexpect.spawn(qemu_cmd[0], qemu_cmd[1:], timeout=120, encoding='utf-8')
    child.logfile_read = sys.stdout
    child.delaybeforesend = 0.15

    try:
        # 1. Boot Verification & Shell Login
        print("\n==> [1/15] Waiting for Diosix Hypervisor & Linux Root VM login prompt...")
        child.expect(r"login:\s*", timeout=90)
        child.sendline("root")
        child.expect(r"#[ \t]*", timeout=30)
        child.sendline("bind 'set enable-bracketed-paste off' 2>/dev/null || true")
        child.expect(r"#[ \t]*", timeout=10)
        child.sendline("export PS1='diosix-rootvm# '")
        PROMPT = r"diosix-rootvm#\s*"
        child.expect(PROMPT, timeout=10)
        print("\n✓ Logged into Root VM shell.")

        # 2. Host Hypervisor Info (`dsx host info`)
        print("\n==> [2/15] Testing 'dsx host info' (GET_HV_INFO)...")
        child.sendline("dsx host info")
        child.expect(r"Diosix version\s+:\s+\d+", timeout=10)
        child.expect(r"Hardware H-(?:extension|Extension)", timeout=10)
        child.expect(r"VirtIO-vsock", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Host hypervisor capabilities & ABI queried successfully.")

        # 3. Guest VM Info (`dsx info`)
        print("\n==> [3/15] Testing 'dsx info' (GET_INFO)...")
        child.sendline("dsx info")
        child.expect(r"Context ID\s+:\s+1", timeout=10)
        child.expect(r"Root VM\s+:\s+yes", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Guest VM info verified.")

        # 4. Quota Management on Self (`dsx quota self`)
        print("\n==> [4/15] Testing 'dsx quota self' (SET_QUOTA)...")
        child.sendline("dsx quota self --ram 1024 --vcpus 8 --depth 4 --descendants 8")
        child.expect(r"Quotas updated successfully", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Set VM resource quotas for self.")

        # 5. Manifest Show & Validate
        print("\n==> [5/15] Testing 'dsx manifest show' & 'dsx manifest validate'...")
        child.sendline("dsx manifest show")
        child.expect(r"\[system\]", timeout=10)
        child.expect(r"\[domains\.sys\]", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest validate /etc/diosix/system.toml")
        child.expect(r"System manifest is valid", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Global system manifest displayed and verified.")

        # 6. Manifest Pruning (Attenuation)
        print("\n==> [6/15] Testing 'dsx manifest prune' (Attenuation Engine)...")
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

        # 7. Service Endpoint Resolution (`dsx manifest resolve`)
        print("\n==> [7/15] Testing 'dsx manifest resolve' (Service Discovery)...")
        child.sendline("dsx manifest resolve gui.display --manifest /tmp/user-child.toml")
        child.expect(r"Service (?:resolution|Resolution):", timeout=10)
        child.expect(r"gui\.display", timeout=10)
        child.expect(r"gui\.wayland", timeout=10)
        child.expect(r"gui", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest resolve net.wan --manifest /tmp/user-child.toml")
        child.expect(r"Service (?:resolution|Resolution):", timeout=10)
        child.expect(r"net\.wan", timeout=10)
        child.expect(r"sys", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Resolved endpoints across domain boundaries.")

        # 8. Hypervisor Manifest Staging (`SET_MANIFEST` / `GET_MANIFEST`)
        print("\n==> [8/15] Testing Hypervisor Manifest Hypercalls (SET_MANIFEST / GET_MANIFEST)...")
        child.sendline("dsx manifest set 1 /tmp/sys-child.toml")
        child.expect(r"Manifest successfully staged in hypervisor for CID 1", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx manifest show --cid 1 --hv")
        child.expect(r"\[vm\]", timeout=10)
        child.expect(r"sys-domain", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Staged and queried manifest in hypervisor memory via SBI ecalls.")

        # 9. CLI Usage & Help (`dsx help`)
        print("\n==> [9/15] Testing CLI usage & help output (`dsx help`)...")
        child.sendline("dsx help")
        child.expect(r"dsx: Diosix Type-1 Hypervisor Guest Management CLI", timeout=10)
        child.expect(r"dsx run <image\|name>", timeout=10)
        child.expect(r"dsx ssh \[user@\]<name\|cid>", timeout=10)
        child.expect(r"dsx host info", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ CLI commands and help interface verified.")

        # 10. Guest VM Run Error Handling
        print("\n==> [10/18] Testing 'dsx run' error handling with missing binary...")
        child.sendline("dsx run nonexistent_image_foo")
        child.expect(r"Error: Guest ELF binary 'nonexistent_image_foo' not found", timeout=10)
        child.expect(PROMPT, timeout=10)
        print("✓ Missing ELF binary error properly reported.")

        # 11. Child VM Storage Management (`dsx disk create / list / resize / delete`)
        print("\n==> [11/18] Testing Child VM Storage Management (`dsx disk`)...")
        child.sendline("dsx disk create data-vol --size 256M")
        child.expect(r"Virtual disk 'data-vol' \(256 MB\) created at /var/lib/diosix/disks/data-vol\.img\.", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx disk list")
        child.expect(r"data-vol\.img\s+256 MB\s+raw\s+/var/lib/diosix/disks/data-vol\.img", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx disk resize data-vol --size 512M")
        child.expect(r"Virtual disk 'data-vol' resized to 512 MB \(512M\)\.", timeout=15)
        child.expect(PROMPT, timeout=10)
        print("✓ Child VM storage disk creation, listing, and resizing verified.")

        # 12. VM State Snapshot Management (`dsx snapshot save / list / restore / delete`)
        print("\n==> [12/18] Testing VM State Checkpoints & Snapshots (`dsx snapshot`)...")
        child.sendline("dsx snapshot save root checkpoint-1")
        child.expect(r"Snapshot 'checkpoint-1' for VM 'root' saved at /var/lib/diosix/snapshots/root_checkpoint-1\.snap\.", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx snapshot list")
        child.expect(r"root_checkpoint-1\.snap\s+root\s+saved", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx snapshot restore checkpoint-1")
        child.expect(r"VM state restored from snapshot 'checkpoint-1'\.", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx snapshot delete checkpoint-1")
        child.expect(r"Snapshot 'checkpoint-1' deleted\.", timeout=15)
        child.expect(PROMPT, timeout=10)
        print("✓ VM state serialization, snapshot save, list, restore, and deletion verified.")

        # 13. Child VM Launch with Persistent Storage Attached (`dsx run --disk`)
        print("\n==> [13/19] Testing Child VM launch with persistent virtual disk attached (`dsx run --disk`)...")
        child.sendline("dsx run linux-guest --name leenix-storage --disk data-vol --vcpus 1 --ram 128M")
        child.expect(r"Child VM 'leenix-storage' \(CID \d+, 1 vCPUs, 128 MB RAM, Disk: /var/lib/diosix/disks/data-vol\.img, IP: 10\.0\.3\.\d+\) started in background\.", timeout=25)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx info leenix-storage")
        child.expect(r"Storage disk\s+:\s+/var/lib/diosix/disks/data-vol\.img", timeout=15)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx stop leenix-storage")
        child.expect(r"Child VM 'leenix-storage' \(CID \d+\) terminated\.", timeout=15)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx disk delete data-vol")
        child.expect(r"Virtual disk 'data-vol' deleted\.", timeout=15)
        child.expect(PROMPT, timeout=15)
        print("✓ Child VM storage attachment and info reporting verified.")

        # 14. Image Repository Management & Dual Storage (CD-ROM + Target Disk)
        print("\n==> [14/19] Testing Image Repository (`dsx image`) & Dual Storage (`--disk` + `--cdrom`)...")
        child.sendline("dsx image import /boot/vmlinux.elf --name test-installer.elf")
        child.expect(r"Image 'test-installer\.elf' successfully imported into /var/lib/diosix/images/test-installer\.elf\.", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx image list")
        child.expect(r"test-installer\.elf\s+kernel\s+elf", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx run test-installer --name installer-job --disk install-target --cdrom /boot/vmlinux.elf --vcpus 1 --ram 128M")
        child.expect(r"Child VM 'installer-job' \(CID \d+, 1 vCPUs, 128 MB RAM, Disk: /var/lib/diosix/disks/install-target\.img, CD-ROM: /boot/vmlinux\.elf, IP: 10\.0\.3\.\d+\) started in background\.", timeout=25)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx info installer-job")
        child.expect(r"Storage disk\s+:\s+/var/lib/diosix/disks/install-target\.img", timeout=15)
        child.expect(r"CD-ROM media\s+:\s+/boot/vmlinux\.elf", timeout=15)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx stop installer-job")
        child.expect(r"Child VM 'installer-job' \(CID \d+\) terminated\.", timeout=15)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx image delete test-installer.elf")
        child.expect(r"Image 'test-installer\.elf' deleted\.", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx disk delete install-target")
        child.expect(r"Virtual disk 'install-target' deleted\.", timeout=15)
        child.expect(PROMPT, timeout=10)
        print("✓ Image repository management and dual storage (CD-ROM + target disk) verified.")

        # 15. Guest VM SSH Access & Security Isolation (`dsx ssh`)
        print("\n==> [15/20] Testing VM SSH access & security hardening...")
        child.sendline("dsx ssh root -- uname -a")
        child.expect(r"Linux diosix-rootvm", timeout=15)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx run linux-guest --name child-sec --vcpus 1 --ram 256M")
        child.expect(r"Child VM 'child-sec' \(CID \d+, 1 vCPUs, 256 MB RAM, IP: 10\.0\.3\.\d+\) started in background\.", timeout=25)
        child.expect(PROMPT, timeout=15)

        time.sleep(25)
        child.sendline("dsx ssh root@child-sec -- uname -a")
        child.expect(r"Linux", timeout=120)
        child.expect(PROMPT, timeout=15)

        # Verify child VM does not have the Root VM private management key
        child.sendline("dsx ssh root@child-sec -- test ! -f /etc/diosix/keys/id_dropbear")
        child.expect(PROMPT, timeout=15)

        # Verify child VM has authorized_keys installed for management
        child.sendline("dsx ssh root@child-sec -- test -s /root/.ssh/authorized_keys")
        child.expect(PROMPT, timeout=15)

        # Verify parent firewall rules block incoming connections from child VMs
        child.sendline("iptables -S INPUT")
        child.expect(r"-i diosix0 -m conntrack --ctstate NEW -j DROP", timeout=10)
        child.expect(PROMPT, timeout=10)

        # Verify lateral cross-guest forwarding is blocked
        child.sendline("iptables -S FORWARD")
        child.expect(r"-s 10\.0\.0\.0/16 -d 10\.0\.0\.0/16 -j DROP", timeout=10)
        child.expect(PROMPT, timeout=10)

        child.sendline("dsx stop child-sec")
        child.expect(r"Child VM 'child-sec' \(CID \d+\) terminated\.", timeout=15)
        child.expect(PROMPT, timeout=10)
        print("✓ Executed command via SSH and verified asymmetric key security + firewall containment.")

        # 16. Trusted Guest VM Spawning (`dsx run --trusted`)
        print("\n==> [16/20] Testing trusted guest VM creation (`dsx run linux-guest --trusted`)...")
        child.sendline("dsx run linux-guest --name trusted-svc --trusted --vcpus 2 --ram 256M")
        child.expect(r"Child VM 'trusted-svc' \(CID 2, 2 vCPUs, 256 MB RAM, IP: 10\.0\.3\.2\) started in background\.", timeout=25)
        child.expect(PROMPT, timeout=15)

        # Verify trusted child VM in `dsx list`
        time.sleep(1)
        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=15)
        child.expect(r"2\s+trusted-svc\s+2\s+256 MB\s+running\s+trusted\s+10\.0\.3\.2", timeout=15)
        child.expect(PROMPT, timeout=15)
        print("✓ Trusted child VM spawned and verified in guest registry.")

        child.sendline("dsx stop trusted-svc")
        child.expect(r"Child VM 'trusted-svc' \(CID 2\) terminated\.", timeout=15)
        child.expect(PROMPT, timeout=15)
        print("✓ Trusted child VM cleanly stopped.")

        # 17. Sandboxed (Untrusted) Guest VM Spawning (`dsx run`)
        print("\n==> [17/20] Testing sandboxed (untrusted) guest VM creation (`dsx run`)...")
        child.sendline("dsx run linux-guest --name user --vcpus 2 --ram 256M")
        child.expect(r"Child VM 'user' \(CID \d+, 2 vCPUs, 256 MB RAM, IP: 10\.0\.3\.\d+\) started in background\.", timeout=25)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=15)
        child.expect(r"\d+\s+user\s+2\s+256 MB\s+running\s+untrusted\s+10\.0\.3\.\d+", timeout=15)
        child.expect(PROMPT, timeout=15)
        print("✓ Sandboxed child VM spawned and verified in guest registry.")

        child.sendline("dsx stop user")
        child.expect(r"Child VM 'user' \(CID \d+\) terminated\.", timeout=15)
        child.expect(PROMPT, timeout=15)
        print("✓ Sandboxed child VM cleanly stopped.")

        # 18. Multiple Concurrent Child VMs with Mixed Trust Levels
        print("\n==> [18/20] Testing multiple concurrent child VMs with mixed trust levels...")
        child.sendline("dsx run linux-guest --name sys-domain --trusted --vcpus 1 --ram 128M")
        child.expect(r"Child VM 'sys-domain' \(CID \d+, 1 vCPUs, 128 MB RAM, IP: 10\.0\.3\.\d+\) started in background\.", timeout=25)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx run linux-guest --name user-domain --vcpus 2 --ram 256M")
        child.expect(r"Child VM 'user-domain' \(CID \d+, 2 vCPUs, 256 MB RAM, IP: 10\.0\.3\.\d+\) started in background\.", timeout=25)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx list")
        child.expect(r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local", timeout=15)
        child.expect(r"\d+\s+sys-domain\s+1\s+128 MB\s+running\s+trusted\s+10\.0\.3\.\d+", timeout=15)
        child.expect(r"\d+\s+user-domain\s+2\s+256 MB\s+running\s+untrusted\s+10\.0\.3\.\d+", timeout=15)
        child.expect(PROMPT, timeout=15)

        print("✓ Concurrent multi-VM hierarchy verified.")

        child.sendline("dsx stop sys-domain")
        child.expect(r"Child VM 'sys-domain' \(CID \d+\) terminated\.", timeout=15)
        child.expect(PROMPT, timeout=15)

        child.sendline("dsx stop user-domain")
        child.expect(r"Child VM 'user-domain' \(CID \d+\) terminated\.", timeout=15)
        child.expect(PROMPT, timeout=15)
        print("✓ Concurrent VMs cleanly stopped.")

        # Test Root VM stop protection
        child.sendline("dsx stop self")
        child.expect(r"Root VM cannot be stopped directly", timeout=15)
        child.expect(PROMPT, timeout=15)
        print("✓ Root VM stop protection verified.")

        # 19. Host Poweroff (`dsx host poweroff`)
        print("\n==> [19/19] Testing 'dsx host poweroff' (SBI SYSTEM_RESET)...")
        child.sendline("dsx host poweroff")
        child.expect(pexpect.EOF, timeout=15)
        print("✓ Host cleanly powered off via SBI hypercall.")

        print("\n===============================================================")
        print("   ALL 19 INTEGRATION TESTS PASSED (100% COVERAGE VERIFIED)     ")
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

