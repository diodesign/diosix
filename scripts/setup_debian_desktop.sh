#!/usr/bin/env bash
#
# setup_debian_desktop.sh: Provision and configure a Debian RISC-V Desktop guest for diosix-wm
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT
#

set -eo pipefail

BOLD="$(printf '\033[1m')"
GREEN="$(printf '\033[32m')"
BLUE="$(printf '\033[34m')"
YELLOW="$(printf '\033[33m')"
RED="$(printf '\033[31m')"
RESET="$(printf '\033[0m')"

log_info() { echo -e "${BLUE}==>${RESET} ${BOLD}$1${RESET}"; }
log_ok()   { echo -e "${GREEN}  ✓${RESET} $1"; }
log_warn() { echo -e "${YELLOW}  !${RESET} $1"; }
log_err()  { echo -e "${RED}  ✗${RESET} $1"; }

DEFAULT_DISK_PATH="zig-out/storage-staging/disks/debian.img"
CANONICAL_DISK_DIR="/var/lib/diosix/disks"
DISK_SIZE="4096M"

usage() {
    cat <<EOF
${BOLD}Diosix Debian RISC-V Desktop Provisioner${RESET}

This script automates setting up a Debian desktop environment for use with ${BOLD}diosix-wm${RESET}.
It supports two display integration modes:
  1. ${BOLD}Rooted Desktop Window (RFB / VNC)${RESET}: Full XFCE/LXDE desktop session streamed
     directly into a native Wuss/RISC OS window in diosix-wm (target: 10.0.3.2:5900).
  2. ${BOLD}Seamless Wayland Windows${RESET}: Guest applications render to individual native
     windows via the built-in Wayland translation bridge (TCP port 8484).

${BOLD}Usage:${RESET}
  $0 [command] [options]

${BOLD}Commands:${RESET}
  create [path] [size]   Create a new formatted ext4 virtual disk image for Debian
  setup-rootfs <dir>     Install desktop, VNC server, and Wayland bridge configs into rootfs
  instructions           Print step-by-step guest setup and launch instructions
  help                   Show this help message

${BOLD}Quick Start inside Diosix Root VM:${RESET}
  # Create a virtual disk for Debian:
  dsx disk create debian --size 4096

  # Launch Debian with rootfs attached to virtio-blk:
  dsx run default --name debian-vm --disk debian.img --ram 1024M --vcpus 2

  # In diosix-wm, the 'Debian Desktop' window will automatically connect to 10.0.3.2:5900!

EOF
}

cmd_create() {
    local target_img="${1:-$DEFAULT_DISK_PATH}"
    local size="${2:-$DISK_SIZE}"

    log_info "Creating Debian virtual disk image at ${BOLD}${target_img}${RESET} (${size})..."
    mkdir -p "$(dirname "$target_img")"

    if command -v mke2fs >/dev/null 2>&1; then
        rm -f "$target_img"
        mke2fs -F -q -t ext4 -L "DEBIAN_ROOT" "$target_img" "$size"
        log_ok "Created ext4 disk image: $target_img"
    elif command -v truncate >/dev/null 2>&1 && command -v mkfs.ext4 >/dev/null 2>&1; then
        truncate -s "$size" "$target_img"
        mkfs.ext4 -F -L "DEBIAN_ROOT" "$target_img"
        log_ok "Created ext4 disk image: $target_img"
    else
        log_err "Neither mke2fs nor mkfs.ext4 found. Please install e2fsprogs."
        exit 1
    fi
}

cmd_setup_rootfs() {
    local rootfs_dir="$1"
    if [ -z "$rootfs_dir" ] || [ ! -d "$rootfs_dir" ]; then
        log_err "Target rootfs directory '$rootfs_dir' does not exist."
        exit 1
    fi

    log_info "Configuring guest desktop and networking services in ${rootfs_dir}..."

    # 1. Virtual Network Configuration (diosix0 bridge)
    mkdir -p "$rootfs_dir/etc/network" "$rootfs_dir/etc/network/interfaces.d"
    cat <<'EOF' > "$rootfs_dir/etc/network/interfaces.d/diosix0"
auto diosix0
iface diosix0 inet static
    address 10.0.3.2
    netmask 255.255.255.0
    gateway 10.0.3.1
    nameserver 10.0.3.1
EOF
    log_ok "Configured static networking on diosix0 (10.0.3.2 -> Root VM 10.0.3.1)."

    # 2. XFCE / TigerVNC Startup Configuration (Step 1: Rooted Desktop Window)
    mkdir -p "$rootfs_dir/etc/skel/.vnc" "$rootfs_dir/root/.vnc"
    cat <<'EOF' > "$rootfs_dir/root/.vnc/xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
[ -x /etc/vnc/xstartup ] && exec /etc/vnc/xstartup
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources
which startxfce4 >/dev/null && exec startxfce4
which openbox-session >/dev/null && exec openbox-session
exec x-window-manager
EOF
    chmod 755 "$rootfs_dir/root/.vnc/xstartup"
    cp -f "$rootfs_dir/root/.vnc/xstartup" "$rootfs_dir/etc/skel/.vnc/xstartup"

    # 3. Systemd / init script for VNC Server service
    mkdir -p "$rootfs_dir/etc/init.d"
    cat <<'EOF' > "$rootfs_dir/etc/init.d/diosix-vnc"
#!/bin/sh
### BEGIN INIT INFO
# Provides:          diosix-vnc
# Required-Start:    $network $syslog
# Required-Stop:     $network $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: TigerVNC service for diosix-wm remote desktop
### END INIT INFO

case "$1" in
    start)
        echo "Starting TigerVNC server for diosix-wm on :0 (port 5900)..."
        tigervncserver :0 -geometry 1024x768 -depth 24 -SecurityTypes None -localhost no &
        ;;
    stop)
        echo "Stopping TigerVNC server..."
        tigervncserver -kill :0 || true
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: /etc/init.d/diosix-vnc {start|stop|restart}"
        exit 1
        ;;
esac
exit 0
EOF
    chmod 755 "$rootfs_dir/etc/init.d/diosix-vnc"
    log_ok "Created VNC autostart service for display :0 (port 5900, SecurityTypes=None)."

    # 4. Wayland TCP Bridge Relay (Step 2: Seamless Windows)
    cat <<'EOF' > "$rootfs_dir/etc/init.d/diosix-wayland"
#!/bin/sh
### BEGIN INIT INFO
# Provides:          diosix-wayland
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Wayland socket relay to diosix-wm host
### END INIT INFO

case "$1" in
    start)
        echo "Bridging local /tmp/wayland-0 to Root VM diosix-wm (10.0.3.1:8484)..."
        rm -f /tmp/wayland-0
        socat UNIX-LISTEN:/tmp/wayland-0,fork,mode=777 TCP:10.0.3.1:8484 &
        ;;
    stop)
        pkill -f "socat.*UNIX-LISTEN:/tmp/wayland-0" || true
        rm -f /tmp/wayland-0
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: /etc/init.d/diosix-wayland {start|stop|restart}"
        exit 1
        ;;
esac
exit 0
EOF
    chmod 755 "$rootfs_dir/etc/init.d/diosix-wayland"
    log_ok "Created Wayland socket relay bridging /tmp/wayland-0 to 10.0.3.1:8484."

    # 5. Environment configuration for login shells
    mkdir -p "$rootfs_dir/etc/profile.d"
    cat <<'EOF' > "$rootfs_dir/etc/profile.d/diosix-gui.sh"
# Environment configuration for Diosix Window Manager integration
export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/tmp
EOF
    chmod 755 "$rootfs_dir/etc/profile.d/diosix-gui.sh"
    log_ok "Configured default DISPLAY=:0 and WAYLAND_DISPLAY=wayland-0 in /etc/profile.d/."

    log_ok "Debian rootfs configuration completed successfully."
}

cmd_instructions() {
    cat <<EOF
================================================================================
           Debian Desktop on Diosix Window Manager (diosix-wm)
================================================================================

${BOLD}1. Overview${RESET}
   Diosix-wm supports two seamless methods to display Debian desktop applications:
   - ${BOLD}Step 1: Rooted Desktop Window${RESET}:
     A native window in diosix-wm runs a lightweight RFB/VNC client connected to
     10.0.3.2:5900. It features RISC OS titlebars, close box, toggle box, and
     interactive scrollbars with sausage grips.
   - ${BOLD}Step 2: Seamless Application Windows${RESET}:
     Diosix-wm embeds a built-in Wayland compositor listening on TCP port 8484
     and /tmp/wayland-0. Any Wayland GUI app inside Debian displays as an independent
     native window on the desktop.

${BOLD}2. Disk Setup (Root VM)${RESET}
   Inside the Diosix Root VM (via terminal or SSH):
     # 1. Create a 4GB virtual disk:
     dsx disk create debian --size 4096

     # 2. Check disk status:
     dsx disk list

${BOLD}3. Booting the Debian Guest${RESET}
   Start the Debian VM with virtio-blk storage attached:
     dsx run default --name debian-vm --disk debian.img --ram 1024M --vcpus 2

${BOLD}4. Inside Debian Guest (via 'dsx ssh debian-vm')${RESET}
   # Install desktop packages and VNC server:
   apt update
   apt install -y xfce4 xfce4-terminal tigervnc-standalone-server socat

   # Step 1: Start VNC Desktop Session (RFB on :0 -> 5900)
   tigervncserver :0 -geometry 1024x768 -depth 24 -SecurityTypes None -localhost no

   The diosix-wm 'Debian Desktop' window will immediately connect and show the desktop!

   # Step 2: Start Wayland Seamless Windows Relay
   socat UNIX-LISTEN:/tmp/wayland-0,fork TCP:10.0.3.1:8484 &
   export WAYLAND_DISPLAY=wayland-0

   # Launch any Wayland application:
   foot &
   # The window instantly appears on the diosix-wm desktop as a native RISC OS window!

================================================================================
EOF
}

case "${1:-instructions}" in
    create)
        shift
        cmd_create "$@"
        ;;
    setup-rootfs)
        shift
        cmd_setup_rootfs "$@"
        ;;
    instructions)
        cmd_instructions
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
