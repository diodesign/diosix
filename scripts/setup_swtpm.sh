#!/usr/bin/env bash
#
# setup_swtpm.sh: Provision and manage a virtual TPM 2.0 emulator (swtpm).
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

TPM_DIR="${DIOSIX_TPM_DIR:-/tmp/diosix-tpm}"
SOCK_PATH="${TPM_DIR}/swtpm-sock"
LOG_PATH="${TPM_DIR}/swtpm.log"
PID_FILE="${TPM_DIR}/swtpm.pid"

check_prereqs() {
    if ! command -v swtpm >/dev/null 2>&1; then
        log_err "'swtpm' is not installed on this host."
        echo "    Install with: sudo dnf install swtpm swtpm-tools (Fedora)"
        echo "              or: sudo apt install swtpm swtpm-tools (Debian)"
        exit 1
    fi
    if ! command -v swtpm_setup >/dev/null 2>&1; then
        log_err "'swtpm_setup' is missing. Please install swtpm-tools."
        exit 1
    fi
}

cmd_start() {
    check_prereqs
    mkdir -p "$TPM_DIR"

    # 1. Initialize TPM state if not already initialized.
    if [ ! -f "$TPM_DIR/tpm2-00.permall" ]; then
        log_info "Initializing virtual TPM 2.0 state in $TPM_DIR..."
        swtpm_setup --tpm2 --tpmstate "$TPM_DIR" \
            --create-spk >/dev/null 2>&1 || {
            log_err "Failed to initialize TPM 2.0 state via swtpm_setup."
            exit 1
        }
        log_ok "TPM 2.0 storage root key and PCR state initialized."
    fi

    # 2. Check if already running and socket responsive.
    if [ -S "$SOCK_PATH" ] && \
       pgrep -f "swtpm socket.*${TPM_DIR}" >/dev/null 2>&1; then
        log_ok "Virtual TPM 2.0 (swtpm) is already running at $SOCK_PATH."
        return 0
    fi

    # Clean stale socket file.
    rm -f "$SOCK_PATH" "$PID_FILE"

    # 3. Launch swtpm socket daemon.
    log_info "Starting swtpm socket daemon..."
    swtpm socket \
        --tpm2 \
        --tpmstate dir="$TPM_DIR" \
        --ctrl type=unixio,path="$SOCK_PATH" \
        --flags not-need-init \
        --pid file="$PID_FILE" \
        --log file="$LOG_PATH" &

    # 4. Wait for socket to become active.
    local tries=0
    while [ ! -S "$SOCK_PATH" ]; do
        sleep 0.1
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ]; then
            log_err "Timed out waiting for swtpm socket at $SOCK_PATH."
            [ -f "$LOG_PATH" ] && cat "$LOG_PATH"
            exit 1
        fi
    done

    log_ok "Virtual TPM 2.0 active and listening on $SOCK_PATH."
}

cmd_stop() {
    if pgrep -f "swtpm socket.*${TPM_DIR}" >/dev/null 2>&1; then
        log_info "Stopping virtual TPM 2.0 daemon..."
        pkill -f "swtpm socket.*${TPM_DIR}" || true
        rm -f "$SOCK_PATH" "$PID_FILE"
        log_ok "Virtual TPM 2.0 stopped."
    else
        log_info "Virtual TPM 2.0 is not running."
    fi
}

cmd_status() {
    if [ -S "$SOCK_PATH" ] && \
       pgrep -f "swtpm socket.*${TPM_DIR}" >/dev/null 2>&1; then
        local pid
        pid=$(pgrep -f "swtpm socket.*${TPM_DIR}" | head -n1)
        log_ok "Virtual TPM 2.0 is RUNNING (PID $pid, socket: $SOCK_PATH)."
    else
        log_warn "Virtual TPM 2.0 is STOPPED."
    fi
}

cmd_clean() {
    cmd_stop
    log_info "Purging virtual TPM 2.0 state directory ($TPM_DIR)..."
    rm -rf "$TPM_DIR"
    log_ok "TPM state directory purged."
}

case "${1:-start}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    clean)
        cmd_clean
        ;;
    help|--help|-h)
        echo "Usage: $0 [start|stop|status|clean]"
        ;;
    *)
        echo "Unknown command: $1. Run '$0 help' for usage."
        exit 1
        ;;
esac
