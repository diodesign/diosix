#!/usr/bin/env bash
# Shared logging, kernel driver injection, and progress monitor for Buildroot.
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

log_banner() {
    echo -e "${BOLD}${BLUE}=== Diosix ${1:-Guest VM} build pipeline ===${RESET}"
}

log_step() {
    echo -e "${BOLD}${CYAN}==>${RESET} ${BOLD}$1${RESET}"
}

log_info() {
    echo -e "    ${DIM}->${RESET} $1"
}

log_ok() {
    echo -e "    ${GREEN}✓${RESET} $1"
}

log_warn() {
    echo -e "    ${YELLOW}!${RESET} $1"
}

log_err() {
    echo -e "    ${RED}✗${RESET} $1"
}

inject_diosix_driver() {
    local br_dir="$1"
    local wget_args="$2"

    if ! ls -d "$br_dir"/output/build/linux-[0-9]* >/dev/null 2>&1; then
        eval make -C "$br_dir" -j"$(nproc)" \
            linux-patch $wget_args >/dev/null 2>&1 || true
    fi

    local injected=0
    for linux_dir in "$br_dir"/output/build/linux-[0-9]*; do
        if [ -d "$linux_dir/drivers/char" ]; then
            mkdir -p "$linux_dir/drivers/char/diosix"
            rm -f "$linux_dir/drivers/char/diosix.c" \
                "$linux_dir/drivers/char/diosix.o"
            sed -i '/obj-y += diosix\.o/d' "$linux_dir/drivers/char/Makefile"
            local driver_changed=0
            local drv_objs=""
            for drv_path in tools/driver/*.[ch]; do
                local drv_src
                drv_src="$(basename "$drv_path")"
                if ! cmp -s "$drv_path" \
                    "$linux_dir/drivers/char/diosix/$drv_src" 2>/dev/null; then
                    driver_changed=1
                fi
                cp "$drv_path" "$linux_dir/drivers/char/diosix/$drv_src"
                case "$drv_src" in
                    *.c) drv_objs="$drv_objs ${drv_src%.c}.o" ;;
                esac
                if [ "$linux_dir/drivers/char/diosix/$drv_src" -nt \
                     "$linux_dir/.stamp_images_installed" ]; then
                    driver_changed=1
                fi
            done
            printf 'obj-y +=%s\n' "$drv_objs" \
                > "$linux_dir/drivers/char/diosix/Makefile"
            if ! grep -q "diosix/" "$linux_dir/drivers/char/Makefile"; then
                echo "obj-y += diosix/" >> "$linux_dir/drivers/char/Makefile"
                driver_changed=1
            fi
            if [ "$driver_changed" -eq 1 ]; then
                rm -f "$linux_dir/.stamp_built" \
                    "$linux_dir/.stamp_target_installed" \
                    "$linux_dir/.stamp_images_installed"
            fi
            injected=1
            log_ok "Installed /dev/diosix driver in $(basename "$linux_dir")."
        fi
    done

    if [ "$injected" -eq 0 ]; then
        log_err "Failed to unpack Linux kernel tree in $br_dir."
        return 1
    fi
}

run_buildroot_monitored() {
    local br_dir="$1"
    local wget_args="$2"
    local start_time="$3"

    local total_packages
    total_packages=$(make -s -C "$br_dir" show-targets 2>/dev/null | \
        tr '\n' ' ' | awk '{print NF}')
    if [ -z "$total_packages" ] || [ "$total_packages" -lt 1 ] 2>/dev/null; then
        total_packages=32
    fi

    local build_log="$br_dir/output/build/build-time.log"
    mkdir -p "$br_dir/output/build"
    local make_log="$br_dir/output/build/make_exec.log"

    cleanup_monitor() {
        printf "\r\033[K"
    }
    trap cleanup_monitor EXIT INT TERM

    eval make -C "$br_dir" -j"$(nproc)" \
        $wget_args > "$make_log" 2>&1 &
    local make_pid=$!

    local spin_chars=("⣾" "⣽" "⣻" "⢿" "⡿" "⣟" "⣯" "⣷")
    local spin_total=${#spin_chars[@]}
    local spin_idx=0
    local last_done=0
    local last_pkg_rep=""

    while kill -0 "$make_pid" 2>/dev/null; do
        local now_ts elapsed mins secs time_str
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_time))
        mins=$((elapsed / 60))
        secs=$((elapsed % 60))
        time_str=$(printf "%02d:%02d" "$mins" "$secs")

        local done_cnt=0
        local cur_pkg="toolchain"
        if [ -f "$build_log" ]; then
            done_cnt=$(grep -E ':end  :install-target' "$build_log" \
                2>/dev/null | wc -l | tr -dc '0-9' || echo "0")
            [ -z "$done_cnt" ] && done_cnt=0
            local latest_line
            latest_line=$(tail -n 1 "$build_log" 2>/dev/null || true)
            if [ -n "$latest_line" ]; then
                cur_pkg=$(echo "$latest_line" | awk -F':' '{print $NF}' \
                    | tr -d ' ' || echo "compiling")
            fi
        fi

        if [ "$done_cnt" -gt "$total_packages" ]; then
            total_packages=$done_cnt
        fi

        if [ "$done_cnt" -gt "$last_done" ]; then
            local last_pkg
            last_pkg=$(tail -n 2 "$build_log" 2>/dev/null | grep ':end  :' \
                | tail -n 1 | awk -F':' '{print $NF}' | tr -d ' ' || true)
            if [ -n "$last_pkg" ] && [ "$last_pkg" != "$last_pkg_rep" ]; then
                local pct=$(( (done_cnt * 100) / total_packages ))
                [ "$pct" -gt 99 ] && pct=99
                printf "\r\033[K    [%2d/%d] [%2d%%] ${GREEN}✓${RESET} %s\n" \
                    "$done_cnt" "$total_packages" "$pct" "$last_pkg"
                last_pkg_rep="$last_pkg"
            fi
            last_done="$done_cnt"
        fi

        local pct=0
        if [ "$total_packages" -gt 0 ]; then
            pct=$(( (done_cnt * 100) / total_packages ))
            [ "$pct" -gt 99 ] && pct=99
        fi

        local spin_char="${spin_chars[$spin_idx]}"
        spin_idx=$(( (spin_idx + 1) % spin_total ))

        local extra=""
        if [[ "$cur_pkg" =~ linux ]]; then
            local obj_count
            obj_count=$(find "$br_dir"/output/build/linux-* \
                -name "*.o" 2>/dev/null | wc -l | tr -dc '0-9' || echo "0")
            [ -z "$obj_count" ] && obj_count=0
            if [ -n "$obj_count" ] && [ "$obj_count" -gt 0 ] 2>/dev/null; then
                extra=" ($obj_count kernel objects)"
            fi
        fi

        local fmt="\r    ${CYAN}%s${RESET} [Elapsed: ${BOLD}%s${RESET}] "
        fmt="${fmt}[%2d/%d packages | %2d%%] Building ${BOLD}%s${RESET}%s\033[K"
        printf "$fmt" "$spin_char" "$time_str" \
            "$done_cnt" "$total_packages" "$pct" "$cur_pkg" "$extra"

        sleep 0.25
    done

    set +e
    wait "$make_pid"
    local rc=$?
    set -e

    printf "\r\033[K"

    if [ "$rc" -ne 0 ]; then
        echo -e "\n${BOLD}${RED}Error:${RESET} Buildroot failed ($rc)!"
        echo -e "Last 25 log lines:"
        tail -n 25 "$make_log" 2>/dev/null || true
        return "$rc"
    fi
}

stage_builtin_guest_images() {
    local kernel_elf="$1"
    local staging_dir="$2"

    mkdir -p "$staging_dir/images" "$staging_dir/manifests"
    if [ -f "$kernel_elf" ]; then
        local strip_tool="strip"
        local br_bin="zig-out/buildroot-riscv64/output/host/bin"
        local cli_bin="zig-out/buildroot-cli-riscv64/output/host/bin"
        for cand in riscv64-buildroot-linux-gnu-strip \
            riscv64-linux-gnu-strip llvm-strip \
            "${br_bin}/riscv64-buildroot-linux-gnu-strip" \
            "${cli_bin}/riscv64-linux-strip"; do
            if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
                strip_tool="$cand"
                break
            fi
        done

        "$strip_tool" -s "$kernel_elf" \
            -o "$staging_dir/images/diosix-node.elf" 2>/dev/null || \
            cp "$kernel_elf" "$staging_dir/images/diosix-node.elf"
        ln -sf diosix-node.elf "$staging_dir/images/default.elf"

        local kernel_dir
        kernel_dir="$(dirname "$kernel_elf")"
        for extra_elf in linux-cli.elf linux-desktop.elf; do
            if [ -f "${kernel_dir}/${extra_elf}" ]; then
                "$strip_tool" -s "${kernel_dir}/${extra_elf}" \
                    -o "$staging_dir/images/${extra_elf}" 2>/dev/null || \
                    cp "${kernel_dir}/${extra_elf}" \
                        "$staging_dir/images/${extra_elf}"
            fi
        done
    fi

    if [ -f "tools/overlay-common/etc/diosix/system.toml" ]; then
        cp "tools/overlay-common/etc/diosix/system.toml" \
            "$staging_dir/manifests/system.toml"
    fi

    local src_cat="tools/overlay-common/etc/diosix/catalog.toml"
    local dst_cat="$staging_dir/manifests/catalog.toml"
    if [ -f "$src_cat" ] && command -v sha256sum >/dev/null 2>&1; then
        local h_node="" h_cli="" h_desk=""
        if [ -f "$staging_dir/images/diosix-node.elf" ]; then
            h_node=$(sha256sum "$staging_dir/images/diosix-node.elf" \
                | awk '{print $1}')
        fi
        if [ -f "$staging_dir/images/linux-cli.elf" ]; then
            h_cli=$(sha256sum "$staging_dir/images/linux-cli.elf" \
                | awk '{print $1}')
        fi
        if [ -f "$staging_dir/images/linux-desktop.elf" ]; then
            h_desk=$(sha256sum "$staging_dir/images/linux-desktop.elf" \
                | awk '{print $1}')
        fi
        awk -v hn="$h_node" -v hc="$h_cli" -v hd="$h_desk" '
            /^url = "file:\/\/\/var\/lib\/diosix\/images\// {
                cur = ""
                if ($0 ~ /diosix-node\.elf"$/) cur = hn
                else if ($0 ~ /linux-cli\.elf"$/) cur = hc
                else if ($0 ~ /linux-desktop\.elf"$/) cur = hd
                print
                next
            }
            /^sha256 = "/ && cur != "" {
                printf "sha256 = \"%s\"\n", cur
                cur = ""
                next
            }
            /^\[\[image\]\]/ { cur = "" }
            { print }
        ' "$src_cat" > "$dst_cat"
    fi

    stage_alpine_apk_seed "$staging_dir"
}

stage_alpine_apk_seed() {
    local staging_dir="$1"
    local iso_dir="zig-out/dl"
    local iso_name="alpine-standard-3.24.3-riscv64.iso"
    local iso_path="${iso_dir}/${iso_name}"
    local site="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64"
    local iso_url="${site}/${iso_name}"
    local exp_sha
    exp_sha="0a98ca04017494e1a19f206d4934f743b13be863aa0ec155ec47b7ab06930025"

    mkdir -p "$iso_dir"
    if [ ! -f "$iso_path" ]; then
        log_info "Downloading ${iso_name} for offline APK repository..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$iso_url" -o "${iso_path}.part"
        else
            wget -q -O "${iso_path}.part" "$iso_url"
        fi
        mv -f "${iso_path}.part" "$iso_path"
    fi
    if ! printf "%s  %s\n" "$exp_sha" "$iso_path" | \
         sha256sum -c - >/dev/null 2>&1; then
        rm -f "$iso_path"
        log_err "SHA-256 verification failed for ${iso_name}."
        return 1
    fi
    if command -v python3 >/dev/null 2>&1 && \
       [ -f "scripts/extract_iso_apks.py" ]; then
        python3 -B "scripts/extract_iso_apks.py" "$iso_path" \
            "$staging_dir/apk/v3.24/main/riscv64"
    fi
}
