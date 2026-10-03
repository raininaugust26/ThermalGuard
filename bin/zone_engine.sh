#!/system/bin/sh
# ThermalGuard — zone engine
# Zone logic + hysteresis. POSIX sh only (Android mksh/toybox).
# Emits current zone name to stdout.

STATE_DIR="/data/adb/thermalguard/state"
CURRENT_ZONE_FILE="${STATE_DIR}/current_zone"
PREV_ZONE_FILE="${STATE_DIR}/prev_zone"
HISTORY_FILE="${STATE_DIR}/history.log"

ZONE_NORMAL="normal"
ZONE_PUSH="push"
ZONE_LIMIT="limit"
ZONE_CRITICAL="critical"

TG_PUSH_MAX="${TG_PUSH_MAX:-38}"
TG_LIMIT_MAX="${TG_LIMIT_MAX:-42}"
TG_CRITICAL_MAX="${TG_CRITICAL_MAX:-45}"
TG_HYSTERESIS="${TG_HYSTERESIS:-2}"

ABS_CPU_GPU_C=85
ABS_BATT_C=48

# zone_engine_resolve <device_temp_c> <cpu_die_temp_c> <batt_temp_c> [gpu_die_temp_c]
# device_temp = battery/skin (zone thresholds)
# cpu_die / gpu_die / batt = absolute hard limits only
zone_engine_resolve() {
    dev_temp="$1"
    cpu_die="$2"
    batt_temp="$3"
    gpu_die="${4:-}"
    prev_zone=$(cat "${PREV_ZONE_FILE}" 2>/dev/null || echo "${ZONE_NORMAL}")

    # Absolute limits always force critical
    if [ -n "${cpu_die}" ] && [ "${cpu_die}" -ge "${ABS_CPU_GPU_C}" ]; then
        echo "${ZONE_CRITICAL}"
        return 0
    fi
    if [ -n "${gpu_die}" ] && [ "${gpu_die}" -ge "${ABS_CPU_GPU_C}" ]; then
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
    # Missing/invalid device sensor → critical (fail closed)
    if [ -z "${dev_temp}" ] || [ "${dev_temp}" = "0" ]; then
        echo "${ZONE_CRITICAL}"
        return 0
    fi

    # Hysteresis: stay in hotter zone until temp drops below threshold - hysteresis
    # POSIX if/elif — do NOT use bash-only ;;&
    crit_thresh=$(( TG_CRITICAL_MAX - TG_HYSTERESIS ))
    limit_thresh=$(( TG_LIMIT_MAX - TG_HYSTERESIS ))
    push_thresh=$(( TG_PUSH_MAX - TG_HYSTERESIS ))

    if [ "${prev_zone}" = "${ZONE_CRITICAL}" ] && [ "${dev_temp}" -ge "${crit_thresh}" ]; then
        echo "${ZONE_CRITICAL}"
        return 0
    fi
    if [ "${prev_zone}" = "${ZONE_LIMIT}" ] && [ "${dev_temp}" -ge "${limit_thresh}" ]; then
        echo "${ZONE_LIMIT}"
        return 0
    fi
    if [ "${prev_zone}" = "${ZONE_PUSH}" ] && [ "${dev_temp}" -ge "${push_thresh}" ]; then
        echo "${ZONE_PUSH}"
        return 0
    fi

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
    old="$1" new="$2" temp="$3" reason="$4"
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    echo "${ts} ${old} -> ${new} temp=${temp}C reason=${reason}" >> "${HISTORY_FILE}"
    if [ -f "${HISTORY_FILE}" ]; then
        lines=$(wc -l < "${HISTORY_FILE}" 2>/dev/null || echo 0)
        if [ "${lines}" -gt 500 ]; then
            tail -n 250 "${HISTORY_FILE}" > "${HISTORY_FILE}.tmp" 2>/dev/null && \
                mv "${HISTORY_FILE}.tmp" "${HISTORY_FILE}" 2>/dev/null
        fi
    fi
}

# zone_engine_set <new_zone>
zone_engine_set() {
    new_zone="$1"
    prev_zone=$(cat "${CURRENT_ZONE_FILE}" 2>/dev/null || echo "${ZONE_NORMAL}")
    echo "${new_zone}" > "${CURRENT_ZONE_FILE}"
    echo "${prev_zone}" > "${PREV_ZONE_FILE}"
}

zone_engine_get_current() {
    cat "${CURRENT_ZONE_FILE}" 2>/dev/null || echo "${ZONE_NORMAL}"
}

# Direct execution (not sourced)
case "${0}" in
    *zone_engine.sh)
        if [ $# -ge 1 ]; then
            ZONE=$(zone_engine_resolve "$1" "$2" "$3")
            zone_engine_set "${ZONE}"
            echo "${ZONE}"
        else
            zone_engine_get_current
        fi
        ;;
esac
