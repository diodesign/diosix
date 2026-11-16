# Deploying and provisioning guest VMs

Diosix runs single-purpose Linux sandboxes, installer ISOs, seeded disk images,
and custom 64-bit or 32-bit RISC-V kernels inside hardware-isolated virtual
machines (VMs).

This guide explains which workflow fits each task, why it works that way, and
how to run it with `dsx`.

---

## Choosing a guest workflow

| Goal | Workflow | Command |
| :--- | :--- | :--- |
| Spin up an interactive command-line Linux sandbox | Built-in CLI guest image | `dsx run linux-cli --name app --vcpus 2 --ram 256M` |
| Launch an offline Wayland graphical desktop guest | Built-in desktop guest image | `dsx run linux-desktop --name desk --vcpus 2 --ram 512M` |
| Run a minimal supervisor, steward, or service domain | Built-in base Linux image | `dsx run base-linux --name svc --vcpus 2 --ram 256M` |
| Boot a 64-bit RISC-V installer or live ISO in RAM | Bootloader shim ISO boot | `dsx run /var/lib/diosix/iso/alpine-standard-3.24.3-riscv64.iso --ram 512M` |
| Seed and boot an ext4 or FAT32 disk image (up to 2 GiB) | Disk seeding and shim boot | `dsx disk seed my-disk --ip 10.0.3.2 && dsx run my-disk.img --ram 1024M` |
| Boot a custom kernel and initial RAM disk | Direct kernel boot | `dsx run Image --initrd initrd.cpio --cmdline "console=hvc0"` |

---

## Built-in RISC-V guest images

### Why use them
Every Diosix system stages three purpose-built 64-bit RISC-V Linux ELF images
under `/var/lib/diosix/images/`. Each image embeds its own root filesystem and
hypervisor driver so it boots in seconds without external disk setup or network
downloads:

| Image file | `dsx run` aliases | Default role |
| :--- | :--- | :--- |
| `linux-cli.elf` | `linux-cli`, `cli` | Interactive command-line sandbox with shell, networking, and diagnostic tools (256 MiB RAM recommended). |
| `linux-desktop.elf` | `linux-desktop`, `desktop` | Offline Weston Wayland graphical desktop and terminal rendered over VirtIO-GPU 2D kernel mode setting (KMS) scanout with VirtIO-Input keyboard, mouse, and tablet devices (512 MiB RAM recommended). |
| `diosix-base-linux.elf` | `base-linux`, `linux-guest`, `steward`, `default` | Compact supervisor-grade Linux image used for governance steward VMs, warm standby root failover, and declarative domain manifests. |

> [!NOTE]
> In the 26.1 series, `linux-desktop.elf` renders its Wayland desktop with
> software Pixman rasterization over a VirtIO-GPU 2D KMS scanout streamed
> zero-copy into the parent VM desktop viewport at 1:1 native pixel resolution,
> including `weston-terminal`, Wayland test clients (`weston-simple-shm`,
> `weston-simple-damage`), `tmux`, `htop`, `vi`, `ssh`, `ip`, and `dsx`.
> Hardware 3D GPU passthrough and VirGL acceleration are planned for future
> releases.

### How to run them

```bash
# Launch an interactive CLI sandbox with 2 vCPUs and 256 MiB RAM
dsx run linux-cli --name work --vcpus 2 --ram 256M

# Or launch the Weston Wayland graphical desktop VM
dsx run linux-desktop --name desktop-demo --vcpus 2 --ram 512M

# View running VMs and their private IP addresses
dsx list

# Open an interactive root shell over key-authenticated SSH
dsx ssh work

# Or run a single command inside the guest
dsx ssh work -- uname -a
```

Passing `--disk 128M` (with `--ram 512M` or larger so the staged disk fits
inside the upper half of child RAM) formats an ext4 volume under
`/var/lib/diosix/disks/`, seeds your management SSH public key and default
guest kernel onto it, and exposes an in-RAM copy to the guest as `/dev/vda`.

---

## Booting an ISO9660 image

### Why use it
When booting a 64-bit RISC-V live or installer ISO (up to 2 GiB) that contains
a gzip-compressed, ELF, or flat Linux kernel and an initial RAM disk, Diosix
stages the ISO near the top of child RAM, marks it reserved in the child device
tree, and boots it through a freestanding supervisor-mode (S-mode) bootloader
shim. Inside the guest, the ISO appears as a read-only VirtIO block device
alongside VirtIO networking, a virtual serial port, and VirtIO-GPU and
VirtIO-Input desktop devices, allowing you to view graphical installers or
Wayland desktops from the parent VM GUI's **Open guest display** button.

> [!NOTE]
> Each child VM stages a single ISO or disk payload (up to 2 GiB, bounded by
> the RAM assigned to the child VM) into volatile guest RAM. Writes to a
> virtual disk persist in RAM for the lifetime of that VM run, and the
> bootloader shim boots gzip-compressed, ELF, and flat RISC-V kernels or
> self-contained EFI stubs (full UEFI boot-services loaders are not yet
> supported).

### How to run it

1. View configured catalog entries and their pinned SHA-256 digests:

   ```bash
   dsx image catalog
   ```

2. Pull a catalog ISO (or import a local 64-bit RISC-V ISO) and launch it with
   enough child RAM to hold both the guest OS and the staged ISO:

   ```bash
   dsx image pull alpine-riscv64
   dsx run /var/lib/diosix/iso/alpine-standard-3.24.3-riscv64.iso \
       --name alpine-live --vcpus 2 --ram 512M --net wan
   ```

3. Attach to the guest's serial console (press `Ctrl+]` to detach without
   stopping the VM):

   ```bash
   dsx console alpine-live
   ```

### Launching external workloads automatically

From your build machine, you can stage the verified Alpine Linux RISC-V ISO,
boot Diosix in a graphical QEMU window, and provision both a headless web
server guest and a graphical Wayland desktop guest without manual copy-pasting:

```bash
python3 scripts/demo_external_guests.py
```

Once both guests are running, click **Guests**, select **alpine-desktop**, and
click **Open guest display** inside the QEMU window to interact with the live
Wayland desktop, or pass `--headless-verify` to run the end-to-end check
non-interactively.

---

## Seeding and booting disk images

### Why use it
Pre-built ext4 root filesystems (up to 2 GiB) need SSH public keys, a
hostname, and network settings before first boot. Seeding an unattached disk
image writes root SSH authorized keys, hostname and network configuration
files, and NoCloud cloud-init seed files automatically. Only the parent VM's
public key is written to the disk—private keys never leave the parent.

### How to run it

1. Create or copy an ext4 disk image of up to 2 GiB:

   ```bash
   dsx disk create app-disk --size 128M
   ```

2. Seed the disk with a hostname and static IP matching its target context ID
   (CID):

   ```bash
   dsx disk seed app-disk --hostname web-01 --ip 10.0.3.2
   ```

3. Boot a kernel with the seeded disk staged in RAM (`--ram 512M` leaves room
   for both guest memory and the 128 MiB in-RAM disk):

   ```bash
   dsx run linux-guest --name web-01 --disk app-disk --vcpus 2 --ram 512M
   dsx ssh web-01
   ```

---

## Direct kernel boot

### Why use it
When testing a custom 64-bit or single-core 32-bit RISC-V Linux or BSD kernel,
you can boot the kernel binary directly without wrapping it in an ISO or disk
image. Diosix loads 64-bit and 32-bit ELF kernels, flat RISC-V Linux or BSD
kernel images, and self-contained portable executable (PE) EFI stubs on 64-bit
RISC-V.

### How to run it

Pass `--initrd` to stage an external initial RAM disk and `--cmdline` to set
kernel boot arguments (`console=hvc0` enables interactive supervisor binary
interface (SBI) console input and output; `console=tty0` routes console output
to the VirtIO-GPU display):

```bash
dsx run /var/lib/diosix/images/Image \
    --initrd /var/lib/diosix/images/initramfs.cpio.gz \
    --cmdline "root=/dev/vda rw console=tty0 console=hvc0" \
    --disk app-disk \
    --vcpus 2 \
    --ram 512M \
    --name custom-kernel
```

Diosix maps the kernel and initial RAM disk into child guest physical address
(GPA) memory and records the ramdisk bounds and command line inside the child's
device tree blob (DTB).

To inspect kernel output from early boot:

```bash
# Print buffered kernel boot messages and exit
dsx console custom-kernel --dump

# Or open an interactive console (press Ctrl+] to detach)
dsx console custom-kernel
```

---

## Managing resource quotas

### Why logical VM size and physical quotas are separate
The RAM size and virtual CPU count assigned when creating a VM set the logical
hardware advertised in the guest's DTB. Separately, the machine-mode (M-mode)
hypervisor enforces a physical subtree quota:

* On hosts with the RISC-V hypervisor (H) extension, physical pages are
  allocated on demand as the guest touches memory, so you can raise or lower a
  running child VM's physical RAM pool or CPU time share on the fly.
* If a child VM launches grandchild VMs, their memory and CPU consumption draw
  from that child's quota pool, preventing a busy subtree from starving sibling
  VMs or the parent VM.

### How to use it

```bash
# Check your current RAM pool, pCPU share, and delegated child quotas
dsx quota

# Give child VM 2 up to 40% of parent pCPU time and a 512 MiB RAM pool
dsx quota 2 --pcpu 40 --ram 512

# Keep 25% of physical CPU time reserved for the calling VM (self)
dsx quota self --retained-pcpu 25
```

---

## Saving and restoring RAM checkpoints

### Why use it
For quick experiments on a running child VM, Diosix can save and restore up to
64 MiB of a child VM's live physical RAM and quota metadata on persistent
storage (virtual CPU registers and virtual device queues are not yet included
in checkpoints).

### How to use it

```bash
# Save an in-memory RAM checkpoint of running VM 'work'
dsx snapshot save work before-test

# List saved snapshots
dsx snapshot list

# Write saved RAM pages back into running VM 'work'
dsx snapshot restore work before-test

# Remove a snapshot you no longer need
dsx snapshot delete work before-test
```
