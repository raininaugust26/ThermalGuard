#!/system/bin/sh
# ThermalGuard — service.sh
# Main daemon: temperature monitor → zone engine → apply actions.
# Runs as a late_start service via Magisk/KernelSU/APatch.

# Never abort the daemon on a single command failure (Magisk may use -e)
set +e

TGDIR="/data/adb/thermalguard"
TG_BIN="${TGDIR}/bin"
TG_STATE="${TGDIR}/state"
TG_BACKUP="${TGDIR}/backup"
TG_LOGS="${TGDIR}/logs"
TG_CONFIG="${TGDIR}/config"
TG_SOC_CONF="${TGDIR}/soc_detected.conf"
STATUS_FILE="${TGDIR}/status.json"
HISTORY_FILE="${TG_STATE}/history.log"
DAEMON_LOG="${TG_LOGS}/daemon.log"
LOCKOUT_FILE="${TG_STATE}/lockout_until"
CURRENT_ZONE_FILE="${TG_STATE}/current_zone"
PREV_ZONE_FILE="${TG_STATE}/prev_zone"
SOC_ID_FILE="${TG_STATE}/soc_id"
BOOT_MARKER="${TG_STATE}/boot_marker"
TG_SAMSUNG_SAFE="false"
TG_FIRST_HEALTHY="0"
zone_ref_src="none"

# ─── Device safety profile ─────────────────────────────────────────
# Samsung OneUI thermal-engine is aggressive. Writing trip points or
# charging nodes too early can reboot/bootloop the device.
MFG=$(getprop ro.product.manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "${MFG}" in
    *samsung*)
        TG_SAMSUNG_SAFE="true"
        sleep 45
        ;;
    *)
        sleep 25
        ;;
esac

# ─── Load configuration ────────────────────────────────────────────
# Default thresholds
TG_PUSH_MAX=38
TG_LIMIT_MAX=42
TG_CRITICAL_MAX=45
TG_HYSTERESIS=2
TG_POLL_INTERVAL=2
TG_STEP_DOWN_PCT=5
TG_PROFILE="auto"
TG_CHARGING_MA_LIMIT=1500
TG_CHARGING_MA_SAVER=1000
TG_READ_ONLY=false

# Load profile JSON if jq is available, otherwise use defaults
load_profile() {
    local profile_name="$1"
    local profiles_json="${TG_CONFIG}/profiles.json"
    [ -f "${profiles_json}" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        TG_PUSH_MAX=$(jq -r ".defaults.profiles.${profile_name}.zones.push.max_temp_c // 38" "${profiles_json}" 2>/dev/null || echo 38)
        TG_LIMIT_MAX=$(jq -r ".defaults.profiles.${profile_name}.zones.limit.max_temp_c // 42" "${profiles_json}" 2>/dev/null || echo 42)
        TG_CRITICAL_MAX=$(jq -r ".defaults.profiles.${profile_name}.zones.critical.max_temp_c // 45" "${profiles_json}" 2>/dev/null || echo 45)
        TG_HYSTERESIS=$(jq -r ".defaults.hysteresis_c // 2" "${profiles_json}" 2>/dev/null || echo 2)
        TG_POLL_INTERVAL=$(jq -r ".defaults.poll_interval_sec // 2" "${profiles_json}" 2>/dev/null || echo 2)
        TG_STEP_DOWN_PCT=$(jq -r ".defaults.profiles.${profile_name}.zones.limit.step_down_pct // 5" "${profiles_json}" 2>/dev/null || echo 5)
        TG_CHARGING_MA_LIMIT=$(jq -r ".defaults.profiles.${profile_name}.zones.limit.charging_current_ma // 1500" "${profiles_json}" 2>/dev/null || echo 1500)
        TG_CHARGING_MA_SAVER=$(jq -r ".defaults.profiles.${profile_name}.zones.limit.charging_current_ma // 1000" "${profiles_json}" 2>/dev/null || echo 1000)
        TG_PROFILE="${profile_name}"
    else
        # Fallback: grep-based extraction (rough)
        TG_PUSH_MAX=38
        TG_LIMIT_MAX=42
        TG_CRITICAL_MAX=45
        TG_HYSTERESIS=2
        TG_POLL_INTERVAL=2
        TG_STEP_DOWN_PCT=5
        TG_PROFILE="auto"
    fi
    # Absolute limits are never overridden
    ABS_CPU_GPU_C=85
    ABS_BATT_C=48
}

# ─── Logging helper ────────────────────────────────────────────────
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    echo "${ts} $*" >> "${DAEMON_LOG}" 2>/dev/null
    # Keep daemon log bounded
    local lines
    lines=$(wc -l < "${DAEMON_LOG}" 2>/dev/null || echo 0)
    if [ "${lines}" -gt 1000 ]; then
        tail -n 500 "${DAEMON_LOG}" > "${DAEMON_LOG}.tmp" 2>/dev/null && \
            mv "${DAEMON_LOG}.tmp" "${DAEMON_LOG}" 2>/dev/null
    fi
}

# ─── Temperature reading ───────────────────────────────────────────
# read_temp_mc <path> — reads millidegrees, returns degrees (integer)
read_temp_mc() {
    local path="$1"
    if [ ! -f "${path}" ] || [ ! -r "${path}" ]; then
        echo ""
        return 1
    fi
    local raw
    raw=$(cat "${path}" 2>/dev/null)
    if [ -z "${raw}" ] || [ "${raw}" = "0" ]; then
        echo ""
        return 1
    fi
    # Values may be in millidegrees (e.g. 41200) or degrees (e.g. 41)
    if [ "${raw}" -gt 1000 ]; then
        echo $(( raw / 1000 ))
    else
        echo "${raw}"
    fi
}

# read_battery_temp — battery temp in °C (power_supply usually 0.1°C units)
read_battery_temp() {
    local path="${BATT_NODE:-/sys/class/power_supply/battery/temp}"
    if [ ! -f "${path}" ] || [ ! -r "${path}" ]; then
        # last-resort thermal zone
        local meta
        meta=$(find_thermal_zone_meta "${SOC_BATT_TYPE_REGEX}")
        path="${meta%%|*}"
        [ "${path}" = "${meta}" ] && path=""
        [ -n "${path}" ] && [ -f "${path}" ] || { echo ""; return 1; }
    fi
    local raw
    raw=$(cat "${path}" 2>/dev/null)
    if [ -z "${raw}" ]; then
        echo ""
        return 1
    fi
    case "${raw}" in
        *[!0-9-]*) echo ""; return 1 ;;
    esac
    # 0.1°C units (360=36.0) vs already °C vs millidegrees (36000)
    if [ "${raw}" -gt 10000 ]; then
        echo $(( raw / 1000 ))
    elif [ "${raw}" -gt 100 ]; then
        echo $(( raw / 10 ))
    else
        echo "${raw}"
    fi
}

# dump_thermal_zones → sensors.txt (for diagnostics / share logs)
dump_thermal_zones() {
    local out="${TGDIR}/logs/sensors.txt"
    {
        echo "=== ThermalGuard sensor dump ==="
        echo "date: $(date 2>/dev/null)"
        echo "soc_id: ${SOC_ID}"
        echo "soc_label: ${SOC_LABEL}"
        echo "manufacturer: ${MFG}"
        echo "samsung_safe: ${TG_SAMSUNG_SAFE}"
        echo "read_only: ${TG_READ_ONLY}"
        echo ""
        echo "--- thermal zones ---"
        for tz_dir in /sys/class/thermal/thermal_zone*; do
            [ -d "${tz_dir}" ] || continue
            echo "$(basename "${tz_dir}") type=$(cat "${tz_dir}/type" 2>/dev/null) temp=$(cat "${tz_dir}/temp" 2>/dev/null)"
        done
        echo ""
        echo "--- battery ---"
        for p in /sys/class/power_supply/battery/temp /sys/class/power_supply/battery/batt_temp; do
            [ -f "${p}" ] && echo "${p}=$(cat "${p}" 2>/dev/null)"
        done
        echo ""
        echo "--- cpu freq ---"
        for p in /sys/devices/system/cpu/cpufreq/policy*; do
            [ -d "${p}" ] || continue
            echo "$(basename "${p}") max=$(cat "${p}/scaling_max_freq" 2>/dev/null)"
        done
        echo ""
        echo "--- selected paths ---"
        echo "cpu=${CPU_TEMP_PATH:-none} (${CPU_TEMP_TYPE:-n/a})"
        echo "gpu=${GPU_TEMP_PATH:-none} (${GPU_TEMP_TYPE:-n/a})"
        echo "skin=${SKIN_TEMP_PATH:-none} (${SKIN_TEMP_TYPE:-n/a})"
        echo "battery_node=${BATT_NODE:-none}"
    } > "${out}" 2>/dev/null
}

# json_num <val> — force integer for JSON
json_num() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

# conf_val <file> <KEY> — read KEY=value, strip quotes (conf files use KEY="value")
conf_val() {
    grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//'
}

# find_hottest_zone <type_regex> — hottest matching zone → "path|type|temp_c"
# Used for multi-core CPU (cpu-1-0..3, cpuss-*) and GPU.
find_hottest_zone() {
    local type_regex="$1"
    local best_path="" best_type="" best_c=0
    local tz_dir tz_type raw c
    for tz_dir in /sys/class/thermal/thermal_zone*; do
        [ -d "${tz_dir}" ] || continue
        tz_type=$(cat "${tz_dir}/type" 2>/dev/null || echo "")
        [ -n "${tz_type}" ] || continue
        echo "${tz_type}" | grep -qiE "${type_regex}" || continue
        raw=$(cat "${tz_dir}/temp" 2>/dev/null || echo "")
        case "${raw}" in
            ''|*[!0-9-]*) c=0 ;;
            *)
                if [ "${raw}" -gt 1000 ]; then
                    c=$(( raw / 1000 ))
                else
                    c="${raw}"
                fi
                ;;
        esac
        # Accept plausible die/board temps; ignore garbage
        if [ "${c}" -ge 1 ] && [ "${c}" -le 119 ] && [ "${c}" -gt "${best_c}" ]; then
            best_c="${c}"
            best_path="${tz_dir}/temp"
            best_type="${tz_type}"
        fi
    done
    if [ -n "${best_path}" ]; then
        echo "${best_path}|${best_type}|${best_c}"
        return 0
    fi
    echo "||"
    return 1
}

# find_thermal_zone_meta <regex> — first plausible zone → "path|type"
find_thermal_zone_meta() {
    meta=$(find_hottest_zone "$1") || true
    path="${meta%%|*}"
    rest="${meta#*|}"
    type="${rest%%|*}"
    if [ -n "${path}" ]; then
        echo "${path}|${type}"
        return 0
    fi
    echo ""
    return 1
}

# ─── SoC config loading ────────────────────────────────────────────
SOC_ID="unknown"
SOC_LABEL=""
# Wide defaults (used if conf missing or values empty after quote strip)
SOC_CPU_TYPE_REGEX="cpu|tsens|cluster|core|cpuss|soc|msoc"
SOC_GPU_TYPE_REGEX="gpu|adreno|mali|kgsl"
SOC_SKIN_TYPE_REGEX="skin|quiet|case|back|pa_therm|shell|wifi"
SOC_BATT_TYPE_REGEX="battery|batt"
if [ -f "${SOC_ID_FILE}" ]; then
    SOC_ID=$(cat "${SOC_ID_FILE}" 2>/dev/null || echo "unknown")
fi
if [ -f "${TG_SOC_CONF}" ]; then
    conf_cpu=$(conf_val "${TG_SOC_CONF}" "THERMAL_TYPE_CPU")
    conf_gpu=$(conf_val "${TG_SOC_CONF}" "THERMAL_TYPE_GPU")
    conf_skin=$(conf_val "${TG_SOC_CONF}" "THERMAL_TYPE_SKIN")
    conf_batt=$(conf_val "${TG_SOC_CONF}" "THERMAL_TYPE_BATT")
    conf_label=$(conf_val "${TG_SOC_CONF}" "SOC_LABEL")
    [ -n "${conf_cpu}" ] && SOC_CPU_TYPE_REGEX="${conf_cpu}"
    [ -n "${conf_gpu}" ] && SOC_GPU_TYPE_REGEX="${conf_gpu}"
    [ -n "${conf_skin}" ] && SOC_SKIN_TYPE_REGEX="${conf_skin}"
    [ -n "${conf_batt}" ] && SOC_BATT_TYPE_REGEX="${conf_batt}"
    [ -n "${conf_label}" ] && SOC_LABEL="${conf_label}"
fi
SOC_LABEL=$(echo "${SOC_LABEL}" | sed 's/^"//;s/"$//')
if [ -z "${SOC_LABEL}" ]; then
    case "${SOC_ID}" in
        qcom) SOC_LABEL="Qualcomm Snapdragon" ;;
        mtk) SOC_LABEL="MediaTek" ;;
        exynos) SOC_LABEL="Samsung Exynos" ;;
        tensor) SOC_LABEL="Google Tensor" ;;
        *) SOC_LABEL="Unknown SoC" ;;
    esac
fi
if [ "${SOC_ID}" = "unknown" ]; then
    TG_READ_ONLY=true
fi

# Resolve sensor paths once
CPU_TEMP_PATH=""
CPU_TEMP_TYPE=""
GPU_TEMP_PATH=""
GPU_TEMP_TYPE=""
SKIN_TEMP_PATH=""
SKIN_TEMP_TYPE=""
BATT_NODE="/sys/class/power_supply/battery/temp"
if [ -f "${TG_SOC_CONF}" ]; then
    conf_batt_node=$(conf_val "${TG_SOC_CONF}" "BATTERY_TEMP_NODE")
    [ -n "${conf_batt_node}" ] && BATT_NODE="${conf_batt_node}"
fi

resolve_sensors() {
    # CPU: hottest among cpu-*/cpuss-*/tsens etc. (A05s: cpu-1-0..3, cpuss-0..2)
    meta=$(find_hottest_zone "${SOC_CPU_TYPE_REGEX}")
    CPU_TEMP_PATH="${meta%%|*}"
    _rest="${meta#*|}"
    CPU_TEMP_TYPE="${_rest%%|*}"
    [ -z "${CPU_TEMP_PATH}" ] && CPU_TEMP_TYPE=""

    # GPU: hottest matching zone (A05s: type=gpu)
    meta=$(find_hottest_zone "${SOC_GPU_TYPE_REGEX}")
    GPU_TEMP_PATH="${meta%%|*}"
    _rest="${meta#*|}"
    GPU_TEMP_TYPE="${_rest%%|*}"
    [ -z "${GPU_TEMP_PATH}" ] && GPU_TEMP_TYPE=""

    # Skin: prefer quiet-therm / skin-like
    meta=$(find_hottest_zone "${SOC_SKIN_TYPE_REGEX}")
    SKIN_TEMP_PATH="${meta%%|*}"
    _rest="${meta#*|}"
    SKIN_TEMP_TYPE="${_rest%%|*}"
    [ -z "${SKIN_TEMP_PATH}" ] && SKIN_TEMP_TYPE=""

    # Battery node fallbacks
    if [ ! -f "${BATT_NODE}" ]; then
        for p in /sys/class/power_supply/battery/temp /sys/class/power_supply/bms/temp; do
            [ -f "${p}" ] && BATT_NODE="${p}" && break
        done
    fi
}

# ─── Read/write helpers for sysfs ──────────────────────────────────
node_write() {
    local node="$1"
    local value="$2"
    if [ "${TG_READ_ONLY}" = "true" ]; then
        return 1
    fi
    if [ -e "${node}" ] && [ -w "${node}" ]; then
        echo "${value}" > "${node}" 2>/dev/null
        return $?
    fi
    return 1
}

# ─── Actions ───────────────────────────────────────────────────────
# action_none — do nothing (Normal zone)
action_none() {
    log "Zone=normal: no action"
}

# action_raise_trip — raise thermal trip thresholds slightly (Push zone)
action_raise_trip() {
    local offset_c="${1:-3}"
    local offset_mc=$(( offset_c * 1000 ))

    # Samsung: trip-point writes can panic thermal-engine → bootloop
    if [ "${TG_SAMSUNG_SAFE}" = "true" ]; then
        log "Samsung-safe: skip raise_trip"
        return 0
    fi

    if [ "${TG_READ_ONLY}" = "true" ]; then
        log "Read-only mode: skip raise_trip"
        return 0
    fi

    # Raise trip points for CPU thermal zones
    for trip_file in /sys/class/thermal/thermal_zone*/trip_point_*_temp; do
        [ -f "${trip_file}" ] || continue
        [ -w "${trip_file}" ] || continue
        local zone_dir zone_type
        zone_dir=$(dirname "${trip_file}")
        zone_type=$(cat "${zone_dir}/type" 2>/dev/null || echo "")
        if echo "${zone_type}" | grep -qiE "${SOC_CPU_TYPE_REGEX}|${SOC_GPU_TYPE_REGEX}"; then
            local current
            current=$(cat "${trip_file}" 2>/dev/null || echo "")
            if [ -n "${current}" ] && [ "${current}" -gt 0 ]; then
                local new_val=$(( current + offset_mc ))
                # Cap at absolute limit
                local abs_mc=$(( 85 * 1000 ))
                if [ "${new_val}" -gt "${abs_mc}" ]; then
                    new_val="${abs_mc}"
                fi
                node_write "${trip_file}" "${new_val}"
            fi
        fi
    done
    log "action_raise_trip: offset=+${offset_c}C"
}

# action_step_down — reduce max CPU/GPU frequency by percentage
action_step_down() {
    local pct="${1:-5}"

    if [ "${TG_READ_ONLY}" = "true" ]; then
        log "Read-only mode: skip step_down"
        return 0
    fi

    # CPU frequency step-down
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "${policy_dir}" ] || continue
        local max_node="${policy_dir}/scaling_max_freq"
        [ -f "${max_node}" ] || continue
        [ -w "${max_node}" ] || continue

        local current_max
        current_max=$(cat "${max_node}" 2>/dev/null || echo "")
        if [ -z "${current_max}" ] || [ "${current_max}" -le 0 ]; then
            continue
        fi

        # Do not go below 50% of original max
        local backup_file="${TG_BACKUP}/cpu_$(basename "${policy_dir}")_scaling_max_freq"
        local orig_max
        orig_max=$(cat "${backup_file}" 2>/dev/null || echo "${current_max}")
        local floor=$(( orig_max / 2 ))
        if [ "${floor}" -le 0 ]; then
            floor=500000
        fi

        local reduction=$(( current_max * pct / 100 ))
        local new_max=$(( current_max - reduction ))
        # Samsung-safe: never go below 70% of original
        if [ "${TG_SAMSUNG_SAFE}" = "true" ]; then
            local safe_floor=$(( orig_max * 70 / 100 ))
            if [ "${safe_floor}" -gt "${floor}" ]; then
                floor="${safe_floor}"
            fi
        fi
        if [ "${new_max}" -lt "${floor}" ]; then
            new_max="${floor}"
        fi
        # Round down to nearest MHz; reject empty/zero
        new_max=$(( (new_max / 1000) * 1000 ))
        if [ -n "${new_max}" ] && [ "${new_max}" -gt 0 ]; then
            node_write "${max_node}" "${new_max}"
        fi
    done

    # GPU frequency step-down (Adreno)
    local gpu_max_node="/sys/class/kgsl/kgsl-3d0/max_gpuclk"
    if [ -f "${gpu_max_node}" ] && [ -w "${gpu_max_node}" ]; then
        local gpu_current
        gpu_current=$(cat "${gpu_max_node}" 2>/dev/null || echo "")
        if [ -n "${gpu_current}" ] && [ "${gpu_current}" -gt 0 ]; then
            local gpu_backup="${TG_BACKUP}/gpu_max_gpuclk"
            local gpu_orig
            gpu_orig=$(cat "${gpu_backup}" 2>/dev/null || echo "${gpu_current}")
            local gpu_floor=$(( gpu_orig / 2 ))
            if [ "${gpu_floor}" -le 0 ]; then
                gpu_floor=200000000
            fi
            local gpu_reduction=$(( gpu_current * pct / 100 ))
            local gpu_new=$(( gpu_current - gpu_reduction ))
            if [ "${gpu_new}" -lt "${gpu_floor}" ]; then
                gpu_new="${gpu_floor}"
            fi
            node_write "${gpu_max_node}" "${gpu_new}"
        fi
    fi

    # GPU frequency step-down (devfreq/Mali)
    for devfreq_dir in /sys/class/devfreq/*mali* /sys/class/devfreq/*gpu*; do
        [ -d "${devfreq_dir}" ] || continue
        local df_max="${devfreq_dir}/max_freq"
        [ -f "${df_max}" ] || continue
        [ -w "${df_max}" ] || continue
        local df_current
        df_current=$(cat "${df_max}" 2>/dev/null || echo "")
        if [ -z "${df_current}" ] || [ "${df_current}" -le 0 ]; then
            continue
        fi
        local df_name
        df_name=$(basename "${devfreq_dir}")
        local df_backup="${TG_BACKUP}/gpu_devfreq_${df_name}_max_freq"
        local df_orig
        df_orig=$(cat "${df_backup}" 2>/dev/null || echo "${df_current}")
        local df_floor=$(( df_orig / 2 ))
        if [ "${df_floor}" -le 0 ]; then
            df_floor=200000000
        fi
        local df_reduction=$(( df_current * pct / 100 ))
        local df_new=$(( df_current - df_reduction ))
        if [ "${df_new}" -lt "${df_floor}" ]; then
            df_new="${df_floor}"
        fi
        node_write "${df_max}" "${df_new}"
    done

    log "action_step_down: pct=${pct}%"
}

# action_reduce_charging — lower charging current
action_reduce_charging() {
    local ma="${1:-1500}"

    # Samsung: charging node paths/units differ; writes can misbehave
    if [ "${TG_SAMSUNG_SAFE}" = "true" ]; then
        log "Samsung-safe: skip reduce_charging"
        return 0
    fi

    if [ "${TG_READ_ONLY}" = "true" ]; then
        log "Read-only mode: skip reduce_charging"
        return 0
    fi

    # Convert mA to µA for power_supply nodes
    local ua=$(( ma * 1000 ))

    for batt_dir in /sys/class/power_supply/*battery*; do
        [ -d "${batt_dir}" ] || continue
        local batt_name
        batt_name=$(basename "${batt_dir}")
        node_write "${batt_dir}/constant_charge_current_max" "${ua}"
        node_write "${batt_dir}/constant_charge_current" "${ua}"
    done

    # MTK-specific
    if [ -f "/sys/devices/platform/mt_battery/charging_current" ]; then
        node_write "/sys/devices/platform/mt_battery/charging_current" "${ma}"
    fi

    log "action_reduce_charging: ${ma}mA"
}

# action_throttle_background — limit background processes via cpuset
action_throttle_background() {
    if [ "${TG_READ_ONLY}" = "true" ]; then
        log "Read-only mode: skip throttle_background"
        return 0
    fi

    # Restrict background/restricted cpusets to fewer cores
    for cpuset_dir in /dev/cpuset/background /dev/cpuset/restricted; do
        [ -d "${cpuset_dir}" ] || continue
        local cpus_node="${cpuset_dir}/cpus"
        [ -w "${cpus_node}" ] || continue
        # Move background tasks to CPU 0-3 (little cores on most SoCs)
        node_write "${cpus_node}" "0-3"
    done

    log "action_throttle_background: cpuset restricted to 0-3"
}

# action_failsafe — emergency: restore all + lock
action_failsafe() {
    local reason="${1:-zone_critical}"
    if [ -f "${TG_BIN}/failsafe.sh" ]; then
        sh "${TG_BIN}/failsafe.sh" "${reason}" 2>/dev/null
    fi
    log "action_failsafe: reason=${reason}"
}

# ─── Apply zone actions ────────────────────────────────────────────
apply_zone_actions() {
    local zone="$1"

    # Samsung safe mode: monitor + failsafe only.
    # No trip-point writes, no charging writes, no cpuset tweaks.
    if [ "${TG_SAMSUNG_SAFE}" = "true" ]; then
        case "${zone}" in
            normal|push)
                log "Samsung-safe: zone=${zone} (monitor only)"
                ;;
            limit)
                # Conservative step-down only; smaller percent; higher floor
                action_step_down 3
                log "Samsung-safe: zone=limit step_down 3%"
                ;;
            critical)
                action_failsafe "zone_critical"
                ;;
        esac
        return 0
    fi

    case "${zone}" in
        normal)
            action_none
            ;;
        push)
            action_raise_trip 3
            ;;
        limit)
            action_step_down "${TG_STEP_DOWN_PCT}"
            if [ "${TG_PROFILE}" = "saver" ]; then
                action_reduce_charging "${TG_CHARGING_MA_SAVER}"
            else
                action_reduce_charging "${TG_CHARGING_MA_LIMIT}"
            fi
            action_throttle_background
            ;;
        critical)
            action_failsafe "zone_critical"
            ;;
    esac
}

# ─── Update status.json ────────────────────────────────────────────
update_status() {
    local zone="$1"
    local dev_temp="$2"
    local cpu_temp="$3"
    local gpu_temp="$4"
    local batt_temp="$5"
    local skin_temp="$6"
    local now
    now=$(date +%s 2>/dev/null || echo 0)

    # Read current CPU max freqs (for display)
    local cpu_freqs="{"
    local first=1
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "${policy_dir}" ] || continue
        local policy_name freq
        policy_name=$(basename "${policy_dir}")
        freq=$(cat "${policy_dir}/scaling_max_freq" 2>/dev/null || echo "0")
        freq=$(json_num "${freq}")
        if [ "${first}" -eq 1 ]; then
            first=0
        else
            cpu_freqs="${cpu_freqs},"
        fi
        cpu_freqs="${cpu_freqs}\"${policy_name}\": ${freq}"
    done
    cpu_freqs="${cpu_freqs}}"

    local gpu_freq=0
    if [ -f "/sys/class/kgsl/kgsl-3d0/max_gpuclk" ]; then
        gpu_freq=$(json_num "$(cat "/sys/class/kgsl/kgsl-3d0/max_gpuclk" 2>/dev/null)")
    fi

    local failsafe_active="false"
    local failsafe_reason=""
    if [ -f "${LOCKOUT_FILE}" ]; then
        local now_s lockout_s
        now_s=$(date +%s 2>/dev/null || echo 0)
        lockout_s=$(cat "${LOCKOUT_FILE}" 2>/dev/null || echo "0")
        case "${lockout_s}" in ''|*[!0-9]*) lockout_s=0 ;; esac
        if [ "${now_s}" -lt "${lockout_s}" ]; then
            failsafe_active="true"
            failsafe_reason="lockout_active"
        fi
    fi

    local mod_version=""
    if [ -f "${TGDIR}/module.prop" ]; then
        mod_version=$(sed -n 's/^version=//p' "${TGDIR}/module.prop" 2>/dev/null | head -1 | tr -d '\r')
    fi
    [ -n "${mod_version}" ] || mod_version="v1.0.2"

    local ro_json="false"
    [ "${TG_READ_ONLY}" = "true" ] && ro_json="true"
    local ss_json="false"
    [ "${TG_SAMSUNG_SAFE}" = "true" ] && ss_json="true"

    local dev_n cpu_n gpu_n batt_n skin_n
    dev_n=$(json_num "${dev_temp}")
    cpu_n=$(json_num "${cpu_temp}")
    gpu_n=$(json_num "${gpu_temp}")
    batt_n=$(json_num "${batt_temp}")
    skin_n=$(json_num "${skin_temp}")

    local cpu_ok="false" gpu_ok="false" batt_ok="false" skin_ok="false"
    [ "${cpu_n}" -gt 0 ] && cpu_ok="true"
    [ "${gpu_n}" -gt 0 ] && gpu_ok="true"
    [ "${batt_n}" -gt 0 ] && batt_ok="true"
    [ "${skin_n}" -gt 0 ] && skin_ok="true"

    local body
    body=$(cat << EOF
{
  "module": "thermalguard",
  "version": "${mod_version}",
  "soc": "${SOC_ID}",
  "soc_label": "${SOC_LABEL}",
  "manufacturer": "${MFG}",
  "samsung_safe": ${ss_json},
  "read_only": ${ro_json},
  "zone": "${zone}",
  "profile": "${TG_PROFILE}",
  "daemon_ok": true,
  "temps": {
    "device_c": ${dev_n},
    "cpu_c": ${cpu_n},
    "gpu_c": ${gpu_n},
    "battery_c": ${batt_n},
    "skin_c": ${skin_n}
  },
  "sensors": {
    "cpu": { "ok": ${cpu_ok}, "temp_c": ${cpu_n}, "path": "${CPU_TEMP_PATH}", "type": "${CPU_TEMP_TYPE}" },
    "gpu": { "ok": ${gpu_ok}, "temp_c": ${gpu_n}, "path": "${GPU_TEMP_PATH}", "type": "${GPU_TEMP_TYPE}" },
    "battery": { "ok": ${batt_ok}, "temp_c": ${batt_n}, "path": "${BATT_NODE}", "type": "power_supply" },
    "skin": { "ok": ${skin_ok}, "temp_c": ${skin_n}, "path": "${SKIN_TEMP_PATH}", "type": "${SKIN_TEMP_TYPE}" }
  },
  "zone_ref": "${zone_ref_src}",
  "thresholds": {
    "push_c": ${TG_PUSH_MAX},
    "limit_c": ${TG_LIMIT_MAX},
    "critical_c": ${TG_CRITICAL_MAX},
    "hysteresis_c": ${TG_HYSTERESIS},
    "abs_cpu_gpu_c": 85,
    "abs_battery_c": 48
  },
  "cpu_freq_max_khz": ${cpu_freqs},
  "gpu_freq_max_khz": ${gpu_freq},
  "failsafe_active": ${failsafe_active},
  "failsafe_reason": "${failsafe_reason}",
  "step_down_pct": ${TG_STEP_DOWN_PCT},
  "poll_interval_sec": ${TG_POLL_INTERVAL},
  "last_update": ${now}
}
EOF
)

    # Atomic-ish write to multiple locations
    # 1) Data dir  2) Module dir  3) webroot (KernelSU WebUI readFile sandbox)
    local webroot="/data/adb/modules/thermalguard/webroot"
    local ok_data="fail" ok_mod="fail" ok_web="fail"
    if echo "${body}" > "${STATUS_FILE}.tmp" 2>/dev/null; then
        mv "${STATUS_FILE}.tmp" "${STATUS_FILE}" 2>/dev/null && ok_data="ok"
    fi
    if echo "${body}" > "/data/adb/modules/thermalguard/status.json" 2>/dev/null; then
        ok_mod="ok"
    fi
    mkdir -p "${webroot}" 2>/dev/null
    if echo "${body}" > "${webroot}/status.json" 2>/dev/null; then
        ok_web="ok"
    fi
    # Heartbeat for debugging (UI/exec can read without full JSON parse)
    echo "${now}" > "${TG_STATE}/heartbeat" 2>/dev/null
    echo "${now} status write data=${ok_data} mod=${ok_mod} web=${ok_web} zone=${zone} cpu=${cpu_n} batt=${batt_n}" >> "${DAEMON_LOG}" 2>/dev/null
}

# ─── Clear boot marker (successful boot) ───────────────────────────
clear_boot_marker() {
    rm -f "${TG_STATE}/boot_marker" 2>/dev/null
    echo "0" > "${TG_STATE}/boot_count" 2>/dev/null
}

# ─── Main daemon loop ──────────────────────────────────────────────
main() {
    log "ThermalGuard daemon starting (SOC=${SOC_ID}, mfg=${MFG:-unknown}, samsung_safe=${TG_SAMSUNG_SAFE}, read_only=${TG_READ_ONLY})"
    # NOTE: boot marker is NOT cleared here — cleared only after health check below.

    # Load initial profile
    load_profile "${TG_PROFILE}"

    # Initialize zone state
    echo "normal" > "${CURRENT_ZONE_FILE}" 2>/dev/null
    echo "normal" > "${PREV_ZONE_FILE}" 2>/dev/null

    resolve_sensors
    dump_thermal_zones

    log "Sensors: cpu=${CPU_TEMP_PATH:-none}(${CPU_TEMP_TYPE:-n/a}) gpu=${GPU_TEMP_PATH:-none}(${GPU_TEMP_TYPE:-n/a}) skin=${SKIN_TEMP_PATH:-none}(${SKIN_TEMP_TYPE:-n/a}) batt=${BATT_NODE}"
    log "Regex cpu='${SOC_CPU_TYPE_REGEX}' gpu='${SOC_GPU_TYPE_REGEX}' skin='${SOC_SKIN_TYPE_REGEX}'"
    log "Zone ref: battery preferred (PRD device temp); CPU/GPU die only for 85C abs limit"

    # Best-effort seed with REAL temps (not zeros) so WebUI has data immediately
    _c=$(read_temp_mc "${CPU_TEMP_PATH}" 2>/dev/null || echo "")
    _g=$(read_temp_mc "${GPU_TEMP_PATH}" 2>/dev/null || echo "")
    _b=$(read_battery_temp 2>/dev/null || echo "")
    _s=$(read_temp_mc "${SKIN_TEMP_PATH}" 2>/dev/null || echo "")
    log "Initial read cpu=${_c:-na} gpu=${_g:-na} batt=${_b:-na} skin=${_s:-na}"
    _z="normal"
    if [ -n "${_b}" ] && [ "${_b}" -ge 45 ]; then _z="critical"
    elif [ -n "${_b}" ] && [ "${_b}" -ge 42 ]; then _z="limit"
    elif [ -n "${_b}" ] && [ "${_b}" -ge 38 ]; then _z="push"
    fi
    [ -n "${_b}" ] && zone_ref_src="battery"
    [ -z "${_b}" ] && [ -n "${_s}" ] && zone_ref_src="skin"
    [ -z "${_b}" ] && [ -z "${_s}" ] && zone_ref_src="none"
    update_status "${_z}" "${_b:-0}" "${_c:-0}" "${_g:-0}" "${_b:-0}" "${_s:-0}"

    _loop=0
    while true; do
        _loop=$(( _loop + 1 ))

        # Check lockout (failsafe active)
        if [ -f "${LOCKOUT_FILE}" ]; then
            now_s=$(date +%s 2>/dev/null || echo 0)
            lockout_s=$(cat "${LOCKOUT_FILE}" 2>/dev/null || echo "0")
            case "${lockout_s}" in ''|*[!0-9]*) lockout_s=0 ;; esac
            if [ "${now_s}" -lt "${lockout_s}" ]; then
                _c=$(read_temp_mc "${CPU_TEMP_PATH}" 2>/dev/null || echo "")
                _g=$(read_temp_mc "${GPU_TEMP_PATH}" 2>/dev/null || echo "")
                _b=$(read_battery_temp 2>/dev/null || echo "")
                _s=$(read_temp_mc "${SKIN_TEMP_PATH}" 2>/dev/null || echo "")
                update_status "critical" "${_b:-0}" "${_c:-0}" "${_g:-0}" "${_b:-0}" "${_s:-0}"
                sleep "${TG_POLL_INTERVAL}"
                continue
            else
                rm -f "${LOCKOUT_FILE}" 2>/dev/null
                log "Lockout expired — resuming normal operation"
                echo "normal" > "${CURRENT_ZONE_FILE}" 2>/dev/null
                echo "normal" > "${PREV_ZONE_FILE}" 2>/dev/null
            fi
        fi

        # Profile change request (optional)
        if [ -f "${TG_STATE}/profile_request" ]; then
            requested=$(cat "${TG_STATE}/profile_request" 2>/dev/null || echo "")
            case "${requested}" in
                auto|gaming|saver)
                    if [ "${requested}" != "${TG_PROFILE}" ]; then
                        load_profile "${requested}"
                        log "Profile switched to: ${TG_PROFILE}"
                    fi
                    ;;
            esac
            rm -f "${TG_STATE}/profile_request" 2>/dev/null
        fi

        # ── Read temperatures ──
        cpu_temp=$(read_temp_mc "${CPU_TEMP_PATH}" 2>/dev/null || echo "")
        gpu_temp=$(read_temp_mc "${GPU_TEMP_PATH}" 2>/dev/null || echo "")
        batt_temp=$(read_battery_temp 2>/dev/null || echo "")
        skin_temp=$(read_temp_mc "${SKIN_TEMP_PATH}" 2>/dev/null || echo "")

        # PRD: zone thresholds use DEVICE temp (battery/skin), NOT CPU die.
        if [ -n "${batt_temp}" ] && [ "${batt_temp}" -gt 0 ] 2>/dev/null; then
            dev_temp="${batt_temp}"
            zone_ref_src="battery"
        elif [ -n "${skin_temp}" ] && [ "${skin_temp}" -gt 0 ] 2>/dev/null; then
            dev_temp="${skin_temp}"
            zone_ref_src="skin"
        elif [ -n "${cpu_temp}" ] && [ "${cpu_temp}" -gt 0 ] 2>/dev/null; then
            dev_temp="${cpu_temp}"
            zone_ref_src="cpu_fallback"
        else
            dev_temp=""
            zone_ref_src="none"
        fi

        # ── Resolve zone (inline POSIX — do NOT source zone_engine here) ──
        new_zone="normal"
        if [ -z "${dev_temp}" ]; then
            new_zone="critical"
        else
            if [ -n "${cpu_temp}" ] && [ "${cpu_temp}" -ge 85 ] 2>/dev/null; then
                new_zone="critical"
            elif [ -n "${gpu_temp}" ] && [ "${gpu_temp}" -ge 85 ] 2>/dev/null; then
                new_zone="critical"
            elif [ -n "${batt_temp}" ] && [ "${batt_temp}" -ge 48 ] 2>/dev/null; then
                new_zone="critical"
            elif [ "${dev_temp}" -ge "${TG_CRITICAL_MAX}" ] 2>/dev/null; then
                new_zone="critical"
            elif [ "${dev_temp}" -ge "${TG_LIMIT_MAX}" ] 2>/dev/null; then
                new_zone="limit"
            elif [ "${dev_temp}" -ge "${TG_PUSH_MAX}" ] 2>/dev/null; then
                new_zone="push"
            else
                new_zone="normal"
            fi
            # Hysteresis: stay in hotter zone until temp drops below threshold - hyst
            prev_zone=$(cat "${CURRENT_ZONE_FILE}" 2>/dev/null || echo "normal")
            if [ "${prev_zone}" = "critical" ] && [ "${dev_temp}" -ge $(( TG_CRITICAL_MAX - TG_HYSTERESIS )) ] 2>/dev/null; then
                new_zone="critical"
            elif [ "${prev_zone}" = "limit" ] && [ "${dev_temp}" -ge $(( TG_LIMIT_MAX - TG_HYSTERESIS )) ] 2>/dev/null; then
                new_zone="limit"
            elif [ "${prev_zone}" = "push" ] && [ "${dev_temp}" -ge $(( TG_PUSH_MAX - TG_HYSTERESIS )) ] 2>/dev/null; then
                new_zone="push"
            fi
        fi
        [ -n "${new_zone}" ] || new_zone="normal"

        prev_zone=$(cat "${CURRENT_ZONE_FILE}" 2>/dev/null || echo "normal")
        if [ "${new_zone}" != "${prev_zone}" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) ${prev_zone} -> ${new_zone} temp=${dev_temp:-0}C ref=${zone_ref_src}" >> "${HISTORY_FILE}" 2>/dev/null
            log "Zone transition: ${prev_zone} -> ${new_zone} (dev=${dev_temp:-N/A}C ref=${zone_ref_src} cpu=${cpu_temp:-na} batt=${batt_temp:-na})"
            echo "${new_zone}" > "${CURRENT_ZONE_FILE}" 2>/dev/null
            echo "${prev_zone}" > "${PREV_ZONE_FILE}" 2>/dev/null
            apply_zone_actions "${new_zone}"
        fi

        # ── Update status ──
        update_status "${new_zone}" "${dev_temp:-0}" "${cpu_temp:-0}" "${gpu_temp:-0}" "${batt_temp:-0}" "${skin_temp:-0}"

        if [ "${TG_FIRST_HEALTHY}" != "1" ] && [ -f "${STATUS_FILE}" ]; then
            clear_boot_marker
            echo "0" > "${TG_STATE}/boot_count" 2>/dev/null
            TG_FIRST_HEALTHY="1"
            log "Boot health check passed — boot marker cleared"
        fi

        if [ "${_loop}" -le 8 ] || [ $(( _loop % 30 )) -eq 0 ]; then
            log "Loop#${_loop} zone=${new_zone} ref=${zone_ref_src} cpu=${cpu_temp:-na} gpu=${gpu_temp:-na} batt=${batt_temp:-na} skin=${skin_temp:-na} dev=${dev_temp:-na}"
        fi

        sleep "${TG_POLL_INTERVAL}"
    done
}

# Run main daemon
main &
