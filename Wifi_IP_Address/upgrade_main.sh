#!/bin/sh
# shellcheck shell=sh disable=SC3043
#
# auto_timezone.sh - Detect the time zone from the public IP address when
#                    WiFi is connected, and apply it to the device.
#
# Usage:  sh auto_timezone.sh [options]
#   (no options)   wait for WiFi, detect once, apply, exit
#   --daemon       keep running; re-detect every time WiFi (re)connects
#   --dry-run      only print the detected zone, do not change anything
#   --iface NAME   WiFi interface (default: auto-detect, falls back to wlan0)
#   --sync-time    also sync the clock via NTP after applying
#   --no-reboot    apply the zone but do NOT reboot the device
#
# By default the device is REBOOTED right after the time zone was actually
# changed (so every process starts with the new zone) and the script exits.
# If the zone is already correct, nothing happens and no reboot is done.
# Loop protection: it reboots at most once per target zone (see
# REBOOT_STATE_FILE); if the change does not survive a reboot it will not
# keep rebooting.
#
# Exit codes: 0 ok, 1 error, 2 no WiFi / no IP within the wait time
#
# How it works:
#   1. Find the wireless interface and wait until it has an IPv4 address.
#   2. Ask public IP-geolocation services for the time zone of our public IP
#      (tries several providers, curl or wget).
#   3. Validate the answer, then set /etc/localtime (or a POSIX TZ rule when
#      tzdata is not installed on the device).
#

unset TZ

SCRIPT_NAME="$(basename "$0")"

### ------------------------------------------------------------------
### Configuration
### ------------------------------------------------------------------

ETC_DIR="${ETC_DIR:-/etc}"
ZONEINFO_DIR="${ZONEINFO_DIR:-/usr/share/zoneinfo}"
TZ_LOG_FILE="${TZ_LOG_FILE:-/userdata/das_rv1126b_app/logs/timezone.log}"
PID_FILE="${PID_FILE:-/tmp/auto_timezone.pid}"

IFACE=""                 # empty = auto-detect
WAIT_WIFI_SECS="${WAIT_WIFI_SECS:-60}"  # once-mode: how long to wait for WiFi to get an IP
LOOKUP_ATTEMPTS="${LOOKUP_ATTEMPTS:-3}"  # once-mode: retries of the IP lookup
LOOKUP_RETRY_DELAY="${LOOKUP_RETRY_DELAY:-5}"  # seconds between retries
POLL_INTERVAL="${POLL_INTERVAL:-10}"  # daemon-mode: WiFi state polling interval
DAEMON_RETRY_DELAY="${DAEMON_RETRY_DELAY:-60}"  # daemon-mode: wait after a failed lookup
HTTP_TIMEOUT="${HTTP_TIMEOUT:-8}"
USER_AGENT="Mozilla/5.0 (X11; Linux) auto_timezone"
NTP_SERVER="pool.ntp.org"

# Providers, tried in order. Each must return the IANA zone name as plain text.
# HTTPS first; plain-HTTP ip-api.com last because BusyBox wget often lacks TLS.
PROVIDERS="https://ipapi.co/timezone
https://ipinfo.io/timezone
http://ip-api.com/line/?fields=timezone"

REBOOT_AFTER_CHANGE="${REBOOT_AFTER_CHANGE:-1}"  # 1=reboot after the zone changed, 0=never
REBOOT_DELAY="${REBOOT_DELAY:-3}"                # seconds before rebooting
REBOOT_STATE_FILE="${REBOOT_STATE_FILE:-/userdata/das_rv1126b_app/configs/timezone_reboot.state}"

MODE="once"
DRY_RUN=0
SYNC_TIME=0
REMOUNTED_RO=0

### ------------------------------------------------------------------
### Logging (same format as upgrade_main.sh)
### ------------------------------------------------------------------

log() {
    local level="$1"
    shift
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] [${level}] $*"
    printf '%s\n' "${line}"
    mkdir -p "$(dirname "${TZ_LOG_FILE}")" 2>/dev/null
    printf '%s\n' "${line}" >> "${TZ_LOG_FILE}" 2>/dev/null
}

### ------------------------------------------------------------------
### WiFi detection
### ------------------------------------------------------------------

find_wifi_iface() {
    if [ -n "${IFACE}" ]; then
        printf '%s\n' "${IFACE}"
        return 0
    fi
    local d
    for d in /sys/class/net/*; do
        if [ -d "${d}/wireless" ] || [ -d "${d}/phy80211" ]; then
            basename "${d}"
            return 0
        fi
    done
    # Some drivers do not expose the wireless sysfs entries
    if [ -d /sys/class/net/wlan0 ]; then
        printf '%s\n' "wlan0"
        return 0
    fi
    return 1
}

iface_ipv4() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 addr show dev "$1" 2>/dev/null \
            | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
    fi
    if [ -z "${ip}" ] && command -v ifconfig >/dev/null 2>&1; then
        ip="$(ifconfig "$1" 2>/dev/null \
            | awk '/inet addr:/{sub("addr:","",$2); print $2; exit} /inet /{print $2; exit}')"
    fi
    case "${ip}" in
        169.254.*) ip="" ;;   # link-local, DHCP not finished
    esac
    printf '%s\n' "${ip}"
}

wifi_ssid() {
    if command -v wpa_cli >/dev/null 2>&1; then
        wpa_cli -i "$1" status 2>/dev/null | sed -n 's/^ssid=//p' | head -n 1
    elif command -v iw >/dev/null 2>&1; then
        iw dev "$1" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1
    fi
}

wait_for_wifi_ip() {
    local waited=0 iface ip
    while [ "${waited}" -lt "${WAIT_WIFI_SECS}" ]; do
        iface="$(find_wifi_iface)"
        if [ -n "${iface}" ]; then
            ip="$(iface_ipv4 "${iface}")"
            if [ -n "${ip}" ]; then
                log INFO "WiFi up: ${iface} has IP ${ip}"
                return 0
            fi
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

### ------------------------------------------------------------------
### IP -> time zone lookup
### ------------------------------------------------------------------

http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m "${HTTP_TIMEOUT}" -A "${USER_AGENT}" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T "${HTTP_TIMEOUT}" -U "${USER_AGENT}" -O - "$1" 2>/dev/null
    else
        return 127
    fi
}

# Accept only "Area/Location" style names with safe characters. The value comes
# from the network and is used to build a file path, so be strict.
valid_tz_name() {
    case "$1" in
        ""|/*|*..*|*[!A-Za-z0-9_/+-]*) return 1 ;;
        */*) return 0 ;;
        UTC) return 0 ;;
        *) return 1 ;;
    esac
}

# POSIX TZ rules for when the device has no zoneinfo database
posix_for_zone() {
    case "$1" in
        America/Los_Angeles|America/Vancouver|US/Pacific) echo "PST8PDT,M3.2.0,M11.1.0" ;;
        America/Denver|America/Edmonton|US/Mountain)      echo "MST7MDT,M3.2.0,M11.1.0" ;;
        America/Phoenix)                                  echo "MST7" ;;
        America/Chicago|America/Winnipeg|US/Central)      echo "CST6CDT,M3.2.0,M11.1.0" ;;
        America/New_York|America/Toronto|US/Eastern)      echo "EST5EDT,M3.2.0,M11.1.0" ;;
        America/Anchorage)                                echo "AKST9AKDT,M3.2.0,M11.1.0" ;;
        Pacific/Honolulu)                                 echo "HST10" ;;
        Asia/Shanghai|Asia/Taipei|Asia/Chongqing)         echo "CST-8" ;;
        Asia/Hong_Kong)                                   echo "HKT-8" ;;
        Asia/Tokyo)                                       echo "JST-9" ;;
        UTC)                                              echo "UTC0" ;;
        *) echo "" ;;
    esac
}

lookup_timezone() {
    local url reply
    for url in ${PROVIDERS}; do
        reply="$(http_get "${url}" | tr -d '\r ' | head -n 1)"
        if valid_tz_name "${reply}"; then
            log INFO "Detected ${reply} (via ${url})" >&2
            printf '%s\n' "${reply}"
            return 0
        fi
        log WARN "No usable answer from ${url}" >&2
    done
    return 1
}

### ------------------------------------------------------------------
### Applying the time zone
### ------------------------------------------------------------------

current_zone() {
    if [ -f "${ETC_DIR}/timezone" ]; then
        head -n 1 "${ETC_DIR}/timezone"
    elif [ -L "${ETC_DIR}/localtime" ]; then
        readlink "${ETC_DIR}/localtime" | sed "s|^.*zoneinfo/||"
    fi
}

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

sync_clock() {
    log INFO "Syncing system clock via NTP (${NTP_SERVER})"
    if command -v ntpd >/dev/null 2>&1; then
        ntpd -q -n -p "${NTP_SERVER}" >/dev/null 2>&1 \
            && log INFO "NTP sync OK" || log WARN "NTP sync failed"
    elif command -v ntpdate >/dev/null 2>&1; then
        ntpdate "${NTP_SERVER}" >/dev/null 2>&1 \
            && log INFO "NTP sync OK" || log WARN "NTP sync failed"
    else
        log WARN "No ntpd/ntpdate found, skipping clock sync"
    fi
}

apply_timezone() {
    local name="$1"
    local posix
    posix="$(posix_for_zone "${name}")"

    local have_zoneinfo=0
    [ -f "${ZONEINFO_DIR}/${name}" ] && have_zoneinfo=1

    if [ "${have_zoneinfo}" -eq 0 ] && [ -z "${posix}" ]; then
        log ERROR "${name}: not in ${ZONEINFO_DIR} and no built-in fallback rule; install tzdata"
        return 1
    fi

    make_etc_writable || {
        log ERROR "Cannot write to ${ETC_DIR}"
        return 1
    }

    local rc=0
    printf '%s\n' "${name}" > "${ETC_DIR}/timezone" || rc=1

    if [ "${have_zoneinfo}" -eq 1 ]; then
        ln -sf "${ZONEINFO_DIR}/${name}" "${ETC_DIR}/localtime" || rc=1
    else
        log WARN "zoneinfo missing for ${name}, using POSIX TZ rule only"
    fi

    # Keep /etc/TZ and profile.d in step with the chosen zone (remove stale ones)
    if [ -n "${posix}" ]; then
        printf '%s\n' "${posix}" > "${ETC_DIR}/TZ" || rc=1
        if [ -d "${ETC_DIR}/profile.d" ]; then
            printf "export TZ='%s'\n" "${posix}" > "${ETC_DIR}/profile.d/timezone.sh" || rc=1
        fi
    else
        rm -f "${ETC_DIR}/TZ" "${ETC_DIR}/profile.d/timezone.sh"
    fi

    sync
    restore_etc_ro
    return ${rc}
}

reboot_device() {
    log INFO "Rebooting in ${REBOOT_DELAY}s to apply the new time zone..."
    local n="${REBOOT_DELAY}"
    while [ "${n}" -gt 0 ]; do
        sleep 1
        n=$((n - 1))
    done

    sync
    if command -v reboot >/dev/null 2>&1; then
        reboot
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    else
        echo b > /proc/sysrq-trigger
    fi

    # Give the reboot time to take effect; never fall back into the polling loop
    sleep 10
    exit 0
}

# Reboot once per target zone. If we already rebooted for this zone and it is
# being applied again, the change is not persistent - do not reboot-loop.
maybe_reboot() {
    local zone="$1" last=""
    [ -f "${REBOOT_STATE_FILE}" ] && last="$(head -n 1 "${REBOOT_STATE_FILE}" 2>/dev/null)"

    if [ "${last}" = "${zone}" ]; then
        log WARN "Already rebooted once for ${zone} but it was applied again;"
        log WARN "the change probably does not persist across reboot (read-only/RAM /etc?). Not rebooting again."
        return 0
    fi

    mkdir -p "$(dirname "${REBOOT_STATE_FILE}")" 2>/dev/null
    printf '%s\n' "${zone}" > "${REBOOT_STATE_FILE}" 2>/dev/null \
        || log WARN "Cannot write ${REBOOT_STATE_FILE} (no loop protection)"
    reboot_device
}

update_timezone_from_ip() {
    local zone cur
    zone="$(lookup_timezone)" || return 1

    cur="$(current_zone)"
    if [ "${zone}" = "${cur}" ]; then
        log INFO "Time zone already ${zone}, nothing to do"
        return 0
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        log INFO "[dry-run] would change time zone: ${cur:-unknown} -> ${zone}"
        return 0
    fi

    log INFO "Changing time zone: ${cur:-unknown} -> ${zone}"
    apply_timezone "${zone}" || return 1
    log INFO "Local time now: $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
    [ "${SYNC_TIME}" -eq 1 ] && sync_clock
    [ "${REBOOT_AFTER_CHANGE}" = "1" ] && maybe_reboot "${zone}"
    return 0
}

### ------------------------------------------------------------------
### Run modes
### ------------------------------------------------------------------

run_once() {
    log INFO "Waiting up to ${WAIT_WIFI_SECS}s for WiFi..."
    if ! wait_for_wifi_ip; then
        log ERROR "WiFi not connected (no IPv4 address)"
        return 2
    fi

    local attempt=1
    while [ "${attempt}" -le "${LOOKUP_ATTEMPTS}" ]; do
        update_timezone_from_ip && return 0
        log WARN "Attempt ${attempt}/${LOOKUP_ATTEMPTS} failed"
        attempt=$((attempt + 1))
        [ "${attempt}" -le "${LOOKUP_ATTEMPTS}" ] && sleep "${LOOKUP_RETRY_DELAY}"
    done
    log ERROR "Could not determine/apply time zone"
    return 1
}

run_daemon() {
    if [ -f "${PID_FILE}" ]; then
        local old
        old="$(cat "${PID_FILE}" 2>/dev/null)"
        if [ -n "${old}" ] && kill -0 "${old}" 2>/dev/null; then
            log ERROR "Already running (PID ${old})"
            return 1
        fi
    fi
    echo "$$" > "${PID_FILE}"
    trap 'rm -f "${PID_FILE}"; exit 0' INT TERM
    trap 'rm -f "${PID_FILE}"' EXIT

    log INFO "Daemon started (PID $$), polling every ${POLL_INTERVAL}s"

    local last_sig="" iface ip sig
    while :; do
        iface="$(find_wifi_iface)"
        ip=""
        [ -n "${iface}" ] && ip="$(iface_ipv4 "${iface}")"

        if [ -n "${ip}" ]; then
            sig="$(wifi_ssid "${iface}")|${ip}"
            if [ "${sig}" != "${last_sig}" ]; then
                log INFO "WiFi connected: ${iface} ${sig}"
                if update_timezone_from_ip; then
                    last_sig="${sig}"
                else
                    log WARN "Lookup failed, retrying in ${DAEMON_RETRY_DELAY}s"
                    sleep "${DAEMON_RETRY_DELAY}"
                    continue
                fi
            fi
        else
            [ -n "${last_sig}" ] && log INFO "WiFi disconnected"
            last_sig=""
        fi
        sleep "${POLL_INTERVAL}"
    done
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --daemon)    MODE="daemon" ;;
            --once)      MODE="once" ;;
            --dry-run)   DRY_RUN=1 ;;
            --sync-time) SYNC_TIME=1 ;;
            --no-reboot) REBOOT_AFTER_CHANGE=0 ;;
            --reboot)    REBOOT_AFTER_CHANGE=1 ;;
            --iface)     shift; IFACE="$1" ;;
            -h|--help)   sed -n '3,22p' "$0"; exit 0 ;;
            *) log ERROR "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done

    [ "$(id -u 2>/dev/null)" = "0" ] || log WARN "Not running as root, writes may fail"

    if [ "${MODE}" = "daemon" ]; then
        run_daemon
    else
        run_once
    fi
    exit $?
}

main "$@"
