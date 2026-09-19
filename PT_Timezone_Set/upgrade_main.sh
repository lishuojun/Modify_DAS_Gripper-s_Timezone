#!/bin/sh
# shellcheck shell=sh disable=SC3043
#
# upgrade_main.sh (time-zone-only version)
# Sets the device time zone to US Pacific (America/Los_Angeles), once.
# Runs offline; needs no WiFi. Meant to be dropped in where the device
# launcher expects upgrade_main.sh.
#
# It follows the same outside contract as the full upgrade script:
#   * every log line goes to /mnt/sdcard/full_upgrade.log (same format)
#     and to /userdata/das_rv1126b_app/logs/timezone.log
#   * on failure it leaves upgrade_result.status (status=FAILED);
#     on success it removes that file (the full script does the same)
#   * reboots afterwards ONLY if the zone was actually changed
#
# Usage (normally started by the launcher with no arguments):
#   sh upgrade_main.sh [--no-reboot]
#
# Exit codes: 0 success (or already Pacific), 1 failure
#

unset TZ

### ------------------------------------------------------------------
### Configuration
### ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
START_TIME=$(date +%s)

TZ_NAME="America/Los_Angeles"
TZ_POSIX="PST8PDT,M3.2.0,M11.1.0"     # fallback rule when tzdata is missing

ETC_DIR="${ETC_DIR:-/etc}"
ZONEINFO_DIR="${ZONEINFO_DIR:-/usr/share/zoneinfo}"

UPGRADE_DIR="${UPGRADE_DIR:-/userdata/das_rv1126b_app/upgrade}"
STATUS_FILE="${STATUS_FILE:-${UPGRADE_DIR}/upgrade_result.status}"
SDCARD_LOG="${SDCARD_LOG:-/mnt/sdcard/full_upgrade.log}"
TZ_LOG_FILE="${TZ_LOG_FILE:-/userdata/das_rv1126b_app/logs/timezone.log}"

REBOOT_AFTER_UPGRADE=1
REBOOT_DELAY="${REBOOT_DELAY:-3}"

EXIT_CODE=0
ZONE_CHANGED=0
REMOUNTED_RO=0

### ------------------------------------------------------------------
### Logging: stdout + SD card log + /userdata log
### ------------------------------------------------------------------

log() {
    local level="$1"
    shift
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] [${level}] $*"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >> "${SDCARD_LOG}" 2>/dev/null
    mkdir -p "$(dirname "${TZ_LOG_FILE}")" 2>/dev/null
    printf '%s\n' "${line}" >> "${TZ_LOG_FILE}" 2>/dev/null
}

### ------------------------------------------------------------------
### Time zone helpers
### ------------------------------------------------------------------

make_etc_writable() {
    local probe="${ETC_DIR}/.tz_probe.$$"
    if touch "${probe}" 2>/dev/null; then
        rm -f "${probe}"
        return 0
    fi
    log WARN "${ETC_DIR} is read-only, trying to remount / read-write"
    if mount -o remount,rw / 2>/dev/null && touch "${probe}" 2>/dev/null; then
        rm -f "${probe}"
        REMOUNTED_RO=1
        return 0
    fi
    return 1
}

restore_etc_ro() {
    if [ "${REMOUNTED_RO}" = "1" ]; then
        mount -o remount,ro / 2>/dev/null
        REMOUNTED_RO=0
    fi
}

already_pacific() {
    [ "$(head -n 1 "${ETC_DIR}/timezone" 2>/dev/null)" = "${TZ_NAME}" ] || return 1
    [ -f "${ZONEINFO_DIR}/${TZ_NAME}" ] || return 0
    [ "$(readlink "${ETC_DIR}/localtime" 2>/dev/null)" = "${ZONEINFO_DIR}/${TZ_NAME}" ]
}

apply_timezone() {
    make_etc_writable || {
        log ERROR "Cannot write to ${ETC_DIR}"
        return 1
    }

    local rc=0
    printf '%s\n' "${TZ_NAME}" > "${ETC_DIR}/timezone" || rc=1

    if [ -f "${ZONEINFO_DIR}/${TZ_NAME}" ]; then
        ln -sf "${ZONEINFO_DIR}/${TZ_NAME}" "${ETC_DIR}/localtime" || rc=1
        log INFO "Linked ${ETC_DIR}/localtime -> ${ZONEINFO_DIR}/${TZ_NAME}"
    else
        log WARN "${ZONEINFO_DIR}/${TZ_NAME} not found (no tzdata), using POSIX TZ rule only"
    fi

    printf '%s\n' "${TZ_POSIX}" > "${ETC_DIR}/TZ" || rc=1
    if [ -d "${ETC_DIR}/profile.d" ]; then
        printf "export TZ='%s'\n" "${TZ_POSIX}" > "${ETC_DIR}/profile.d/timezone.sh" || rc=1
    fi

    sync
    restore_etc_ro
    return ${rc}
}

### ------------------------------------------------------------------
### Result reporting (mirrors the full upgrade script)
### ------------------------------------------------------------------

write_result() {
    local success="$1"
    local duration=$(( $(date +%s) - START_TIME ))

    if [ "${success}" -eq 1 ]; then
        rm -f "${STATUS_FILE}" 2>/dev/null
        log INFO "Final status: SUCCESS (exit code 0)"
        return 0
    fi

    log ERROR "Final status: FAILED (exit code ${EXIT_CODE})"
    mkdir -p "$(dirname "${STATUS_FILE}")" 2>/dev/null
    if cat > "${STATUS_FILE}" 2>/dev/null << STATUS_EOF
[upgrade_info]
upgrade_mode=timezone
target_timezone=${TZ_NAME}
duration_seconds=${duration}
status=FAILED
success=0
exit_code=${EXIT_CODE}
timestamp=$(date +%s)

[paths]
script_dir=${SCRIPT_DIR}
log_file=${SDCARD_LOG}
STATUS_EOF
    then
        log INFO "Status file saved: ${STATUS_FILE}"
    else
        log WARN "Failed to save status file: ${STATUS_FILE}"
    fi
}

reboot_device() {
    log INFO "Rebooting in ${REBOOT_DELAY}s to apply the new time zone..."
    sleep "${REBOOT_DELAY}"
    sync
    if command -v reboot >/dev/null 2>&1; then
        reboot
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    else
        echo b > /proc/sysrq-trigger
    fi
    sleep 10
}

### ------------------------------------------------------------------
### Main
### ------------------------------------------------------------------

main() {
    for arg in "$@"; do
        case "${arg}" in
            --no-reboot) REBOOT_AFTER_UPGRADE=0 ;;
            *) ;;   # the launcher may pass its own arguments; ignore them
        esac
    done

    trap 'log ERROR "Script interrupted by signal"; exit 1' INT TERM

    log INFO ""
    log INFO "=========================================="
    log INFO "Main upgrade script started (time-zone-only)"
    log INFO "=========================================="
    log INFO "Script path: $0"
    log INFO "Script directory: ${SCRIPT_DIR}"
    log INFO "Process PID: $$, user id: $(id -u 2>/dev/null)"
    log INFO "Target time zone: ${TZ_NAME}"
    if [ -d "$(dirname "${SDCARD_LOG}")" ]; then
        log INFO "SD card log: ${SDCARD_LOG}"
    else
        log WARN "$(dirname "${SDCARD_LOG}") not found - SD card not mounted? (log only in ${TZ_LOG_FILE})"
    fi
    log INFO "Before: $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"

    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        log WARN "Not running as root, writes may fail"
    fi

    if already_pacific; then
        log INFO "Time zone is already ${TZ_NAME}, nothing to do"
        write_result 1
        return 0
    fi

    if ! apply_timezone; then
        log ERROR "Failed to apply time zone"
        EXIT_CODE=1
        write_result 0
        return 1
    fi
    ZONE_CHANGED=1

    local now
    now="$(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
    log INFO "After:  ${now}"
    case "${now}" in
        *PST*|*PDT*) log INFO "Time zone is now Pacific" ;;
        *)
            log WARN "Shell does not report PST/PDT yet (tzdata missing or TZ not exported)"
            log WARN "It takes effect for the application after reboot"
            ;;
    esac

    write_result 1
    return 0
}

main "$@"
EXIT_CODE=$?

if [ "${EXIT_CODE}" -eq 0 ] && [ "${ZONE_CHANGED}" = "1" ] && [ "${REBOOT_AFTER_UPGRADE}" = "1" ]; then
    reboot_device
fi

exit "${EXIT_CODE}"