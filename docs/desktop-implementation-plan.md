# Diosix Graphics & Desktop Implementation Plan

## Modern RISC OS-Inspired Window Management for the Diosix Hypervisor

*Revision 1 — September 2026*

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Immediate Issues & Root-Cause Resolutions](#2-immediate-issues--root-cause-resolutions)
   - [2.1 Compositor Performance & Frame Latency](#21-compositor-performance--frame-latency)
   - [2.2 Truncated Mouse Cursor](#22-truncated-mouse-cursor)
   - [2.3 Blinking Virtual Terminal Console Cursor](#23-blinking-virtual-terminal-console-cursor)
3. [Architectural Philosophy: The RISC OS Influence](#3-architectural-philosophy-the-risc-os-influence)
   - [3.1 The Iconbar](#31-the-iconbar)
   - [3.2 The Three Mouse Buttons (Select, Menu, Adjust)](#32-the-three-mouse-buttons-select-menu-adjust)
   - [3.3 Context-Aware Popup Menus](#33-context-aware-popup-menus)
   - [3.4 The Pinboard as a Modular Application](#34-the-pinboard-as-a-modular-application)
   - [3.5 Pervasive Drag-and-Drop Workflows](#35-pervasive-drag-and-drop-workflows)
4. [API Design: Native Primitives vs. Wayland Compatibility](#4-api-design-native-primitives-vs-wayland-compatibility)
   - [4.1 The Native Diosix Wimp Protocol](#41-the-native-diosix-wimp-protocol)
   - [4.2 Wayland Integration for Foreign Guest VMs](#42-wayland-integration-for-foreign-guest-vms)
5. [Window Creation, Widgets & Rendering Engine](#5-window-creation-widgets--rendering-engine)
   - [5.1 Window Definition & Geometry](#51-window-definition--geometry)
   - [5.2 Icon Definitions & Widget Templates](#52-icon-definitions--widget-templates)
   - [5.3 Visual Styling & Tamper-Proof Security Borders](#53-visual-styling--tamper-proof-security-borders)
   - [5.4 2D Graphics, Sprites & Color Management](#54-2d-graphics-sprites--color-management)
   - [5.5 Typography & Vector Font Rendering](#55-typography--vector-font-rendering)
6. [Multitasking, Event Loop & Scheduling Model](#6-multitasking-event-loop--scheduling-model)
   - [6.1 Preemptive OS Multitasking with Wimp Event Dispatching](#61-preemptive-os-multitasking-with-wimp-event-dispatching)
   - [6.2 The Wimp_Poll Event Contract](#62-the-wimp_poll-event-contract)
   - [6.3 Redraw Protocol & Dirty Region Optimization](#63-redraw-protocol--dirty-region-optimization)
7. [Native Applications & Foreign VM Integration](#7-native-applications--foreign-vm-integration)
   - [7.1 Core Native Desktop Applications](#71-core-native-desktop-applications)
   - [7.2 Displaying Non-Native Guest Desktops and Windows](#72-displaying-non-native-guest-desktops-and-windows)
8. [Implementation Roadmap](#8-implementation-roadmap)

---

## 1. Executive Summary

Diosix is a secure, lightweight type-1 hypervisor. To deliver an intuitive,
modular, and responsive graphical user interface without the bloated dependency
chains of modern Linux desktop environments, Diosix adopts a desktop model
heavily inspired by the **Acorn RISC OS Window Manager (Wimp)**.

The RISC OS desktop paradigm prioritizes speed, clarity, modular components, and
seamless drag-and-drop workflows. At the bottom of the screen sits the
**Iconbar**, anchoring physical hardware resources on the left and active
applications and configuration modules on the right. Context-sensitive **Popup
Menus** open directly beneath the mouse pointer rather than across an inflexible
top menu bar. The desktop background is an independent application called the
**Pinboard**.

While the hypervisor and guest domains execute with fully preemptive scheduling,
applications interact with the window manager through a clean, event-driven
polling interface (`Wimp_Poll`) over Inter-Process Communication (IPC). Native
Diosix applications leverage a lightweight, tailored graphical API, while foreign
Virtual Machine (VM) payloads (such as Linux web browsers or word processors)
connect via a Wayland translation bridge that wraps guest surfaces in
tamper-proof, domain-colored security frames.

---

## 2. Immediate Issues & Root-Cause Resolutions

Investigation of the prototype desktop environment identifies three immediate
defects. Each issue has a clean, deterministic architectural fix.

### 2.1 Compositor Performance & Frame Latency

#### The Problem
In software emulation under QEMU, the desktop feels sluggish and unresponsive.
Reviewing [`tools/diosix-wm/src/main.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/main.zig)
reveals that the compositor executes a continuous 60 FPS busy loop:
1. Every 16 milliseconds, it issues `@memset` to clear the entire 1280x800x4
   byte backbuffer (4 megabytes).
2. It rasterizes every window titlebar, border, text string, and panel from
   scratch.
3. It performs a full 4-megabyte `@memcpy` to the mapped `/dev/fb0` scanout
   buffer.
4. It calls `msync(..., MSF.SYNC)`, forcing a synchronous blocking flush to the
   QEMU host graphics worker.

At 60 FPS, this forces over 240 megabytes of memory copies and 60 synchronous
host round-trips per second under pure software Tiny Code Generator (TCG)
emulation, even when the screen is completely stationary.

#### The Architectural Solution
1. **Damage Tracking (Dirty Rectangles)**:
   Track an invalidated bounding box `damage_rect: ?Rect`. When no windows move
   and no input events occur, redraw operations are skipped entirely.
2. **Differential Scanout Blitting**:
   When redrawing, only copy the updated bounding box slice from the backbuffer
   to the scanout buffer rather than copying the entire screen surface.
3. **Event-Driven Sleep (`epoll`/`poll`)**:
   Replace the unconditional `nanosleep(16ms)` loop with a Linux `epoll` wait
   monitoring seat input file descriptors (`/dev/input/event*`) and client IPC
   sockets. When idle, the compositor process sleeps with zero CPU overhead.

### 2.2 Truncated Mouse Cursor

#### The Problem
The mouse pointer sprite in
[`tools/diosix-wm/src/seat.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/seat.zig)
uses a crude nested loop that clamps columns to `col < 8` and `row < 12`, with an
incomplete two-pixel black border. This chops the cursor into a blunt fragment
missing its stem, tail, and contrast outline.

#### The Architectural Solution
Replace the procedural loop with a formal **Cursor Sprite Definition**:
- Define a 16x16 or 24x24 32-bit pixel array with an explicit hotspot at (0, 0).
- Support four-state pixels: Transparent, Outer Outline (Black), Inner Body
  (White), and Accent Fill (Acorn Red).
- Store a backing scratch buffer beneath the cursor. When the mouse moves, the
  compositor restores the saved background pixels and writes the cursor at the
  new coordinate, avoiding a full window tree re-render for mouse movements.

```text
Row  0:  # . . . . . . . . . . . . . . .
Row  1:  # # . . . . . . . . . . . . . .
Row  2:  # O # . . . . . . . . . . . . .
Row  3:  # O O # . . . . . . . . . . . .
Row  4:  # O O O # . . . . . . . . . . .
Row  5:  # O O O O # . . . . . . . . . .
Row  6:  # O O O O O # . . . . . . . . .
Row  7:  # O O O O O O # . . . . . . . .
Row  8:  # O O O O # # # . . . . . . . .
Row  9:  # O # O O # . . . . . . . . . .
Row 10:  # # . # O O # . . . . . . . . .
Row 11:  # . . . # O O # . . . . . . . .
Row 12:  . . . . . # # . . . . . . . . .
(# = Black outline, O = White body, . = Transparent)
```

### 2.3 Blinking Virtual Terminal Console Cursor

#### The Problem
A blinking underline cursor appears in the upper left corner of the screen
(coordinate 0, 0). This is caused by the Linux kernel's Framebuffer Console
(`fbcon`) driver, which binds Virtual Terminal 0 (`/dev/tty0`) to `/dev/fb0`.
The kernel timer continues to blink the text mode hardware cursor over the top
panel of the graphical compositor.

#### The Architectural Solution
1. **Kernel Boot Argument**:
   In [`hypervisor/core/boot.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/hypervisor/core/boot.zig),
   append `vt.global_cursor_default=0` to the guest kernel boot parameters in
   `/chosen/bootargs`.
2. **Terminal Graphics Mode Setting**:
   During initialization, `diosix-wm` opens the active virtual terminal and
   issues `ioctl(fd, KDSETMODE, KD_GRAPHICS)` along with writing the escape
   string `\033[?25l` (hide cursor) to disable VT cursor rendering.

---

## 3. Architectural Philosophy: The RISC OS Influence

The Diosix desktop environment rejects the bloated, monolithic top-menu design
of conventional contemporary desktops in favor of the lightweight, spatial, and
clean structure established by RISC OS.

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│   [ !SysConfig ]        [ !WebBrowser ]                     [ Disks ]        │
│   ┌───────────────────┐ ┌─────────────────────────────────┐ ┌──────────────┐ │
│   │ Diosix Host Config│ │ Sandboxed Web Browser           │ │ :0  rootfs   │ │
│   ├───────────────────┤ ├─────────────────────────────────┤ ├──────────────┤ │
│   │ [sys.config]      │ │ [user.web]                      │ │ :1  storage  │ │
│   │                   │ │                                 │ └──────────────┘ │
│   │ Memory: 128 MB    │ │ https://diosix.org              │                  │
│   │ vCPUs: 2          │ │                                 │   (Pinboard)     │
│   └───────────────────┘ └─────────────────────────────────┘                  │
│                                                                              │
│                                   ┌────────────────┐                         │
│                                   │ Display Setup  │                         │
│                                   ├────────────────┤                         │
│                                   │ New VM...    > │ (Context Menu           │
│                                   │ Applications > │  opened on click)       │
│                                   │ Log Out        │                         │
│                                   └────────────────┘                         │
├──────────────────────────────────────────────────────────────────────────────┤
│ [:0] [:1] [eth0] [CPU: 4%]                      [!SysConfig] [!VMMgr] [12:00]│
│  <-- Drives, Network & Hardware                   Active Applications -->    │
│                                (The Iconbar)                                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 The Iconbar

The **Iconbar** is a persistent horizontal shelf anchored to the bottom of the
display (height: 52 pixels):

*   **Left-Hand Side (Hardware & Storage Devices)**:
    - Block storage devices (e.g. `:0` for the root drive, `:1` for attached
      storage volumes). Clicking a drive icon opens a directory viewer window
      showing that volume's filesystem.
    - Network interface status (virtual network `diosix0`, MAC address, and IP
      indicators).
    - Host hypervisor load monitor (physical core load gauge and memory
      utilization).
*   **Right-Hand Side (Applications & Services)**:
    - Running applications install their application sprite on the right of the
      iconbar (e.g. `!SysConfig`, `!VMMgr`, `!Terminal`, `!TextEdit`).
    - The rightmost slot contains a compact date/time clock and notification
      bell.
*   **Behavior**:
    - Clicking an application icon with **Select** brings its primary window to
      the front. If the application has no open windows, it opens a default
      window or template.
    - Clicking an application icon with **Menu** displays that application's
      top-level context menu (`Info`, `Configure`, `Quit`).
    - Closing an application's windows does not terminate the process; it
      remains active on the iconbar, ready for instant invocation.

### 3.2 The Three Mouse Buttons (Select, Menu, Adjust)

Diosix adheres strictly to the classic three-button mouse paradigm:

1.  **Select (Left Button)**:
    - Primary activation.
    - Click to focus and raise a window.
    - Double-click to open files or launch applications.
    - Click and drag to reposition windows, adjust scrollbars, or perform
      drag-and-drop transfers.
2.  **Menu (Middle or Right Button)**:
    - Opens a context-sensitive popup menu tree at the current pointer
      coordinate.
    - Works on the desktop backdrop, window work areas, titlebars, and iconbar
      elements.
    - Menus are dismissed when clicking outside with Select.
3.  **Adjust (Right Button or Modified Click)**:
    - Secondary toggle and fine adjustment.
    - In directory views, clicking an item with Adjust toggles selection without
      clearing existing selections.
    - In popup menus, clicking a menu item with Adjust **executes the action
      without closing the menu**, allowing the user to rapidly toggle multiple
      options.

### 3.3 Context-Aware Popup Menus

Diosix eliminates fixed top-screen menu bars. Contextual menus appear anywhere on
demand:

*   **Pinboard Menu**: Right-clicking the desktop backdrop displays desktop
    configuration, icon rearrangement options, and hypervisor power controls.
*   **Window Menu**: Right-clicking inside an application window displays that
    application's operations (e.g. `File > Save`, `Edit > Find`, `Zoom`).
*   **Submenus**: Entries with arrow indicators (`>`) cascade to the right when
    hovered or clicked with Select.
*   **In-Place Dialogs**: Menu sub-items can open small parameter entry boxes
    directly adjacent to the menu item without requiring heavy modal windows.

### 3.4 The Pinboard as a Modular Application

The desktop backdrop is not hardcoded into the window manager compositor. It is
an autonomous client application named `!Pinboard`:
- It owns the bottom layer of the desktop stack.
- It displays custom background artwork or gradients.
- It allows users to "pin" frequently accessed files, directories, and VM
  launch configurations directly to the desktop workspace.
- Clicking or dragging across the Pinboard allows rubber-band multi-selection of
  pinned icons.

### 3.5 Pervasive Drag-and-Drop Workflows

File interactions in Diosix avoid modal file-selection dialogs:
- To start a VM, the user drags a VM manifest or ISO file directly from a file
  browser window onto the `!VMMgr` icon on the iconbar.
- To open a document, the user drags its icon into an open application window.
- To attach virtual storage to a running guest domain, the user drags the disk
  icon onto that domain's window.

---

## 4. API Design: Native Primitives vs. Wayland Compatibility

Diosix does not lock its desktop to an external display server standard.
Instead, it provides a dual-interface architecture:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                          DIOSIX COMPOSITOR (diosix-wm)                      │
│                                                                             │
│  ┌──────────────────────────────┐        ┌───────────────────────────────┐  │
│  │   Native Diosix Wimp API     │        │    Wayland Translation Bridge │  │
│  │   (AF_UNIX / Shared Memory)  │        │    (wl_compositor / VSOCK)    │  │
│  └──────────────▲───────────────┘        └───────────────▲───────────────┘  │
└─────────────────┼────────────────────────────────────────┼──────────────────┘
                  │                                        │
     ┌────────────┴────────────┐             ┌─────────────┴─────────────┐
     │ Native Diosix Apps      │             │ Foreign Linux Guest VMs   │
     │ (!SysConfig, !VMMgr)    │             │ (Firefox, LibreOffice)    │
     │ Direct Zig/C API        │             │ Standard Wayland Clients  │
     └─────────────────────────┘             └───────────────────────────┘
```

### 4.1 The Native Diosix Wimp Protocol

For native applications written in Zig or C, Diosix provides `libdiosix-ui`, a
compact client library modeled after RISC OS Software Interrupts (SWIs):

- **Window Management**:
  - `wimp_create_window(const WindowDef* def)` -> `WindowHandle`
  - `wimp_open_window(WindowHandle handle, const WindowState* state)`
  - `wimp_close_window(WindowHandle handle)`
  - `wimp_delete_window(WindowHandle handle)`
- **Icon Operations**:
  - `wimp_create_icon(WindowHandle win, const IconDef* icon)` -> `IconHandle`
  - `wimp_set_icon_state(WindowHandle win, IconHandle icon, u32 set, u32 clear)`
- **Menu System**:
  - `wimp_create_menu(const MenuDef* menu, i32 x, i32 y)`
- **Event Polling**:
  - `wimp_poll(u32 mask, WimpEvent* event)`

Communication occurs across high-speed Unix domain sockets using structured
binary messages, with graphics surfaces allocated from shared memory (`shm_open`
or `memfd_create`).

### 4.2 Wayland Integration for Foreign Guest VMs

To run standard graphical software from guest Linux, BSD, or Android VMs:
1. `diosix-wm` implements core Wayland protocols (`wl_compositor`, `wl_shm`,
   `xdg_shell`, `wl_seat`).
2. Wayland sockets are exposed over **VirtIO-VSOCK** (`AF_VSOCK`) into guest
   domains.
3. When a foreign application creates an `xdg_toplevel` surface, `diosix-wm`
   wraps that surface in a native window frame and decorates it with an
   immutable security badge indicating the originating VM domain.

---

## 5. Window Creation, Widgets & Rendering Engine

### 5.1 Window Definition & Geometry

A window definition mirrors the spatial coordinates of RISC OS:
- **Visible Box (`vis_area`)**: The bounding box of the window on the desktop
  surface (including titlebar, borders, and scrollbars).
- **Work Area Extents (`work_area`)**: The virtual canvas coordinate bounds
  (e.g., a document canvas may be 2000x3000 pixels, viewed through a 600x400
  window).
- **Scroll Offsets (`scroll_x`, `scroll_y`)**: Current offset of the visible
  viewport within the work area.
- **Window Flags**:
  - `has_titlebar`: Window displays a titlebar.
  - `is_moveable`: User can drag the window.
  - `is_resizable`: Window displays resize grips and scrollbars.
  - `has_back_button`: Window displays a "Send to Back" button.
  - `has_close_button`: Window displays a close icon.
  - `domain_id`: Hypervisor Domain CID for provenance verification.

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ [X] Diosix Host Configuration [sys.config]                           [V] [^]│
├─────────────────────────────────────────────────────────────────────────┬───┤
│                                                                         │ ▲ │
│ Work Area Viewport                                                      │ █ │
│ (Virtual coordinates mapped via scroll offsets)                         │ █ │
│                                                                         │ │ │
│                                                                         │ ▼ │
├─────────────────────────────────────────────────────────────────────────┼───┤
│ ◄ ████████████████                                                    ► │ ◢ │
└─────────────────────────────────────────────────────────────────────────┴───┘
```

### 5.2 Icon Definitions & Widget Templates

In the RISC OS architecture, all standard controls inside a window—buttons,
labels, text fields, radio buttons, and sprites—are called **Icons**. An icon
is defined by a standard data block:

```zig
pub const IconFlags = packed struct(u32) {
    text: bool = false,
    sprite: bool = false,
    border: bool = false,
    h_centered: bool = false,
    v_centered: bool = false,
    clickable: bool = true,
    shaded: bool = false, // Disabled/greyed out
    selected: bool = false,
    has_validation: bool = false,
    reserved: u23 = 0,
};

pub const IconDef = struct {
    bounds: Rect,
    flags: IconFlags,
    foreground: u32,
    background: u32,
    data: IconData,
};
```

This compact, declarative widget format allows dialogs and toolbars to be
defined statically in memory and rendered with extreme performance without
heavy object-oriented widget trees.

### 5.3 Visual Styling & Tamper-Proof Security Borders

Diosix adopts a crisp, modern 3D beveled appearance inspired by classic Acorn
styling with contemporary color palettes:

- **Soft 3D Relief**: Windows and buttons feature light highlights on the top
  and left edges, with dark shadows on the bottom and right edges.
- **Window Controls**:
  - Left button: **Close Window** (`[X]`).
  - Right button 1: **Send to Back** (`[V]`): Drops the window beneath all other
    open windows without closing it.
  - Right button 2: **Toggle Size / Maximize** (`[^]`): Expands the window to
    fill the visible desktop (excluding the iconbar) or restores its previous
    size.
- **Domain Trust Security Borders**:
  The window frame is rendered exclusively by `diosix-wm` in the presentation
  domain (`sys.gui`). Client applications cannot paint into the frame area. The
  outer edge displays a prominent 3-pixel color band indicating the domain's
  security provenance:
  - 🟢 **Emerald Green (`#2ECC71`)**: `[sys.config]` (Trusted Admin Domain).
  - 🔵 **Dodger Blue (`#3498DB`)**: `[user.work]` (Work Domain).
  - 🔴 **Alizarin Red (`#E74C3C`)**: `[user.web]` (Untrusted Sandboxed Domain).
  - 🟣 **Amethyst Purple (`#9B59B6`)**: `[sys.net]` (System Domain Service).

### 5.4 2D Graphics, Sprites & Color Management

The 2D rendering pipeline operates on 32-bit true-color pixels (ARGB8888):
- **Sprite Area**: A memory buffer containing named bitmap sprites with alpha
  masks. The system maintains a shared sprite bank for icons, drives, and
  controls.
- **Compositing Operators**:
  - `drawSprite`: Bitmaps with 1-bit or 8-bit alpha channels.
  - `fillRect`: Fast solid color fills.
  - `drawBevel`: Highlight/shadow border strokes for 3D buttons and panels.
  - `drawText`: Character glyph rasterization.

### 5.5 Typography & Vector Font Rendering

Typography proceeds in two phases:
1.  **Phase 1 (Bitmap Typography)**: Clean, high-contrast monospace and
    proportional bitmap font glyphs (8x16 and 9x18) stored directly in the
    binary.
2.  **Phase 2 (Scalable Vector Fonts)**: Integrated vector font rasterizer
    providing smooth subpixel anti-aliasing for application text, dialogs, and
    titles at any display DPI.

---

## 6. Multitasking, Event Loop & Scheduling Model

### 6.1 Preemptive OS Multitasking with Wimp Event Dispatching

Multitasking in Diosix operates at two distinct layers:
1.  **Operating System Layer**:
    The Diosix hypervisor and Linux guest kernels execute **fully preemptive**
    time-slice scheduling across multiple virtual and physical CPU cores.
2.  **Application Interaction Layer**:
    Applications coordinate their graphical presentation via an **event-driven
    poll loop**. The client calls `wimp_poll()`, which suspends the client
    process on an IPC socket until the window manager has work for it.

### 6.2 The Wimp_Poll Event Contract

Every native application runs an event loop structured around `wimp_poll`:

```zig
pub fn main() !void {
    const app = try wimp.initApp("!SysConfig");
    defer app.deinit();

    var running = true;
    while (running) {
        const event = try app.poll(wimp.PollMask.default);
        switch (event) {
            .null_reason => {}, // Idle time processing if requested
            .redraw_window_request => |r| try app.redrawWindow(r),
            .open_window_request => |o| try app.openWindow(o),
            .close_window_request => |c| try app.closeWindow(c),
            .pointer_click => |p| try app.handlePointerClick(p),
            .key_pressed => |k| try app.handleKeyPress(k),
            .menu_selection => |m| try app.handleMenuSelect(m),
            .user_message => |msg| {
                if (msg.action == .quit) running = false;
            },
        }
    }
}
```

### 6.3 Redraw Protocol & Dirty Region Optimization

Rather than maintaining an enormous offscreen surface for every window in
memory, Diosix implements the efficient RISC OS **Clip Rectangle Redraw
Protocol**:

1.  When an area of a window is damaged or exposed, `diosix-wm` sends a
    `redraw_window_request` containing the exposed bounding rectangle.
2.  The client calls `wimp_get_rectangle()` to receive the first visible sub-box
    in its work area.
3.  The client renders only the graphics and text overlapping that sub-box.
4.  The client loops `wimp_get_rectangle()` until all overlapping visible
    rectangles are satisfied.
5.  `diosix-wm` marks only those changed pixels as damaged, updating the physical
    framebuffer via a targeted blit.

---

## 7. Native Applications & Foreign VM Integration

### 7.1 Core Native Desktop Applications

The initial Diosix desktop includes four foundational native applications:

1.  **`!SysConfig` (System Configuration & Domain Monitor)**:
    - Sits on the iconbar.
    - Monitors physical hardware: CPU load, RAM allocation, temperature, and
      battery.
    - Displays active guest VM domains, granted device passthrough status, and
      dynamic resource quotas.
2.  **`!VMMgr` (Virtual Machine Manager)**:
    - Launches, suspends, and terminates guest VMs.
    - Features memory and vCPU sliders.
    - Supports drag-and-drop: dragging an ELF kernel or ISO disk image onto the
      `!VMMgr` iconbar icon immediately opens the configuration prompt to run
      that VM.
3.  **`!Filer` (Volume & Directory Browser)**:
    - Double-clicking a storage drive icon on the left of the iconbar opens a
      `!Filer` window displaying the contents of that filesystem.
    - Files can be dragged into applications or pinned to the desktop.
4.  **`!Pinboard` (Desktop Background)**:
    - Paints the desktop wallpaper.
    - Manages desktop shortcut icons.

### 7.2 Displaying Non-Native Guest Desktops and Windows

Foreign guest operating systems (e.g. Debian Linux, FreeBSD, Alpine) are
accommodated through two presentation modes:

1.  **Seamless Window Integration (Default)**:
    - The guest runs a lightweight Wayland proxy (`diosix-wayland-bridge`).
    - Individual applications (such as a web browser or text editor) export
      their surfaces across VirtIO-VSOCK.
    - Each surface appears on the Diosix desktop as an independent native
      window bordered by the guest's domain security badge.
2.  **Full Desktop in a Window**:
    - For guest VMs that boot a complete desktop environment (e.g. XFCE or
      GNOME), the guest's entire screen output is displayed within a single
      resizable Diosix window.
    - Clicking inside the window captures the seat focus; pressing a release hotkey
      (e.g., `Ctrl+Alt+Escape`) returns focus to the host desktop.

---

## 8. Implementation Roadmap

The graphics and desktop implementation is structured into five sequential
phases:

### Phase 1: Core Performance, DRM KMS Acceleration & Hardware Cursor
- Implement direct Linux DRM/KMS hardware acceleration in
  [`tools/diosix-wm/src/drm.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/drm.zig)
  accessing `/dev/dri/card0`.
- Utilize the VirtIO-GPU **Hardware Cursor Plane** via `DRM_IOCTL_MODE_CURSOR`:
  - Pointer movement (`DRM_MODE_CURSOR_MOVE`) incurs 0 memory copying, 0 page
    faults, and 0 latency; the host GPU composites the cursor overlay directly.
- Allocate scanout memory via DRM dumb buffers (`DRM_IOCTL_MODE_CREATE_DUMB` and
  `DRM_IOCTL_MODE_MAP_DUMB`) bypassing the kernel's `fb_deferred_io` page fault
  trapping mechanism.
- Flush damaged sub-regions immediately via `DRM_IOCTL_MODE_DIRTYFB`, eliminating
  the 50ms (20 FPS) deferred I/O latency bottleneck present in legacy `/dev/fb0`.
- Maintain automatic fallback to `/dev/fb0` software rendering in
  [`tools/diosix-wm/src/framebuffer.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/framebuffer.zig).
- Support host OpenGL Virgl acceleration via `virtio-gpu-gl-pci` in
  [`build.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/build.zig)
  (`zig build run-gui -Dgl=true`).
- Disable Linux framebuffer console cursor blinking by passing
  `vt.global_cursor_default=0` in
  [`hypervisor/core/boot.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/hypervisor/core/boot.zig).

### Phase 2: The Iconbar & Modernized RISC OS Aesthetics
- Replace the prototype top bar with the persistent bottom **Iconbar** (height:
  52 pixels) in
  [`tools/diosix-wm/src/panel.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/panel.zig).
- Partition the iconbar into left-hand hardware/device slots and right-hand
  application slots.
- Redesign window frames in
  [`tools/diosix-wm/src/decorator.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/decorator.zig)
  with 3D beveled borders, Acorn-style window buttons (Close `[X]`, Send-to-Back
  `[V]`, Toggle-Size `[^]`), and domain trust color bands.

### Phase 3: Three-Button Input Model & Context-Aware Popup Menus
- Add right-click (**Menu**) and middle-click event routing in
  [`tools/diosix-wm/src/seat.zig`](file:///home/chris/Documents/src/diosix-hq/diosix/tools/diosix-wm/src/seat.zig).
- Implement dynamic popup menu trees with cascading submenus.
- Implement **Adjust-click** functionality, allowing options to be toggled
  without closing the active menu tree.

### Phase 4: Native Wimp API & Modular Applications
- Develop `libdiosix-ui`, providing the native `wimp_poll` client API and
  structured icon definitions.
- Implement `!Pinboard` as a standalone desktop background manager.
- Port `diosix-config` into a native `!SysConfig` iconbar application.
- Implement `!VMMgr` with drag-and-drop ISO/manifest VM launching.

### Phase 5: Foreign VM Wayland Integration
- Expose Wayland protocols over VirtIO-VSOCK channels.
- Map guest application surfaces into native Diosix Wimp frames.
- Verify multi-domain visual isolation across concurrent trusted and untrusted
  guest workloads.
