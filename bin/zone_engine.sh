#!/system/bin/sh
# ThermalGuard — zone engine
# Zone logic + hysteresis. Emits current zone name to stdout.

# Read current and previous zone from state file
STATE_DIR="/data/adb/thermalguard/state"
CURRENT_ZONE_FILE="${STATE_DIR}/current_zone"
PREV_ZONE_FILE="${STATE_DIR}/prev_zone"
LOCK_FILE="${STATE_DIR}/zone.lock"
HISTORY_FILE="${STATE_DIR}/history.log"
STATUS_FILE="/data/adb/thermalguard/status.json"

# Zone definitions (from profiles.json defaults; overridden at runtime)
ZONE_NORMAL="normal"
ZONE_PUSH="push"
ZONE_LIMIT="limit"
ZONE_CRITICAL="critical"

# Hysteresis: to leave a hotter zone, temp must drop by hysteresis_c below that zone's threshold
# Thresholds are read from config at runtime via $TG_PUSH_MAX, $TG_LIMIT_MAX
# Fallback defaults
TG_PUSH_MAX="${TG_PUSH_MAX:-38}"
TG_LIMIT_MAX="${TG_LIMIT_MAX:-42}"
TG_CRITICAL_MAX="${TG_CRITICAL_MAX:-45}"
TG_HYSTERESIS="${TG_HYSTERESIS:-2}"

# Absolute limits (cannot be overridden)
ABS_CPU_GPU_C=85
ABS_BATT_C=48

# zone_engine_resolve <device_temp_c> <cpu_die_temp_c> <batt_temp_c>
# Resolves current zone and prints it.
zone_engine_resolve() {
    local dev_temp="$1"
    local cpu_die="$2"
    local batt_temp="$3"
    local prev_zone current_zone
    local push_thresh limit_thresh crit_thresh

    # Read previous zone
    prev_zone=$(cat "${PREV_ZONE_FILE}" 2>/dev/null || echo "${ZONE_NORMAL}")

    # Absolute limits always force critical
    if [ -n "${cpu_die}" ] && [ "${cpu_die}" -ge "${ABS_CPU_GPU_C}" ]; then
        echo "${ZONE_CRITICAL}"
        return 0
    fi
    if [ -n "${batt_temp}" ] && [ "${batt_temp}" -ge "${ABS_BATT_C}" ]; then
        echo "${ZONE_CRITICAL}"
        return 0
    fi
    if [ -n "${dev_temp}" ] && [ "${dev_temp}" -ge "${TG_CRITICAL_MAX}" ]; then
        echo "${ZONE_CRITICAL}"
        return 0
    fi
    # Missing device temperature sensor → treat as critical (fail-safe)
    if [ -z "${dev_temp}" ] || [ "${dev_temp}" = "0" ]; then
        echo "${ZONE_CRITICAL}"
        return 0
    fi

    # Compute thresholds with hysteresis based on previous zone
    case "${prev_zone}" in
        "${ZONE_CRITICAL}")
            # Stay critical until temp drops below critical threshold minus hysteresis
            crit_thresh=$(( TG_CRITICAL_MAX - TG_HYSTERESIS ))
            if [ "${dev_temp}" -ge "${crit_thresh}" ]; then
                echo "${ZONE_CRITICAL}"
                return 0
            fi
            ;;&
        "${ZONE_LIMIT}")
            # To leave limit zone, must drop below limit threshold minus hysteresis
            limit_thresh=$(( TG_LIMIT_MAX - TG_HYSTERESIS ))
            if [ "${dev_temp}" -ge "${limit_thresh}" ]; then
                echo "${ZONE_LIMIT}"
                return 0
            fi
            ;;&
        "${ZONE_PUSH}")
            # To leave push zone, must drop below push threshold minus hysteresis
            push_thresh=$(( TG_PUSH_MAX - TG_HYSTERESIS ))
            if [ "${dev_temp}" -ge "${push_thresh}" ]; then
                echo "${ZONE_PUSH}"
                return 0
            fi
            ;;
    esac

    # Hysteresis did not hold us in a hotter zone — resolve by absolute thresholds
    if [ "${dev_temp}" -ge "${TG_LIMIT_MAX}" ]; then
        echo "${ZONE_LIMIT}"
    elif [ "${dev_temp}" -ge "${TG_PUSH_MAX}" ]; then
        echo "${ZONE_PUSH}"
    else
        echo "${ZONE_NORMAL}"
    fi
}

# zone_engine_log <old_zone> <new_zone> <temp_c> <reason>
zone_engine_log() {
    local old="$1" new="$2" temp="$3" reason="$4"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    echo "${ts} ${old} -> ${new} temp=${temp}C reason=${reason}" >> "${HISTORY_FILE}"
    # Keep history bounded (last 500 lines)
    if [ -f "${HISTORY_FILE}" ]; then
        local lines
        lines=$(wc -l < "${HISTORY_FILE}" 2>/dev/null || echo 0)
        if [ "${lines}" -gt 500 ]; then
            tail -n 250 "${HISTORY_FILE}" > "${HISTORY_FILE}.tmp" 2>/dev/null && \
                mv "${HISTORY_FILE}.tmp" "${HISTORY_FILE}" 2>/dev/null
        fi
    fi
}

# zone_engine_set <new_zone>
zone_engine_set() {
    local new_zone="$1"
    local prev_zone
    prev_zone=$(cat "${CURRENT_ZONE_FILE}" 2>/dev/null || echo "${ZONE_NORMAL}")
    echo "${new_zone}" > "${CURRENT_ZONE_FILE}"
    echo "${prev_zone}" > "${PREV_ZONE_FILE}"
}

# zone_engine_get_current
zone_engine_get_current() {
    cat "${CURRENT_ZONE_FILE}" 2>/dev/null || echo "${ZONE_NORMAL}"
}

# Export functions for sourcing
# When executed directly: resolve zone from temp args
if [ "${0}" = "${BASH_SOURCE[0]}" ] || [ -z "${BASH_SOURCE[0]}" ]; then
    # Direct execution mode
    if [ $# -ge 1 ]; then
        ZONE=$(zone_engine_resolve "$1" "$2" "$3")
        zone_engine_set "${ZONE}"
        echo "${ZONE}"
    else
        zone_engine_get_current
    fi
fi
