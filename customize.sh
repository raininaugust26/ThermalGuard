#!/system/bin/sh
# ThermalGuard — module installer (customize.sh)
# Detects SoC, verifies writable nodes, backs up original values.

SKIPUNZIP=0
SKIPMOUNT=0
PROPFILE=0
POSTFSDATA=1
LATESTART=1
REPLACE=""

TGDIR="/data/adb/thermalguard"
MODDIR="${MODPATH}"
TG_BIN="${MODDIR}/bin"
TG_SOC="${MODDIR}/soc"
TG_CONFIG="${MODDIR}/config"
TG_BACKUP="${TGDIR}/backup"
TG_STATE="${TGDIR}/state"
TG_LOG="${TGDIR}/install.log"

# ─── Logging ───────────────────────────────────────────────────────
ui_print() {
    echo "$1"
    echo "$1" >> "${TG_LOG}" 2>/dev/null
}

# ─── Helper: check node writability ────────────────────────────────
is_writable() {
    [ -e "$1" ] && [ -w "$1" ]
}

# ─── Step 1: Environment checks ────────────────────────────────────
ui_print " "
ui_print "  ThermalGuard v1.0.0"
ui_print "  ─────────────────────────────────────"
ui_print " "

# Check root
if [ "$(id -u)" -ne 0 ]; then
    abort "! ThermalGuard requires root. Installation aborted."
fi

# Check architecture
ARCH=$(getprop ro.product.cpu.abi 2>/dev/null || echo "unknown")
case "${ARCH}" in
    arm64*|aarch64*)
        ui_print "- Architecture: arm64 (OK)"
        ;;
    *)
        abort "! Unsupported architecture: ${ARCH}. ThermalGuard requires arm64."
        ;;
esac

# Check Android version
SDK=$(getprop ro.build.version.sdk 2>/dev/null || echo "0")
if [ "${SDK}" -lt 29 ]; then
    abort "! Android 10 (API 29) or higher required. Detected SDK: ${SDK}"
fi
ui_print "- Android SDK: ${SDK} (OK)"

# ─── Step 2: Detect SoC ────────────────────────────────────────────
ui_print " "

detect_soc() {
    local hardware board platform
    hardware=$(getprop ro.hardware 2>/dev/null || echo "")
    board=$(getprop ro.board.platform 2>/dev/null || echo "")
    platform=$(getprop ro.product.board 2>/dev/null || echo "")
    local socinfo
    socinfo="${hardware} ${board} ${platform}"

    # Qualcomm (incl. Snapdragon 680 SM6225 / Holi — Galaxy A05s, etc.)
    case "${socinfo}" in
        *qcom*|*sm[0-9]*|*msm*|*sdm*|*kona*|*lahaina*|*taro*|*kalama*|*pineapple*|*holi*|*sm6150*|*sm6225*|*bengal*|*atoll*|*trinket*|*lito*|*atoll*)
            echo "qcom"
            return 0
            ;;
    esac
    # Also check /proc/cpuinfo for Qualcomm markers
    if grep -qi "qualcomm\|snapdragon" /proc/cpuinfo 2>/dev/null; then
        echo "qcom"
        return 0
    fi

    # MediaTek
    case "${socinfo}" in
        *mt[0-9]*|*mediatek*|*mtk*|*dimensity*|*helio*)
            echo "mtk"
            return 0
            ;;
    esac
    if grep -qi "mediatek\|mt[0-9]" /proc/cpuinfo 2>/dev/null; then
        echo "mtk"
        return 0
    fi

    # Samsung Exynos
    case "${socinfo}" in
        *exynos*|*universal*|*s5e*|*s5l*)
            echo "exynos"
            return 0
            ;;
    esac
    if grep -qi "exynos\|samsung" /proc/cpuinfo 2>/dev/null; then
        echo "exynos"
        return 0
    fi

    # Google Tensor
    case "${socinfo}" in
        *gs[0-9]*|*tensor*|*zuma*|*zurcher*)
            echo "tensor"
            return 0
            ;;
    esac

    # Unknown
    echo "unknown"
}

SOC_ID=$(detect_soc)
ui_print "- SoC detected: ${SOC_ID}"

# Manufacturer (Samsung needs conservative runtime behavior)
MFG=$(getprop ro.product.manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]')
case "${SOC_ID}" in
    qcom) SOC_LABEL="Qualcomm Snapdragon" ;;
    mtk) SOC_LABEL="MediaTek" ;;
    exynos) SOC_LABEL="Samsung Exynos" ;;
    tensor) SOC_LABEL="Google Tensor" ;;
    *) SOC_LABEL="Unknown SoC" ;;
esac
case "${MFG}" in
    *samsung*)
        ui_print "- Manufacturer: Samsung"
        ui_print "  Samsung-safe mode: trip/charging writes disabled at runtime."
        ui_print "  Bootloop protection hardened in v1.0.1."
        ;;
    *)
        ui_print "- Manufacturer: ${MFG:-unknown}"
        ;;
esac

if [ "${SOC_ID}" = "unknown" ]; then
    ui_print " "
    ui_print "  WARNING: Unknown SoC detected."
    ui_print "  Module will install in READ-ONLY mode."
    ui_print "  You can manually place a path map in:"
    ui_print "    ${TGDIR}/soc/"
    ui_print " "
fi

# ─── Step 3: Create data directories ───────────────────────────────
mkdir -p "${TGDIR}" 2>/dev/null
mkdir -p "${TG_BACKUP}" 2>/dev/null
mkdir -p "${TG_STATE}" 2>/dev/null
mkdir -p "${TGDIR}/logs" 2>/dev/null

# Keep module.prop in data dir (WebUI version display)
cp "${MODDIR}/module.prop" "${TGDIR}/module.prop" 2>/dev/null

# Runtime scripts + config live under /data/adb/thermalguard (daemon calls these)
mkdir -p "${TGDIR}/bin" "${TGDIR}/config" 2>/dev/null
cp -f "${MODDIR}/bin/"*.sh "${TGDIR}/bin/" 2>/dev/null
if [ ! -f "${TGDIR}/config/profiles.json" ] && [ -f "${MODDIR}/config/profiles.json" ]; then
    cp "${MODDIR}/config/profiles.json" "${TGDIR}/config/" 2>/dev/null
fi
chmod 755 "${TGDIR}/bin/"*.sh 2>/dev/null
ui_print "- Runtime bin/config staged to ${TGDIR}"

# Copy soc conf for detected chip
if [ "${SOC_ID}" != "unknown" ] && [ -f "${TG_SOC}/${SOC_ID}.conf" ]; then
    cp "${TG_SOC}/${SOC_ID}.conf" "${TGDIR}/soc_detected.conf" 2>/dev/null
    ui_print "- Path map loaded: ${SOC_ID}.conf"
fi

# ─── Step 4: Test critical writable nodes ──────────────────────────
ui_print " "
ui_print "- Probing thermal and CPU nodes..."

CPUFREQ_COUNT=0
for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "${policy_dir}" ] || continue
    if is_writable "${policy_dir}/scaling_max_freq"; then
        CPUFREQ_COUNT=$(( CPUFREQ_COUNT + 1 ))
    fi
done
ui_print "  CPU cpufreq policies (writable): ${CPUFREQ_COUNT}"

THERMAL_COUNT=0
for tz_dir in /sys/class/thermal/thermal_zone*; do
    [ -d "${tz_dir}" ] || continue
    if [ -f "${tz_dir}/temp" ] && [ -r "${tz_dir}/temp" ]; then
        THERMAL_COUNT=$(( THERMAL_COUNT + 1 ))
    fi
done
ui_print "  Thermal zones readable: ${THERMAL_COUNT}"

BATT_WRITABLE=0
for batt_dir in /sys/class/power_supply/*battery*; do
    [ -d "${batt_dir}" ] || continue
    if is_writable "${batt_dir}/constant_charge_current_max" || \
       is_writable "${batt_dir}/constant_charge_current"; then
        BATT_WRITABLE=1
        break
    fi
done
ui_print "  Charging control writable: ${BATT_WRITABLE}"

if [ "${CPUFREQ_COUNT}" -eq 0 ]; then
    ui_print " "
    ui_print "  WARNING: No writable cpufreq nodes found."
    ui_print "  CPU frequency control will be unavailable."
    ui_print "  This device may have firmware-locked thermal."
    ui_print " "
fi

# ─── Step 5: Conflict detection ────────────────────────────────────
ui_print " "
CONFLICT_FOUND=0

# Check for other thermal modules
for known_module in \
    "thermal_manager" "thermals" "no_thermal" "thermal_disable" \
    "universal_thermal" "cooler" "thermal_engine"
do
    for search_path in \
        "/data/adb/modules/${known_module}" \
        "/data/adb/modules_update/${known_module}"
    do
        if [ -d "${search_path}" ]; then
            if [ -f "${search_path}/disable" ]; then
                continue
            fi
            if [ ! -f "${search_path}/remove" ]; then
                ui_print "  CONFLICT: Thermal module '${known_module}' is active."
                CONFLICT_FOUND=1
            fi
        fi
    done
done

if [ "${CONFLICT_FOUND}" -eq 1 ]; then
    ui_print " "
    ui_print "  ThermalGuard will NOT install alongside other thermal modules."
    ui_print "  Please remove the conflicting module first, then reinstall."
    ui_print " "
    abort "! Conflicting thermal module detected. Remove it and re-run installer."
fi
ui_print "- No thermal module conflicts found."

# ─── Step 6: Backup original values ────────────────────────────────
ui_print " "
ui_print "- Backing up original values..."

backup_file() {
    local node="$1"
    local backup_name="$2"
    if [ -f "${node}" ] && [ -r "${node}" ]; then
        cat "${node}" > "${TG_BACKUP}/${backup_name}" 2>/dev/null
    fi
}

# Backup CPU max frequencies
for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "${policy_dir}" ] || continue
    policy=$(basename "${policy_dir}")
    backup_file "${policy_dir}/scaling_max_freq" "cpu_${policy}_scaling_max_freq"
    backup_file "${policy_dir}/scaling_min_freq" "cpu_${policy}_scaling_min_freq"
    backup_file "${policy_dir}/scaling_governor" "cpu_${policy}_scaling_governor"
done
ui_print "  CPU frequency backed up."

# Backup GPU max frequency
if [ -f "/sys/class/kgsl/kgsl-3d0/max_gpuclk" ]; then
    backup_file "/sys/class/kgsl/kgsl-3d0/max_gpuclk" "gpu_max_gpuclk"
fi
for devfreq_dir in /sys/class/devfreq/*mali* /sys/class/devfreq/*gpu*; do
    [ -d "${devfreq_dir}" ] || continue
    dir_name=$(basename "${devfreq_dir}")
    backup_file "${devfreq_dir}/max_freq" "gpu_devfreq_${dir_name}_max_freq"
    backup_file "${devfreq_dir}/governor" "gpu_devfreq_${dir_name}_governor"
done
ui_print "  GPU frequency backed up."

# Backup charging current
for batt_dir in /sys/class/power_supply/*battery*; do
    [ -d "${batt_dir}" ] || continue
    batt_name=$(basename "${batt_dir}")
    backup_file "${batt_dir}/constant_charge_current_max" "charge_${batt_name}_constant_charge_current_max"
    backup_file "${batt_dir}/constant_charge_current" "charge_${batt_name}_constant_charge_current"
done
if [ -f "/sys/devices/platform/mt_battery/charging_current" ]; then
    backup_file "/sys/devices/platform/mt_battery/charging_current" "charge_mtk_current"
fi
ui_print "  Charging values backed up."

# Backup thermal trip points
for trip_file in /sys/class/thermal/thermal_zone*/trip_point_*_temp; do
    [ -f "${trip_file}" ] || continue
    zone_dir=$(dirname "${trip_file}")
    zone_id=$(basename "${zone_dir}")
    trip_id=$(basename "${trip_file}" | sed 's/trip_point_//;s/_temp//')
    backup_file "${trip_file}" "trip_${zone_id}_${trip_id}"
done
ui_print "  Thermal trip points backed up."

# Backup cpuset
for cpuset_dir in /dev/cpuset/*/; do
    [ -d "${cpuset_dir}" ] || continue
    cpuset_name=$(basename "${cpuset_dir}")
    backup_file "${cpuset_dir}cpus" "cpuset_${cpuset_name}_cpus"
done
ui_print "  Cpuset values backed up."

# ─── Step 7: Create initial state ──────────────────────────────────
echo "normal" > "${TG_STATE}/current_zone" 2>/dev/null
echo "normal" > "${TG_STATE}/prev_zone" 2>/dev/null
echo "${SOC_ID}" > "${TG_STATE}/soc_id" 2>/dev/null
echo "0" > "${TG_STATE}/lockout_until" 2>/dev/null
echo "0" > "${TG_STATE}/boot_count" 2>/dev/null

# Write initial status.json
cat > "${TGDIR}/status.json" << EOF
{
  "module": "thermalguard",
  "version": "v1.0.8",
  "soc": "${SOC_ID}",
  "soc_label": "${SOC_LABEL:-Unknown}",
  "manufacturer": "${MFG:-unknown}",
  "read_only": $([ "${SOC_ID}" = "unknown" ] && echo "true" || echo "false"),
  "zone": "normal",
  "daemon_ok": false,
  "temps": {
    "device_c": 0,
    "cpu_c": 0,
    "gpu_c": 0,
    "battery_c": 0,
    "skin_c": 0
  },
  "sensors": {
    "cpu": { "ok": false, "temp_c": 0, "path": "", "type": "" },
    "gpu": { "ok": false, "temp_c": 0, "path": "", "type": "" },
    "battery": { "ok": false, "temp_c": 0, "path": "", "type": "" },
    "skin": { "ok": false, "temp_c": 0, "path": "", "type": "" }
  },
  "profile": "auto",
  "failsafe_active": false,
  "failsafe_reason": "",
  "cpu_freq_max_khz": {},
  "gpu_freq_max_khz": 0,
  "last_update": 0,
  "poll_interval_sec": 2,
  "history": []
}
EOF
ui_print "  Initial status written."

# ─── Step 8: Make scripts executable ───────────────────────────────
chmod 755 "${TG_BIN}"/*.sh 2>/dev/null
chmod 644 "${TGDIR}/status.json" 2>/dev/null

# ─── Done ───────────────────────────────────────────────────────────
ui_print " "
ui_print "  ─────────────────────────────────────"
ui_print "  ThermalGuard installed successfully."
ui_print "  SoC: ${SOC_ID}"
ui_print "  Mode: $([ "${SOC_ID}" = "unknown" ] && echo "READ-ONLY" || echo "FULL")"
ui_print "  Backup: ${TG_BACKUP}"
ui_print "  Data: ${TGDIR}"
ui_print "  ─────────────────────────────────────"
ui_print " "
ui_print "  IMPORTANT:"
ui_print "  - Reboot to activate the module."
ui_print "  - Access WebUI via KernelSU/APatch manager."
ui_print "  - Hard limits: CPU/GPU die 85°C, Battery 48°C."
ui_print "    These CANNOT be changed."
ui_print " "
ui_print "  Disclaimer: Use at your own risk. This module"
ui_print "  shapes throttle curves; it does not disable"
ui_print "  thermal protection entirely."
ui_print " "
