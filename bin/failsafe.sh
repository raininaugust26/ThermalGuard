#!/system/bin/sh
# ThermalGuard — failsafe
# Restores all original values from backup/ and locks the module.

MODULE_DIR="/data/adb/thermalguard"
BACKUP_DIR="${MODULE_DIR}/backup"
STATE_DIR="${MODULE_DIR}/state"
LOCK_FILE="${STATE_DIR}/failsafe.lock"
LOCKOUT_FILE="${STATE_DIR}/lockout_until"
STATUS_FILE="${MODULE_DIR}/status.json"
HISTORY_FILE="${STATE_DIR}/history.log"
TG_BIN="${MODULE_DIR}/bin"

# Read a value from backup file: failsafe_restore_node <backup_file> <target_node>
failsafe_restore_node() {
    local backup_file="$1"
    local target_node="$2"

    if [ ! -f "${backup_file}" ]; then
        return 1
    fi

    local original_value
    original_value=$(cat "${backup_file}" 2>/dev/null)
    if [ -z "${original_value}" ]; then
        return 1
    fi

    # Only write if node exists and is writable
    if [ -e "${target_node}" ] && [ -w "${target_node}" ]; then
        echo "${original_value}" > "${target_node}" 2>/dev/null
        return $?
    fi
    return 1
}

# failsafe_restore_cpu_freq — restore all cpufreq policies to original max freq
failsafe_restore_cpu_freq() {
    local policy backup_node target_node
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "${policy_dir}" ] || continue
        policy=$(basename "${policy_dir}")
        backup_node="${BACKUP_DIR}/cpu_${policy}_scaling_max_freq"
        target_node="${policy_dir}/scaling_max_freq"
        failsafe_restore_node "${backup_node}" "${target_node}"
    done
}

# failsafe_restore_gpu_freq — restore GPU max frequency
failsafe_restore_gpu_freq() {
    # Adreno via kgsl
    local backup="${BACKUP_DIR}/gpu_max_gpuclk"
    if [ -f "${backup}" ]; then
        failsafe_restore_node "${backup}" "/sys/class/kgsl/kgsl-3d0/max_gpuclk"
    fi

    # Mali/devfreq via glob
    for devfreq_dir in /sys/class/devfreq/*mali* /sys/class/devfreq/*gpu*; do
        [ -d "${devfreq_dir}" ] || continue
        local dir_name
        dir_name=$(basename "${devfreq_dir}")
        local backup_node="${BACKUP_DIR}/gpu_devfreq_${dir_name}_max_freq"
        local target_node="${devfreq_dir}/max_freq"
        failsafe_restore_node "${backup_node}" "${target_node}"
    done
}

# failsafe_restore_charging — restore charging current limits
failsafe_restore_charging() {
    local backup target
    for batt_dir in /sys/class/power_supply/*battery*; do
        [ -d "${batt_dir}" ] || continue
        local batt_name
        batt_name=$(basename "${batt_dir}")
        backup="${BACKUP_DIR}/charge_${batt_name}_constant_charge_current_max"
        target="${batt_dir}/constant_charge_current_max"
        failsafe_restore_node "${backup}" "${target}"

        backup="${BACKUP_DIR}/charge_${batt_name}_constant_charge_current"
        target="${batt_dir}/constant_charge_current"
        failsafe_restore_node "${backup}" "${target}"
    done

    # MTK-specific
    if [ -f "${BACKUP_DIR}/charge_mtk_current" ]; then
        failsafe_restore_node "${BACKUP_DIR}/charge_mtk_current" "/sys/devices/platform/mt_battery/charging_current"
    fi
}

# failsafe_restore_thermal_trips — restore original thermal trip points
failsafe_restore_thermal_trips() {
    local backup target
    for trip_file in /sys/class/thermal/thermal_zone*/trip_point_*_temp; do
        [ -f "${trip_file}" ] || continue
        local zone_dir zone_id trip_id
        zone_dir=$(dirname "${trip_file}")
        zone_id=$(basename "${zone_dir}")
        trip_id=$(basename "${trip_file}" | sed 's/trip_point_//;s/_temp//')
        backup="${BACKUP_DIR}/trip_${zone_id}_${trip_id}"
        target="${trip_file}"
        failsafe_restore_node "${backup}" "${target}"
    done
}

# failsafe_restore_cpuset — restore background cpuset assignments
failsafe_restore_cpuset() {
    local backup target
    for cpuset_dir in /dev/cpuset/*/; do
        [ -d "${cpuset_dir}" ] || continue
        local cpuset_name
        cpuset_name=$(basename "${cpuset_dir}")
        backup="${BACKUP_DIR}/cpuset_${cpuset_name}_cpus"
        target="${cpuset_dir}cpus"
        failsafe_restore_node "${backup}" "${target}"
    done
}

# failsafe_clear_boost — remove any thermal boost flags
failsafe_clear_boost() {
    local target
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "${policy_dir}" ] || continue
        target="${policy_dir}/boost"
        if [ -e "${target}" ] && [ -w "${target}" ]; then
            echo "0" > "${target}" 2>/dev/null
        fi
    done
}

# failsafe_notify — send a notification (best-effort; am broadcast)
failsafe_notify() {
    local title="$1"
    local message="$2"
    # Try termux-notification if available
    if command -v termux-notification >/dev/null 2>&1; then
        termux-notification --title "${title}" --content "${message}" 2>/dev/null
        return 0
    fi
    # Try Android notification via am (requires proper intents; best-effort)
    if command -v am >/dev/null 2>&1; then
        am broadcast -a thermalguard.FAILSAFE \
            --es title "${title}" \
            --es message "${message}" \
            -n com.thermalguard.notify/.Notifier 2>/dev/null
    fi
    return 0
}

# failsafe_set_lockout <seconds>
failsafe_set_lockout() {
    local seconds="$1"
    local now until
    now=$(date +%s 2>/dev/null || echo 0)
    until=$(( now + seconds ))
    echo "${until}" > "${LOCKOUT_FILE}"
}

# failsafe_is_locked
failsafe_is_locked() {
    [ -f "${LOCKOUT_FILE}" ] || return 1
    local now until
    now=$(date +%s 2>/dev/null || echo 0)
    until=$(cat "${LOCKOUT_FILE}" 2>/dev/null || echo 0)
    if [ "${now}" -lt "${until}" ]; then
        return 0
    fi
    # Lockout expired — clean up
    rm -f "${LOCKOUT_FILE}" 2>/dev/null
    return 1
}

# failsafe_run <reason>
failsafe_run() {
    local reason="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

    # Log the failsafe event
    echo "${ts} FAILSAFE reason=${reason}" >> "${HISTORY_FILE}"

    # Restore everything
    failsafe_restore_cpu_freq
    failsafe_restore_gpu_freq
    failsafe_restore_charging
    failsafe_restore_thermal_trips
    failsafe_restore_cpuset
    failsafe_clear_boost

    # Lock the module for 5 minutes
    failsafe_set_lockout 300

    # Notify the user
    failsafe_notify "ThermalGuard: Failsafe Activated" \
        "All tweaks removed and defaults restored. Reason: ${reason}. Module locked for 5 minutes."

    # Update status.json (best-effort)
    if [ -f "${STATUS_FILE}" ]; then
        # Minimal in-place update via sed (no jq dependency)
        sed -i 's/"zone": *"[^"]*"/"zone": "critical"/' "${STATUS_FILE}" 2>/dev/null
        sed -i 's/"failsafe_active": *false/"failsafe_active": true/' "${STATUS_FILE}" 2>/dev/null
        sed -i "s/\"failsafe_reason\": *\"[^\"]*\"/\"failsafe_reason\": \"${reason}\"/" "${STATUS_FILE}" 2>/dev/null
    fi
}

# When executed directly (not sourced)
case "${0}" in
    *failsafe.sh)
        if [ $# -ge 1 ]; then
            failsafe_run "$1"
        else
            failsafe_run "manual"
        fi
        ;;
esac
