#!/usr/bin/env bash
#
# test_hardware_keys.sh: Helper and diagnostic utility for testing virtual
# and physical hardware keys (TPM 2.0 and FIDO2/U2F) in Diosix under QEMU.
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT
#

set -eo pipefail

BOLD="$(printf '\033[1m')"
DIM="$(printf '\033[2m')"
GREEN="$(printf '\033[32m')"
BLUE="$(printf '\033[34m')"
YELLOW="$(printf '\033[33m')"
RED="$(printf '\033[31m')"
CYAN="$(printf '\033[36m')"
RESET="$(printf '\033[0m')"

log_info() { echo -e "${BLUE}==>${RESET} ${BOLD}$1${RESET}"; }
log_ok()   { echo -e "${GREEN}  ✓${RESET} $1"; }
log_warn() { echo -e "${YELLOW}  !${RESET} $1"; }
log_err()  { echo -e "${RED}  ✗${RESET} $1"; }

usage() {
    cat <<EOF
${BOLD}Diosix Hardware Key Testing Utility${RESET}

Automates testing with virtual TPM 2.0 (swtpm) and physical/virtual FIDO2 keys.

${BOLD}Usage:${RESET}
  $0 [command]

${BOLD}Commands:${RESET}
  ${CYAN}tpm-start${RESET}       Launch virtual TPM 2.0 emulator (swtpm)
  ${CYAN}tpm-status${RESET}      Check virtual TPM 2.0 status and socket health
  ${CYAN}tpm-stop${RESET}        Stop running virtual TPM 2.0 emulator
  ${CYAN}run-tpm${RESET}         Launch Diosix GUI with virtual TPM 2.0 attached
  ${CYAN}scan-usb${RESET}        Scan host for FIDO2/U2F keys and print flags
  ${CYAN}guide${RESET}           Show guest verification and testing commands
  ${CYAN}clean${RESET}           Stop daemon and purge /tmp/diosix-tpm

EOF
}

cmd_tpm_start() {
    ./scripts/setup_swtpm.sh start
}

cmd_tpm_status() {
    ./scripts/setup_swtpm.sh status
}

cmd_tpm_stop() {
    ./scripts/setup_swtpm.sh stop
}

cmd_clean() {
    ./scripts/setup_swtpm.sh clean
}

cmd_run_tpm() {
    log_info "Launching Diosix GUI with virtual TPM 2.0..."
    ./scripts/build.sh run-tpm
}

cmd_scan_usb() {
    log_info "Scanning host USB devices for hardware security keys..."
    if ! command -v lsusb >/dev/null 2>&1; then
        log_warn "'lsusb' not found. Scanning /sys/bus/usb/devices..."
        for dev in /sys/bus/usb/devices/*; do
            if [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ]; then
                local vid pid prod
                vid=$(cat "$dev/idVendor")
                pid=$(cat "$dev/idProduct")
                prod=$(cat "$dev/product" 2>/dev/null || echo "Unknown")
                echo "    Found USB: ${vid}:${pid} - $prod"
            fi
        done
        return 0
    fi

    local found=0
    local pat="yubico|yubikey|fido|nitrokey|solo|feitian|titan|security key"
    while IFS= read -r line; do
        if echo "$line" | grep -iE "$pat" >/dev/null; then
            found=1
            local id
            id=$(echo "$line" | \
                grep -oE "ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4}" | cut -d' ' -f2)
            log_ok "Detected Security Key: ${BOLD}$line${RESET}"
            echo -e "    ${DIM}->${RESET} To pass this key into Diosix, run:"
            local gui_cmd="./scripts/build.sh run-gui -Dusb-key=${id}"
            local tpm_cmd="./scripts/build.sh run-tpm -Dusb-key=${id}"
            echo -e "       ${CYAN}${gui_cmd}${RESET}"
            echo -e "       ${CYAN}${tpm_cmd}${RESET}"
        fi
    done < <(lsusb)

    if [ "$found" -eq 0 ]; then
        log_warn "No physical FIDO2/U2F keys detected automatically on USB bus."
        echo "    All connected USB devices:"
        lsusb | sed 's/^/      /'
        echo ""
        echo "    You can still pass any USB device by ID using:"
        echo "      ./scripts/build.sh run-gui -Dusb-key=VID:PID"
    fi
}

cmd_guide() {
    cat <<EOF
${BOLD}Hardware Key Verification Guide inside Diosix Root VM${RESET}

${BOLD}1. Testing Virtual TPM 2.0 (/dev/tpm0):${RESET}
   # Verify kernel driver detected the TIS TPM:
   dmesg | grep -i tpm

   # Check capabilities:
   tpm2_getcap properties-fixed | head -n 15

   # Seal a secret against a PIN:
   tpm2_createprimary -C o -c primary.ctx
   echo "secret-authorized-by-pin" | \
       tpm2_create -C primary.ctx -u key.pub -r key.priv -i - -p "123456"
   tpm2_load -C primary.ctx -u key.pub -r key.priv -c key.ctx

   # Unsealing with incorrect PIN will fail (TPM2_RC_AUTH_FAIL):
   tpm2_unseal -c key.ctx -p "wrong"

   # Unsealing with correct PIN will succeed:
   tpm2_unseal -c key.ctx -p "123456"

${BOLD}2. Testing FIDO2 / U2F USB Keys (/dev/hidraw*):${RESET}
   # Verify key attached over USB XHCI:
   lsusb
   dmesg | grep -i hid

   # Check FIDO token information:
   fido2-token -I /dev/hidraw0

EOF
}

case "${1:-guide}" in
    tpm-start)
        cmd_tpm_start
        ;;
    tpm-status)
        cmd_tpm_status
        ;;
    tpm-stop)
        cmd_tpm_stop
        ;;
    run-tpm)
        cmd_run_tpm
        ;;
    scan-usb)
        cmd_scan_usb
        ;;
    guide)
        cmd_guide
        ;;
    clean)
        cmd_clean
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $1."
        usage
        exit 1
        ;;
esac
