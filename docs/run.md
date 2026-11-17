# Getting started and running Diosix

When Diosix boots, the machine-mode (M-mode) hypervisor sets up hardware memory
and CPU isolation and starts a privileged Linux virtual machine (VM) called the
root VM. From the root VM, you can launch and manage isolated child VMs over
the serial console, SSH, or the built-in graphical desktop.

This guide walks through booting Diosix in QEMU, exploring the interactive tour
and desktop, and provisioning a target disk.

---

## System requirements

* Physical target hardware or an emulator must provide a 64-bit RISC-V
  processor with either the RISC-V hypervisor (H) extension or physical memory
  protection (PMP), plus at least 256 MiB of RAM (512 MiB or more is
  recommended when running child VMs).
* Emulated runs require QEMU 10.0 or later. On Debian or Ubuntu, install it
  with `sudo apt install -y qemu-system-misc`; on Fedora, run
  `sudo dnf install -y qemu-system-riscv`.

---

## Booting Diosix in QEMU

### Running a prebuilt release bundle

If you downloaded the standalone `diosix-26.1-riscv64.tar.xz` bundle from
GitHub Releases, unpack it and run `run-diosix.sh` directly without installing
any compiler or Buildroot packages:

```bash
tar -xf diosix-26.1-riscv64.tar.xz
cd diosix-26.1-riscv64
sha256sum -c SHA256SUMS

# Boot straight into the Wayland desktop RISC-V VM
./run-diosix.sh --desktop

# Boot straight into an interactive CLI RISC-V VM
./run-diosix.sh --cli

# Open the root VM graphical desktop with the welcome launcher
./run-diosix.sh --gui

# Or auto-select --gui on desktop hosts or --cli on headless terminals
./run-diosix.sh
```

### Building and booting from source

Once you have the [build dependencies](build.md#build-process-and-dependencies)
installed (or are inside one of the Docker containers in `dockerfiles/`), run
`./scripts/build.sh` to compile and boot Diosix:

```bash
# Boot the unified Alpine node VM in headless serial mode or with GUI
./scripts/build.sh run
./scripts/build.sh run-gui

# Optionally build and boot the standalone Wayland desktop or CLI demo VMs
./scripts/build.sh run-desktop
./scripts/build.sh run-cli
```

### How boot modes work

Diosix adjusts its startup behavior across three boot modes and two optional
guest-onboarding flags:

* Developer mode stages your build machine's SSH public keys into a temporary
  overlay so you can SSH into the root VM right away during QEMU runs.
* Live mode copies pre-loaded guest images into a 768 MiB RAM-backed filesystem,
  leaves the boot media unmounted so you can partition and install onto target
  storage, and opens the graphical welcome launcher automatically on first boot.
* Persistent mode mounts an ext4 data partition read-write to retain enrolled
  SSH keys, guest images, and virtual disks across reboots.
* Passing `diosix.demo=desktop` on the kernel command line skips the boot intro,
  launches the built-in Weston Wayland desktop VM in the background, and opens
  its interactive VirtIO-GPU 2D display pane automatically.
* Passing `diosix.demo=cli` spawns the built-in interactive CLI VM at boot,
  attaching to its console automatically in headless serial sessions or opening
  its built-in terminal pane in graphical sessions.

To try the 640 MiB hybrid GPT live image in QEMU:

```bash
# Headless serial live session
./scripts/build.sh run-live

# Graphical desktop live session (opens the welcome launcher)
./scripts/build.sh run-live-gui
```

Building the live image with `./scripts/build.sh live-image` also generates a
standalone launcher script so you can re-run the packaged image without
invoking the build system:

```bash
./zig-out/run-qemu.sh [--desktop|--cli|--gui] [--smp 4] [--mem 2G] \
    [--mode live|install|persistent|dev]
```

### Controlling QEMU from your terminal

In headless serial mode, press `Ctrl-a` then `x` to exit QEMU, or press
`Ctrl-a` then `c` to switch to the QEMU monitor (press `Ctrl-a` then `c` again
to return to the Diosix console).

---

## Exploring the interactive tour and desktop

After logging into the root VM, run the 5-step guided tour for an overview of
hardware isolation, SSH passkey management, and guest workflows:

```bash
# View all 5 steps of the guided tour
dsx tour

# Or view a single step (1..5)
dsx tour --step 1
```

### Using the graphical desktop

Booting with `./scripts/build.sh run-gui` or `./scripts/build.sh run-live-gui`
starts the Diosix desktop environment directly on the Linux direct rendering
manager (DRM) and kernel mode setting (KMS) display stack:

* Live sessions open the welcome dialog automatically with one-click
  **Try Desktop VM** and **Try CLI VM** buttons alongside **Start guided tour**.
* The top-left menu opens panes for creating VMs, viewing host and hypervisor
  telemetry, tuning display settings, and restarting or shutting down the host.
* Selecting any guest in the running VMs pane lets you adjust its CPU and RAM
  quotas on the fly, open its VirtIO-GPU 2D graphical guest display (for child
  VMs), or open a built-in VT100 terminal over SSH or the serial console.
* The built-in Wayland desktop guest uses software Pixman rasterization over a
  VirtIO-GPU 2D KMS scanout streamed zero-copy to the host display; 3D GPU
  passthrough and VirGL acceleration are planned beyond the 26.1 series.
* The dockable on-screen keyboard provides QWERTY and symbol layouts for
  pointer or touchscreen text entry across both host widgets and guest windows.

You can also inspect or drive the desktop from a terminal or script with
`dsx gui`:

```bash
# Check active pane, resolution, keyboard state, and tour progress
dsx gui state --json

# Launch the built-in Wayland desktop VM or CLI VM from the welcome workflow
dsx gui trigger welcome.try_desktop
dsx gui trigger welcome.try_cli

# Start the guided tour or toggle the on-screen keyboard
dsx gui trigger tour.start
dsx gui trigger osk.toggle

# Save a raw framebuffer capture when fbdev scanout is active
dsx gui screenshot /tmp/diosix-screen.raw
```

---

## Provisioning a target disk

From a live session, `dsx host install` partitions an NVMe, VirtIO, or SATA
disk with GPT boot, state, and data partitions and initializes the persistent
data volume. To flash a bootable standalone image onto raw media for physical
boards, see [Booting on physical RISC-V boards][phys-boards].

[phys-boards]: build.md#booting-on-physical-risc-v-boards

1. Preview the planned partition layout without modifying the disk:

   ```bash
   dsx host install --mode basic --disk /dev/vda --dry-run
   ```

2. Apply the partition layout and data-volume setup interactively or from an
   installation manifest:

   ```bash
   dsx host install --mode basic --disk /dev/vda --hostname my-diosix-host
   dsx host install --mode expert --config /etc/diosix/install.toml --json
   ```

---

## Next steps

* [Deploying and provisioning guest VMs](guests.md) covers launching quick
  sandboxes, booting installer ISOs, seeding disk images, booting custom
  kernels, and managing quotas.
* [Security, networking, and governance](security.md) covers guest network
  modes, chaining VMs through a firewall VM, enrolling SSH passkeys, and
  sealing a charter.
* [CLI and configuration reference](cli.md) documents every command, flag, and
  runtime configuration file.
