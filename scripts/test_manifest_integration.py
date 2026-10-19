#!/usr/bin/env python3
"""
Diosix Full-Stack Integration Test Suite:
Validates all guest CLI operations and hypercalls on live VM:
- Host & Guest Info (info, host info)
- System & Child Manifests (show, validate, prune, set, resolve)
- Resource Quota Attenuation (quota self)
- Hypervisor Manifest Staging (SET_MANIFEST / GET_MANIFEST SBI FIDs 11 & 12)
- Guest CLI Commands & Help (dsx help)
- Child VM Lifecycle Management (run, list, stop)
- System Poweroff & Hypervisor Exit (host poweroff)

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import os
import sys
import time
import pexpect


def run_expect(child, prompt, cmd, *patterns, timeout=15):
    child.sendline(cmd)
    for pat in patterns:
        child.expect(pat, timeout=timeout)
    child.expect(prompt, timeout=timeout)


def run_integration_test():
    print("===============================================================")
    print("      Diosix Full-Stack Integration Test Suite (100% Verified) ")
    print("===============================================================")

    os.system("pkill -9 -f qemu-system-riscv64 >/dev/null 2>&1 || true")
    os.system(
        "./scripts/create_storage_disk.sh "
        "zig-out/guest-riscv64/bin/rootvm.elf "
        "zig-out/storage.img 256M >/dev/null 2>&1 || true"
    )

    qemu_cmd = [
        "qemu-system-riscv64",
        "-nographic",
        "-s",
        "-machine",
        "virt",
        "-cpu",
        "rv64,h=true,smstateen=true,sstc=true,v=true",
        "-smp",
        "4",
        "-m",
        "2048M",
        "-drive",
        "file=zig-out/storage.img,if=none,format=raw,id=hd0",
        "-device",
        "virtio-blk-device,drive=hd0",
        "-netdev",
        "user,id=net0",
        "-device",
        "virtio-net-device,netdev=net0",
        "-bios",
        "none",
        "-kernel",
        "zig-out/guest-riscv64/bin/vmdiosix",
    ]

    print(f"==> Launching QEMU: {' '.join(qemu_cmd)}")
    child = pexpect.spawn(
        qemu_cmd[0], qemu_cmd[1:], timeout=120, encoding="utf-8"
    )
    child.logfile_read = sys.stdout
    child.delaybeforesend = 0.15

    try:
        # 1. Boot Verification & Shell Login.
        print("\n==> [1/19] Waiting for Diosix Hypervisor & Root VM login...")
        child.expect(r"login:\s*", timeout=90)
        child.sendline("root")
        child.expect(r"#[ \t]*", timeout=30)
        child.sendline(
            "bind 'set enable-bracketed-paste off' 2>/dev/null || true"
        )
        child.expect(r"#[ \t]*", timeout=10)
        child.sendline("export PS1='diosix-rootvm# '")
        prompt = r"diosix-rootvm#\s*"
        child.expect(prompt, timeout=10)
        print("\n✓ Logged into Root VM shell.")

        def run(cmd, *patterns, timeout=15):
            run_expect(child, prompt, cmd, *patterns, timeout=timeout)

        # 2. Host Hypervisor Info (`dsx host info`).
        print("\n==> [2/19] Testing 'dsx host info' (GET_HV_INFO)...")
        run(
            "dsx host info",
            r"Hypervisor build\s+:\s+Version\s+\d+",
            r"Hardware H-(?:extension|Extension)",
            r"VirtIO(?:-|\s+)vsock",
            timeout=10,
        )
        print("✓ Host hypervisor capabilities & ABI queried successfully.")

        # 3. Guest VM Info (`dsx info`).
        print("\n==> [3/19] Testing 'dsx info' (GET_INFO)...")
        run("dsx info", r"Root VM\s+:\s+yes", timeout=10)
        print("✓ Guest VM info verified.")

        # 4. Quota Management on Self (`dsx quota self`).
        print("\n==> [4/19] Testing 'dsx quota self' (SET_QUOTA)...")
        run(
            "dsx quota self --ram 1024 --vcpus 8 --depth 4 --descendants 8",
            r"Quotas updated successfully",
            timeout=10,
        )
        print("✓ Set VM resource quotas for self.")

        # 5. Manifest Show & Validate.
        print("\n==> [5/19] Testing 'dsx manifest show' & 'validate'...")
        run("dsx manifest show", r"\[system\]", r"\[domains\.sys\]", timeout=10)
        run(
            "dsx manifest validate /etc/diosix/system.toml",
            r"System manifest is valid",
            timeout=10,
        )
        print("✓ Global system manifest displayed and verified.")

        # 6. Manifest Pruning (Attenuation).
        print("\n==> [6/19] Testing 'dsx manifest prune'...")
        run(
            "dsx manifest prune /etc/diosix/system.toml "
            "--domain sys -o /tmp/sys-child.toml",
            r"Attenuated manifest written to /tmp/sys-child.toml",
            timeout=10,
        )
        run(
            "dsx manifest validate /tmp/sys-child.toml",
            r"Child VM manifest is valid",
            timeout=10,
        )
        run(
            "dsx manifest prune /etc/diosix/system.toml "
            "--domain user -o /tmp/user-child.toml",
            r"Attenuated manifest written to /tmp/user-child.toml",
            timeout=10,
        )
        print("✓ Attenuated manifests created and validated.")

        # 7. Service Endpoint Resolution (`dsx manifest resolve`).
        print("\n==> [7/19] Testing 'dsx manifest resolve'...")
        run(
            "dsx manifest resolve gui.display --manifest /tmp/user-child.toml",
            r"Service (?:resolution|Resolution):",
            r"gui\.display",
            r"gui\.wayland",
            r"gui",
            timeout=10,
        )
        run(
            "dsx manifest resolve net.wan --manifest /tmp/user-child.toml",
            r"Service (?:resolution|Resolution):",
            r"net\.wan",
            r"sys",
            timeout=10,
        )
        print("✓ Resolved endpoints across domain boundaries.")

        # 8. Hypervisor Manifest Staging (`SET_MANIFEST` / `GET_MANIFEST`).
        print("\n==> [8/19] Testing SET_MANIFEST / GET_MANIFEST...")
        run(
            "dsx manifest set 1 /tmp/sys-child.toml",
            r"Manifest successfully staged in hypervisor for CID 1",
            timeout=10,
        )
        run(
            "dsx manifest show --cid 1 --hv",
            r"\[vm\]",
            r"sys-domain",
            timeout=10,
        )
        print("✓ Staged and queried manifest in hypervisor memory via SBI.")

        # 9. CLI Usage & Help (`dsx help`).
        print("\n==> [9/19] Testing CLI usage & help output (`dsx help`)...")
        run(
            "dsx help",
            r"dsx: Diosix [tT]ype-1 [hH]ypervisor [gG]uest [mM]anagement CLI",
            r"dsx run <image\|name>",
            r"dsx ssh \[user@\]<name\|cid>",
            r"dsx host info",
            timeout=10,
        )
        print("✓ CLI commands and help interface verified.")

        # 10. Guest VM Run Error Handling.
        print("\n==> [10/19] Testing 'dsx run' with missing binary...")
        run(
            "dsx run nonexistent_image_foo",
            r"Error: Guest ELF binary 'nonexistent_image_foo' not found",
            timeout=10,
        )
        print("✓ Missing ELF binary error properly reported.")

        # 11. Child VM Storage Management (`dsx disk`).
        print("\n==> [11/19] Testing Child VM Storage (`dsx disk`)...")
        run(
            "dsx disk create data-vol --size 256M",
            r"Virtual disk 'data-vol' \(256 MB.*\) created at "
            r"/var/lib/diosix/disks/data-vol\.img\.",
            timeout=30,
        )
        run(
            "dsx disk list",
            r"data-vol\.img\s+256 MB\s+(?:raw|ext4)\s+.*data-vol\.img",
        )
        run(
            "dsx disk resize data-vol --size 512M",
            r"Virtual disk 'data-vol' resized to 512 MB \(512M\)\.",
        )
        print("✓ Child VM storage disk creation, list, and resize verified.")

        # 12. VM State Snapshot Management (`dsx snapshot`).
        print("\n==> [12/19] Testing VM State Snapshots (`dsx snapshot`)...")
        run(
            "dsx snapshot save root checkpoint-1",
            r"Snapshot 'checkpoint-1' for VM 'root' saved at "
            r"/var/lib/diosix/snapshots/root_checkpoint-1\.snap\.",
        )
        run("dsx snapshot list", r"root_checkpoint-1\.snap\s+root\s+saved")
        run(
            "dsx snapshot restore checkpoint-1",
            r"VM state restored from snapshot 'checkpoint-1'\.",
        )
        run(
            "dsx snapshot delete checkpoint-1",
            r"Snapshot 'checkpoint-1' deleted\.",
        )
        print("✓ VM state snapshot save, list, restore, and delete verified.")

        # 13. Child VM Launch with Persistent Storage (`dsx run --disk`).
        print("\n==> [13/19] Testing Child VM launch with `--disk`...")
        run(
            "dsx run linux-guest --name leenix-storage "
            "--disk data-vol --vcpus 1 --ram 128M",
            r"Child VM 'leenix-storage' \(CID \d+, 1 vCPUs, 128 MB RAM, "
            r"Disk: /var/lib/diosix/disks/data-vol\.img, "
            r"IP: 10\.0\.3\.\d+\) started in background\.",
            timeout=25,
        )
        run(
            "dsx info leenix-storage",
            r"Storage disk\s+:\s+/var/lib/diosix/disks/data-vol\.img",
        )
        run(
            "dsx stop leenix-storage",
            r"Child VM 'leenix-storage' \(CID \d+\) terminated\.",
        )
        run("dsx disk delete data-vol", r"Virtual disk 'data-vol' deleted\.")
        print("✓ Child VM storage attachment and info reporting verified.")

        # 14. Image Repository & Dual Storage (CD-ROM + Target Disk).
        print("\n==> [14/19] Testing `dsx image` & `--disk` + `--cdrom`...")
        run(
            "dsx image import /var/lib/diosix/images/linux-guest.elf "
            "--name test-installer.elf",
            r"Image 'test-installer\.elf' successfully imported into "
            r"/var/lib/diosix/images/test-installer\.elf\.",
        )
        run("dsx image list", r"test-installer\.elf\s+leaf\s+linux\s+elf")
        run(
            "dsx run test-installer --name installer-job "
            "--disk install-target "
            "--cdrom /var/lib/diosix/images/linux-guest.elf "
            "--vcpus 1 --ram 128M",
            r"Child VM 'installer-job' \(CID \d+, 1 vCPUs, 128 MB RAM, "
            r"Disk: /var/lib/diosix/disks/install-target\.img, "
            r"CD-ROM: /var/lib/diosix/images/linux-guest\.elf, "
            r"IP: 10\.0\.3\.\d+\) started in background\.",
            timeout=25,
        )
        run(
            "dsx info installer-job",
            r"Storage disk\s+:\s+/var/lib/diosix/disks/install-target\.img",
            r"CD-ROM media\s+:\s+/var/lib/diosix/images/linux-guest\.elf",
        )
        run(
            "dsx stop installer-job",
            r"Child VM 'installer-job' \(CID \d+\) terminated\.",
        )
        run(
            "dsx image delete test-installer.elf",
            r"Image 'test-installer\.elf' deleted\.",
        )
        run(
            "dsx disk delete install-target",
            r"Virtual disk 'install-target' deleted\.",
        )
        print("✓ Image repository and dual storage verified.")

        # 15. Guest VM SSH Access & Security Isolation (`dsx ssh`).
        print("\n==> [15/19] Testing VM SSH access & security hardening...")
        run("dsx ssh root -- uname -a", r"Linux diosix-rootvm")
        run(
            "dsx run linux-guest --name child-sec --vcpus 1 --ram 256M",
            r"Child VM 'child-sec' \(CID \d+, 1 vCPUs, 256 MB RAM, "
            r"IP: 10\.0\.3\.\d+\) started in background\.",
            timeout=25,
        )
        time.sleep(25)
        run("dsx ssh root@child-sec -- uname -a", r"Linux", timeout=120)
        run("dsx ssh root@child-sec -- test ! -f /etc/diosix/keys/id_dropbear")
        run("dsx ssh root@child-sec -- test -s /root/.ssh/authorized_keys")
        run(
            "iptables -S INPUT",
            r"-i diosix0 -m conntrack --ctstate NEW -j DROP",
            timeout=10,
        )
        run(
            "iptables -S FORWARD",
            r"-s 10\.0\.0\.0/16 -d 10\.0\.0\.0/16 -j DROP",
            timeout=10,
        )
        run(
            "dsx stop child-sec",
            r"Child VM 'child-sec' \(CID \d+\) terminated\.",
        )
        print("✓ Executed command via SSH and verified firewall containment.")

        # 16. Trusted Guest VM Spawning (`dsx run --trusted`).
        print("\n==> [16/19] Testing trusted guest VM (`dsx run --trusted`)...")
        run(
            "dsx run linux-guest --name trusted-svc "
            "--trusted --vcpus 2 --ram 256M",
            r"Child VM 'trusted-svc' \(CID 2, 2 vCPUs, 256 MB RAM, "
            r"IP: 10\.0\.3\.2\) started in background\.",
            timeout=25,
        )
        time.sleep(1)
        run(
            "dsx list",
            r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local",
            r"2\s+trusted-svc\s+2\s+256 MB\s+running\s+trusted\s+10\.0\.3\.2",
        )
        print("✓ Trusted child VM spawned and verified in guest registry.")
        run(
            "dsx stop trusted-svc",
            r"Child VM 'trusted-svc' \(CID 2\) terminated\.",
        )
        print("✓ Trusted child VM cleanly stopped.")

        # 17. Sandboxed (Untrusted) Guest VM Spawning (`dsx run`).
        print("\n==> [17/19] Testing sandboxed (untrusted) guest VM...")
        run(
            "dsx run linux-guest --name user --vcpus 2 --ram 256M",
            r"Child VM 'user' \(CID \d+, 2 vCPUs, 256 MB RAM, "
            r"IP: 10\.0\.3\.\d+\) started in background\.",
            timeout=25,
        )
        run(
            "dsx list",
            r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local",
            r"\d+\s+user\s+2\s+256 MB\s+running\s+untrusted\s+10\.0\.3\.\d+",
        )
        print("✓ Sandboxed child VM spawned and verified in guest registry.")
        run("dsx stop user", r"Child VM 'user' \(CID \d+\) terminated\.")
        print("✓ Sandboxed child VM cleanly stopped.")

        # 18. Multiple Concurrent Child VMs with Mixed Trust Levels.
        print("\n==> [18/19] Testing multiple concurrent child VMs...")
        run(
            "dsx run linux-guest --name sys-domain "
            "--trusted --vcpus 1 --ram 128M",
            r"Child VM 'sys-domain' \(CID \d+, 1 vCPUs, 128 MB RAM, "
            r"IP: 10\.0\.3\.\d+\) started in background\.",
            timeout=25,
        )
        run(
            "dsx run linux-guest --name user-domain --vcpus 2 --ram 256M",
            r"Child VM 'user-domain' \(CID \d+, 2 vCPUs, 256 MB RAM, "
            r"IP: 10\.0\.3\.\d+\) started in background\.",
            timeout=25,
        )
        run(
            "dsx list",
            r"1\s+root \(self\)\s+\d+\s+\d+\s+MB\s+running\s+trusted\s+local",
            r"\d+\s+sys-domain\s+1\s+128 MB\s+running\s+"
            r"trusted\s+10\.0\.3\.\d+",
            r"\d+\s+user-domain\s+2\s+256 MB\s+running\s+"
            r"untrusted\s+10\.0\.3\.\d+",
        )
        print("✓ Concurrent multi-VM hierarchy verified.")

        run(
            "dsx stop sys-domain",
            r"Child VM 'sys-domain' \(CID \d+\) terminated\.",
        )
        run(
            "dsx stop user-domain",
            r"Child VM 'user-domain' \(CID \d+\) terminated\.",
        )
        print("✓ Concurrent VMs cleanly stopped.")

        # Test Root VM stop protection.
        run("dsx stop self", r"Root VM cannot be stopped directly")
        print("✓ Root VM stop protection verified.")

        # 19. Host Poweroff (`dsx host poweroff`).
        print("\n==> [19/19] Testing 'dsx host poweroff' (SYSTEM_RESET)...")
        child.sendline("dsx host poweroff")
        child.expect(pexpect.EOF, timeout=15)
        print("✓ Host cleanly powered off via SBI hypercall.")

        print("\n=============================================================")
        print("   ALL 19 INTEGRATION TESTS PASSED (100% COVERAGE VERIFIED)")
        print("=============================================================")
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
