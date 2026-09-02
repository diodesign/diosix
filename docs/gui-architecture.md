# Diosix GUI & System Configuration Architecture

## 1. Overview & Security Model

Diosix isolates the **Presentation Layer** (`sys.gui`) from the **Host Administration Layer** (`sys.config`):

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                   PHYSICAL HARDWARE                                    │
│       Physical Display (DRM / KMS)                  Physical Keyboard & Mouse (evdev)  │
└───────────────────────────────┬─────────────────────────────────┬──────────────────────┘
                                │                                 │
┌───────────────────────────────▼─────────────────────────────────▼──────────────────────┐
│                    GUI DOMAIN (`sys.gui` / CID 2 — Hardware Trust)                     │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                     Homegrown Window Manager / Compositor (diosix-wm)            │  │
│  │                                                                                  │  │
│  │  • Drives DRM/KMS scanout buffer & captures evdev/libinput seat input            │  │
│  │  • Fullscreen Desktop Shell: Top status bar, workspace manager, window frames    │  │
│  │  • Tamper-Proof Trusted Window Borders: Color-coded by source Domain / CID       │  │
│  │  • Wayland Server: Exposes wl_compositor, xdg_shell, wl_shm, wl_seat             │  │
│  └───────────────────▲──────────────────────────────▲───────────────────────────▲───┘  │
│                      │                              │                           │      │
└──────────────────────┼──────────────────────────────┼───────────────────────────┼──────┘
                       │ (Wayland over VSOCK / IP)    │                           │
    ┌──────────────────┴───────────────┐ ┌────────────┴──────────────┐ ┌──────────┴───────────────┐
    │  CONFIG DOMAIN (`sys.config`)    │ │  APP DOMAIN (`user.web`)  │ │ WORK DOMAIN (`user.work`) │
    │                                  │ │                           │ │                           │
    │  • Native GUI Config App         │ │  • Web Browser (Firefox)  │ │ • Terminal & Text Editor  │
    │  • Talks to Root VM / Hypervisor │ │  • Wayland Client         │ │ • Wayland Client          │
    │  • Manages VMs, Disks, Manifests │ │  • Untrusted sandbox      │ │ • Sandboxed environment   │
    └──────────────────────────────────┘ └───────────────────────────┘ └───────────────────────────┘
```

### Key Security Properties
1. **Decoupled Privileges**: `sys.gui` owns display hardware and mouse/keyboard inputs, but has **zero administrative power** to control other VMs or modify storage.
2. **Untrusted Presentation**: `sys.config` runs the native GUI configuration tool (`diosix-config`) but has **no direct access to display or input hardware**. It renders as a standard client window to `sys.gui`.
3. **Visual Provenance (Trusted Window Frames)**: `diosix-wm` draws tamper-proof window frames with color-coded security badges:
   - 🟢 **Green Border**: `[sys.config]` (Trusted Admin Domain)
   - 🔵 **Blue Border**: `[user.work]` (Work Domain)
   - 🔴 **Red Border**: `[user.web]` (Untrusted Sandboxed Domain)
   - 🟣 **Purple Border**: `[sys.net]` (System Domain Service)

---

## 2. Window Manager Component (`diosix-wm`)

Located in [`tools/diosix-wm/`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm):
- **[`src/framebuffer.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/framebuffer.zig)**: Software double-buffered scanout rasterizer for `/dev/fb0` and DRM dumb buffers.
- **[`src/decorator.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/decorator.zig)**: Enforces domain trust borders, titlebars, window controls, and client area clipping.
- **[`src/seat.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/seat.zig)**: Mouse cursor sprite rendering, titlebar dragging, hit-testing, and focus management.
- **[`src/panel.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/panel.zig)**: Top desktop panel displaying active domain focus badge and system status.
- **[`src/wayland.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/wayland.zig)**: Lightweight Wayland server handling client surface commitments over AF_UNIX / VSOCK.

---

## 3. Configuration GUI Component (`diosix-config`)

Located in [`tools/diosix-config/`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-config):
- **[`src/ui.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-config/src/ui.zig)**: Widget library providing VM cards, navigation sidebars, memory/vCPU sliders, and action buttons.
- **[`src/main.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-config/src/main.zig)**: Application lifecycle, tab controller (Dashboard, Virtual Machines, Storage Disks, Network Matrix), and hypervisor API bridge.

---

## 4. System Manifest Specification (`system.toml`)

```toml
[system]
version = "1.0"
domain = "diosix.local"

# 1. Dedicated Display & Seat Compositor Domain
[domains.gui]
name = "gui-domain"
image = "/var/lib/diosix/images/gui-guest.elf"
vcpus = 2
ram = "512 MB"
ip = "10.0.3.4"
grant_devices = ["gpu", "input"]
can_provide = ["gui.*", "display.*", "seat.*"]
can_require = ["net.*", "fs.*"]

provides = [
  { service = "gui.wayland", channel = "vsock", type = "display" },
  { service = "gui.seat", channel = "shmem", type = "input" }
]

# 2. Dedicated Graphical System Configuration Domain
[domains.config]
name = "config-domain"
image = "/var/lib/diosix/images/config-guest.elf"
vcpus = 2
ram = "512 MB"
ip = "10.0.3.5"
can_provide = ["config.*", "admin.*"]
can_require = ["gui.*", "host.manage"]

routes = [
  { require = "gui.display", resolve_to = "gui.gui.wayland" },
  { require = "host.manage", resolve_to = "root.ctl" }
]
```
