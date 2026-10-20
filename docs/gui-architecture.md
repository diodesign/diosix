# Diosix GUI and system configuration architecture

## 1. Overview and security model

Diosix isolates the **presentation layer** (`sys.gui`, Context ID (CID) `2`)
from the **host administration layer** (`sys.config`) while providing a
zero-dependency Direct Rendering Manager (DRM) and Kernel Mode Setting (KMS)
desktop environment (`diosix-gui`). Domains communicate over Virtual Socket
(VSOCK) and shared-memory Inter-Process Communication (IPC) channels, rendering
Remote Framebuffer (RFB) and Wayland client surfaces inside Windows, Icons,
Menus, and Pointer (WIMP) frames with a dockable On-Screen Keyboard (OSK), a
Virtual Machine (VM) management dashboard, and isolated Wide Area Network (WAN)
rules:

```text
+----------------------------------------------------------------------------+
|                             PHYSICAL HARDWARE                              |
|     Physical Display (DRM / KMS)            Keyboard, Mouse & Touch (evdev)|
+---------------------------------+---------------------------+--------------+
                                  |                           |
+---------------------------------v---------------------------v--------------+
|               GUI DOMAIN (`sys.gui` / CID 2 - Hardware Trust)              |
|                                                                            |
|  +----------------------------------------------------------------------+  |
|  |                 Monolithic Desktop Compositor (diosix-gui)           |  |
|  |                                                                      |  |
|  |  * Drives DRM/KMS scanout buffer & captures evdev/touch seat input   |  |
|  |  * Optical glass panes, dynamic sky backdrop, and WIMP window frames |  |
|  |  * Dockable on-screen virtual keyboard (OSK) & 5-step Guided Tour    |  |
|  |  * Headless semantic JSON control plane (/run/diosix/gui_state.json) |  |
|  +------------------^----------------------------^--------------------^-+  |
+---------------------|----------------------------|--------------------|----+
                      | (Wayland / VSOCK / IPC)    |                    |
   +------------------+-------------+ +------------+----------+ +-------+----+
   | CONFIG DOMAIN (`sys.config`)   | | APP DOMAIN (`user`)   | | VAULT VM   |
   | * Native GUI Config App        | | * Wayland/RFB Client  | | * Isolated |
   | * Manages VMs, Disks, Charters | | * Untrusted sandbox   | | * No WAN   |
   +--------------------------------+ +-----------------------+ +------------+
```

### Key security properties

1. **Decoupled privileges**: `sys.gui` owns display hardware and pointer,
   keyboard, and touchscreen inputs, while delegating VM lifecycle and
   storage management to the hypervisor control plane.
2. **Untrusted presentation**: `sys.config` runs the native GUI configuration
   tool (`diosix-config`) without direct access to display or input hardware.
3. **Visual provenance (trusted window frames)**: `diosix-gui` renders
   tamper-proof window frames with domain-specific accents:
   - **Green border**: `[sys.config]` (trusted admin domain)
   - **Blue border**: `[user.work]` (work domain)
   - **Red border**: `[user.web]` (untrusted sandboxed domain)
   - **Purple border**: `[sys.net]` (system domain service)

---

## 2. Monolithic desktop compositor (`diosix-gui`)

Located in `tools/diosix-gui/src/`:

*   **[`framebuffer.zig`](../tools/diosix-gui/src/framebuffer.zig),
    [`glass.zig`](../tools/diosix-gui/src/glass.zig),
    [`backdrop.zig`](../tools/diosix-gui/src/backdrop.zig),
    [`blur.zig`](../tools/diosix-gui/src/backdrop/blur.zig),
    [`noise.zig`](../tools/diosix-gui/src/noise.zig),
    [`font.zig`](../tools/diosix-gui/src/font.zig),
    [`banner.zig`](../tools/diosix-gui/src/font/banner.zig), and
    [`cursor.zig`](../tools/diosix-gui/src/cursor.zig)**: Double-buffered
    32-bit XRGB8888 software rasterizer, optical superellipse glass pane shader,
    procedural terrain/cloud sky backdrop renderer, anti-aliased glyph
    rasterizer, and software cursor rendering.
*   **[`window.zig`](../tools/diosix-gui/src/window.zig) and
    [`input.zig`](../tools/diosix-gui/src/window/input.zig)**: Window chrome,
    titlebar hit-testing, scrollbars, and mouse/keyboard dispatch.
*   **[`icon.zig`](../tools/diosix-gui/src/icon.zig),
    [`render.zig`](../tools/diosix-gui/src/icon/render.zig),
    [`text.zig`](../tools/diosix-gui/src/icon/text.zig),
    [`viewport.zig`](../tools/diosix-gui/src/icon/viewport.zig),
    [`widgets.zig`](../tools/diosix-gui/src/icon/widgets.zig), and
    [`label.zig`](../tools/diosix-gui/src/label.zig)**: Widget
    primitives (buttons, badges, sliders, progress bars, RFB/Wayland client
    viewports, vector action glyphs, and bounded text formatting).
*   **[`panes.zig`](../tools/diosix-gui/src/panes.zig),
    [`vm.zig`](../tools/diosix-gui/src/panes/vm.zig),
    [`catalog.zig`](../tools/diosix-gui/src/panes/catalog.zig),
    [`modal.zig`](../tools/diosix-gui/src/panes/modal.zig), and
    [`osk.zig`](../tools/diosix-gui/src/panes/osk.zig)**: Layout builders
    for the VM Fleet Overview, slide-out VM Action Drawer, Software and
    Hardware panes, Power modal, Welcome modal, 5-step Guided Tour, and
    dockable OSK.
*   **[`gui.zig`](../tools/diosix-gui/src/gui.zig),
    [`chrome.zig`](../tools/diosix-gui/src/gui/chrome.zig),
    [`input.zig`](../tools/diosix-gui/src/gui/input.zig),
    [`json.zig`](../tools/diosix-gui/src/gui/json.zig),
    [`nav.zig`](../tools/diosix-gui/src/gui/nav.zig),
    [`render.zig`](../tools/diosix-gui/src/gui/render.zig), and
    [`ipc.zig`](../tools/diosix-gui/src/ipc.zig)**: Core
    compositor state machine, dirty-rectangle damage tracking, keyboard focus
    navigation, semantic JSON state serialization, and host/VM action dispatch.
*   **[`osk.zig`](../tools/diosix-gui/src/osk.zig),
    [`welcome.zig`](../tools/diosix-gui/src/welcome.zig),
    [`intro.zig`](../tools/diosix-gui/src/intro.zig),
    [`fx.zig`](../tools/diosix-gui/src/intro/fx.zig), and
    [`audio.zig`](../tools/diosix-gui/src/audio.zig)**: Virtual
    keyboard state machine, Guided Tour state, boot intro sequence, and audio
    chimes.
*   **[`drm.zig`](../tools/diosix-gui/src/drm.zig),
    [`display.zig`](../tools/diosix-gui/src/display.zig),
    [`host.zig`](../tools/diosix-gui/src/host.zig),
    [`mem.zig`](../tools/diosix-gui/src/host/mem.zig),
    [`time.zig`](../tools/diosix-gui/src/host/time.zig),
    [`paths.zig`](../tools/diosix-gui/src/paths.zig), and
    [`main.zig`](../tools/diosix-gui/src/main.zig)**: Linux DRM/KMS dumb-buffer
    and `/dev/fb0` display backends, `evdev` input polling, host telemetry,
    canonical runtime paths, and event loop.

---

## 3. Configuration GUI component (`diosix-config`)

Located in `tools/diosix-config/src/`:

*   **[`ui.zig`](../tools/diosix-config/src/ui.zig)**: Widget library providing
    VM cards, navigation sidebars, memory and Virtual CPU (vCPU) sliders, and
    action buttons.
*   **[`main.zig`](../tools/diosix-config/src/main.zig)**: Application
    lifecycle, tab controller (Dashboard, Virtual Machines, Storage Disks,
    Network Matrix), and hypervisor Application Programming Interface (API)
    bridge.

---

## 4. System manifest specification (`system.toml`)

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

---

## 5. Detailed desktop implementation plan

For the historical design roadmap, window manager primitive specifications,
RISC OS-inspired Wimp event contracts, iconbar design, and rendering
optimizations, see
[Desktop implementation plan](desktop-implementation-plan.md).
