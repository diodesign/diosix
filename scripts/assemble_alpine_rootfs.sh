#!/usr/bin/env bash
# Assemble an Alpine Linux riscv64 rootfs from Buildroot musl artifacts.
# Invoked via BR2_ROOTFS_POST_FAKEROOT_SCRIPT inside host-fakeroot.
#
# Usage: assemble_alpine_rootfs.sh <target_dir> <alpine_tar>
#                                  <overlay_common> <dynamic_overlay>
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

set -euo pipefail

TARGET_DIR="$1"
ALPINE_TAR="$2"
OVERLAY_COMMON="$3"
DYNAMIC_OVERLAY="$4"

if [ ! -f "$ALPINE_TAR" ]; then
    echo "Error: Missing Alpine minirootfs tarball '$ALPINE_TAR'" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/usr/local/sbin" "$STAGE/usr/local/bin" \
    "$STAGE/usr/local/lib" "$STAGE/preserve"

copy_tool() {
    local name="$1"
    local dest_dir="$2"
    local d cand
    for d in "$TARGET_DIR/sbin" "$TARGET_DIR/usr/sbin" \
             "$TARGET_DIR/bin" "$TARGET_DIR/usr/bin"; do
        cand="${d}/${name}"
        if [ -e "$cand" ] || [ -L "$cand" ]; then
            cp -L "$cand" "${dest_dir}/${name}"
            return 0
        fi
    done
    return 1
}

# Preserve kernel modules/firmware if Buildroot installed any.
for sub in lib/modules lib/firmware; do
    if [ -d "${TARGET_DIR}/${sub}" ]; then
        mkdir -p "$STAGE/preserve/$(dirname "$sub")"
        cp -a "${TARGET_DIR}/${sub}" "$STAGE/preserve/${sub}"
    fi
done

# Preserve xtables plugin modules used by xtables-legacy-multi (/usr/lib).
if [ -d "${TARGET_DIR}/usr/lib/xtables" ]; then
    cp -a "${TARGET_DIR}/usr/lib/xtables" "$STAGE/preserve/xtables"
fi

# Stage Buildroot musl utilities into /usr/local/{sbin,bin}.
if copy_tool "dropbear" "$STAGE/usr/local/sbin"; then
    ln -sf "dropbear" "$STAGE/usr/local/sbin/dropbearkey"
    ln -sf "../sbin/dropbear" "$STAGE/usr/local/bin/dropbearkey"
    ln -sf "../sbin/dropbear" "$STAGE/usr/local/bin/dbclient"
    ln -sf "../sbin/dropbear" "$STAGE/usr/local/bin/dropbearconvert"
fi
copy_tool "scp" "$STAGE/usr/local/bin" || true

if copy_tool "xtables-legacy-multi" "$STAGE/usr/local/sbin"; then
    for link in iptables iptables-save iptables-restore \
                iptables-legacy iptables-legacy-save iptables-legacy-restore; do
        ln -sf "xtables-legacy-multi" "$STAGE/usr/local/sbin/${link}"
    done
else
    for tool in iptables iptables-save iptables-restore; do
        copy_tool "$tool" "$STAGE/usr/local/sbin" || true
    done
fi

for tool in ip agetty sfdisk fdisk blkid losetup mkfs.vfat resize2fs; do
    copy_tool "$tool" "$STAGE/usr/local/sbin" || true
done
if copy_tool "mke2fs" "$STAGE/usr/local/sbin"; then
    ln -sf "mke2fs" "$STAGE/usr/local/sbin/mkfs.ext4"
else
    copy_tool "mkfs.ext4" "$STAGE/usr/local/sbin" || true
fi
if copy_tool "e2fsck" "$STAGE/usr/local/sbin"; then
    ln -sf "e2fsck" "$STAGE/usr/local/sbin/fsck.ext4"
else
    copy_tool "fsck.ext4" "$STAGE/usr/local/sbin" || true
fi
copy_tool "wget" "$STAGE/usr/local/bin" || true

# Stage required shared libraries from Buildroot into /usr/local/lib,
# keeping Alpine core libc/libcrypto/libssl/libz/libapk authoritative.
for libdir in "$TARGET_DIR/lib" "$TARGET_DIR/usr/lib"; do
    [ -d "$libdir" ] || continue
    for lib in "$libdir"/*.so*; do
        [ -e "$lib" ] || [ -L "$lib" ] || continue
        base="$(basename "$lib")"
        case "$base" in
            ld-musl*|libc.so*|libc.musl*|libcrypto*|libssl*|libz.so*|libapk*)
                continue
                ;;
        esac
        cp -a "$lib" "$STAGE/usr/local/lib/"
    done
done

# Replace Buildroot target tree with verified Alpine minirootfs.
find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -xzpf "$ALPINE_TAR" -C "$TARGET_DIR"

mkdir -p "$TARGET_DIR/dev" "$TARGET_DIR/usr/local/sbin" \
    "$TARGET_DIR/usr/local/bin" "$TARGET_DIR/usr/local/lib"
cp -a "$STAGE/usr/local/." "$TARGET_DIR/usr/local/"

if [ -d "$STAGE/preserve/lib/modules" ]; then
    mkdir -p "$TARGET_DIR/lib"
    cp -a "$STAGE/preserve/lib/modules" "$TARGET_DIR/lib/"
fi
if [ -d "$STAGE/preserve/lib/firmware" ]; then
    mkdir -p "$TARGET_DIR/lib"
    cp -a "$STAGE/preserve/lib/firmware" "$TARGET_DIR/lib/"
fi
if [ -d "$STAGE/preserve/xtables" ]; then
    mkdir -p "$TARGET_DIR/usr/lib"
    cp -a "$STAGE/preserve/xtables" "$TARGET_DIR/usr/lib/xtables"
fi

printf "/lib\n/usr/lib\n/usr/local/lib\n" \
    > "$TARGET_DIR/etc/ld-musl-riscv64.path"

cat <<'EOF' > "$TARGET_DIR/etc/fstab"
proc		/proc		proc	defaults	0	0
devpts		/dev/pts	devpts	defaults,gid=5,mode=620,ptmxmode=0666	0	0
tmpfs		/dev/shm	tmpfs	mode=1777	0	0
tmpfs		/tmp		tmpfs	mode=1777	0	0
tmpfs		/run		tmpfs	mode=0755,nosuid,nodev	0	0
sysfs		/sys		sysfs	defaults	0	0
EOF

cat <<'EOF' > "$TARGET_DIR/etc/inittab"
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/mkdir -p /dev/pts /dev/shm /run/lock/subsys
::sysinit:/bin/mount -a
null::sysinit:/bin/ln -sf /proc/self/fd /dev/fd
null::sysinit:/bin/ln -sf /proc/self/fd/0 /dev/stdin
null::sysinit:/bin/ln -sf /proc/self/fd/1 /dev/stdout
null::sysinit:/bin/ln -sf /proc/self/fd/2 /dev/stderr
::sysinit:/bin/hostname -F /etc/hostname
::sysinit:/etc/init.d/rcS

hvc0::respawn:/sbin/getty -L hvc0 0 vt100

::shutdown:/etc/init.d/rcK
::shutdown:/bin/umount -a -r
EOF

mkdir -p "$TARGET_DIR/etc/init.d"
cat <<'EOF' > "$TARGET_DIR/etc/init.d/rcS"
#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
for i in /etc/init.d/S??*; do
    [ ! -f "$i" ] && continue
    case "$i" in
        *.sh) (trap - INT QUIT TSTP; set start; . "$i") ;;
        *) "$i" start ;;
    esac
done
EOF
chmod 0755 "$TARGET_DIR/etc/init.d/rcS"

cat <<'EOF' > "$TARGET_DIR/etc/init.d/rcK"
#!/bin/sh
for i in $(ls -r /etc/init.d/S??* 2>/dev/null); do
    [ ! -f "$i" ] && continue
    case "$i" in
        *.sh) (trap - INT QUIT TSTP; set stop; . "$i") ;;
        *) "$i" stop ;;
    esac
done
EOF
chmod 0755 "$TARGET_DIR/etc/init.d/rcK"

echo "diosix-node" > "$TARGET_DIR/etc/hostname"
printf "root::0:0:99999:7:::\nagent:!:0:0:99999:7:::\n" \
    > "$TARGET_DIR/etc/shadow"
chmod 0600 "$TARGET_DIR/etc/shadow"
printf "console\nhvc0\nttyS0\ntty1\n" > "$TARGET_DIR/etc/securetty"
chmod 0644 "$TARGET_DIR/etc/securetty"

# Apply Diosix common overlay and cross-compiled Zig dynamic overlay.
cp -a "${OVERLAY_COMMON}/." "$TARGET_DIR/"
cp -a "${DYNAMIC_OVERLAY}/." "$TARGET_DIR/"
chmod 0700 "$TARGET_DIR/etc/diosix/keys" 2>/dev/null || true
chmod 0755 "$TARGET_DIR"/etc/init.d/S* 2>/dev/null || true
chmod 0755 "$TARGET_DIR/usr/sbin/diosix-agent-start" 2>/dev/null || true
