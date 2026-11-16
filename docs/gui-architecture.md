# Diosix GUI architecture

## Overview and execution model

When display hardware is present on the host, the root virtual machine (VM)
starts the Diosix desktop compositor automatically at boot unless text-only
mode is requested on the kernel command line. Written in Zig, the compositor
drives Linux direct rendering manager (DRM) and kernel mode setting (KMS) dumb
buffers (with a Linux framebuffer device fallback) and reads kernel input event
devices directly without an external display server:

```text
+----------------------------------------------------------------------------+
|                             Physical hardware                              |
|      Physical display (DRM / KMS or fbdev)    Keyboard, mouse & touchscreen|
+---------------------------------+---------------------------+--------------+
                                  |                           |
+---------------------------------v---------------------------v--------------+
|                        Any VM Node (CID 1 - Linux)                         |
|                                                                            |
|  +----------------------------------------------------------------------+  |
|  |                        Host desktop compositor                       |  |
|  |                                                                      |  |
|  |  * Top-left navigation menu (Create VM, About, Config, Power)        |  |
|  |  * Running guest VMs pane, live quota sliders, and task status bars  |  |
|  |  * Guest VirtIO-GPU desktop display and VirtIO-Input event bridge    |  |
|  |  * Built-in VT100 terminal (local shell, guest SSH, serial console)  |  |
|  |  * Dockable on-screen keyboard, welcome modal, and guided tour       |  |
|  |  * Semantic JSON state export and command control plane              |  |
|  +------------------+----------------------------+--------------------+--+ |
|                     |                            |                    |    |
|          Hypervisor driver calls          Pseudo-TTYs + SSH     CLI tasks  |
+---------------------|----------------------------|--------------------|----+
                      v                            v                    v
            M-mode hypervisor                Child guest VMs      Image & disk
      (Quotas, scanout, input, info)          (Guest OSes)        provisioning
```

---

## Desktop layout and workflows

* The top-left navigation menu opens panes for creating VMs, inspecting host
  and hypervisor metrics (uptime, CPU and RAM totals, UTC clock, and M-mode
  heap usage), adjusting display settings (transparency, backdrop animation,
  poll rate, color scheme, resolution preset, Bayer dithering depth, and UI
  scale), and confirming host restart or shutdown.
* The running guest VMs pane sits beside the main menu. Selecting a guest opens
  its detail card with a 60-sample physical CPU usage graph, live CPU share and
  RAM pool sliders, attached disk metadata, lifecycle controls, and buttons to
  open a terminal or graphical display.
* Selecting **Open guest display** on a child VM opens a full-width desktop
  window that streams the child's VirtIO-GPU 2D scanout into an
  aspect-ratio-matched viewport at up to 60 Hz and forwards physical keystrokes,
  on-screen keyboard input, mouse clicks, scroll-wheel ticks, and absolute
  tablet coordinates into the child's VirtIO-Input device.
* The **Create VM** pane browses local kernels and ISOs, configures name,
  virtual CPU (vCPU) count, RAM, and virtual disk settings, and spawns CLI
  provisioning jobs asynchronously while rendering progress and error bars
  along the bottom edge.
* The built-in VT100 terminal multiplexer maintains up to 16 concurrent
  sessions (up to 200x60 cells) across local VM shells, key-authenticated
  child VM SSH logins, and raw hypervisor serial consoles.
* Contextual help and version chrome bars anchor the bottom of the screen,
  while live boots (or `diosix.welcome=force` sessions) present the welcome
  onboarding modal with one-click **Try Desktop VM** and **Try CLI VM**
  launchers alongside the 5-step guided tour. Passing `diosix.demo=desktop` or
  `diosix.demo=cli` on the kernel command line skips the intro animation,
  launches the matching built-in guest VM automatically, and opens its
  VirtIO-GPU 2D display or serial console pane once the guest comes online.

---

## Compositor internals

For the exact list of source files in each subsystem, see the
[Feature support matrix](support-matrix.md). Internally, the compositor is
divided into six subsystems:

* The entrypoint and inter-process communication (IPC) loop initializes display
  scanout and non-blocking input polling, switches to faster 16 ms frame
  cadence whenever an interactive terminal or guest desktop window is open, and
  synchronizes the JSON control plane.
* The display and input backend manages double-buffered KMS dumb buffers,
  mode-setting presets from 800x600 up to 3840x2160, connector-aware DPI
  scaling from 75% to 200%, 4x4 Bayer ordered dithering across 8-, 15-, 16-,
  and 32-bit color depths, and keyboard, mouse, scroll-wheel, and calibrated
  touchscreen input.
* The software rasterizer and typography engine renders clipped 32-bit RGB
  surfaces, procedural sky and terrain backdrops, superellipse frosted-glass
  panes, 4x4 supersampled vector icons and cursors, and freestanding TrueType
  glyph caches for proportional UI text and monospaced terminal cells.
* The window manager and widget toolkit tracks dirty damage rectangles,
  animates sliding sub-panes, and provides reusable buttons, sliders,
  dropdowns, checkboxes, text fields, line graphs, and progress bars.
* The management panes and host bridge query hypervisor state and kernel
  telemetry, drive live quota updates, manage pseudo-terminal and serial I/O,
  and monitor background CLI child processes.
* The guest desktop bridge prefers read-only Stage-2 zero-copy mapping over
  `GPU_MAP_SCANOUT` and `mmap()` when running on H-extension hardware, reading
  only changed dirty rectangles and the 64x64 hardware cursor overlay directly
  from mapped child pages, and falls back seamlessly to pinned page streaming
  when required. It renders updated pixels into the sunken viewport well and
  translates pointer coordinates into VirtIO tablet, mouse, and key events.
* Because M-mode enforces relative CIDs and child subtree opacity everywhere,
  `diosix-gui` operates identically inside the initial top-level VM or any
  nested child VM, displaying a one-level tree rooted at self (`CID 1`) with
  strictly direct children.

---

## Semantic JSON control plane

The compositor exposes a file-based control plane under `/run/diosix/` so CLI
commands and automated tests can inspect and drive the desktop without
screen-scraping:

* Whenever UI state changes, the compositor atomically writes
  `/run/diosix/gui_state.json` with the current resolution, render mode, active
  pane (`main`, `create_vm`, `about`, `config`, `guest_display`, or `submenu`),
  window count, on-screen keyboard state, and welcome or guided tour progress.
* Writing an action name to `/run/diosix/gui_cmd` (or running
  `dsx gui trigger <action>`) triggers navigation and modal actions directly:

| Category | Actions |
| :--- | :--- |
| Navigation | `menu.create_vm`, `menu.about`, `menu.status`, `menu.config`, `menu.back` |
| On-screen keyboard | `osk.toggle`, `osk.show`, `osk.hide` |
| Welcome and tour | `welcome.open`, `welcome.close`, `welcome.try_desktop`, `welcome.try_cli`, `tour.start`, `tour.next`, `tour.prev`, `tour.close` |
