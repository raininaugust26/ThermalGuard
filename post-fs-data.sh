#!/system/bin/sh
# ThermalGuard — post-fs-data.sh
# Early boot hook. SAFETY FIRST:
#   - Never write thermal/cpufreq/charging sysfs here (Samsung bootloops).
#   - Never run failsafe restore here.
#   - Only: bootloop marker + auto-disable if previous boot failed.

TGDIR="/data/adb/thermalguard"
TG_STATE="${TGDIR}/state"
MODDIR="/data/adb/modules/thermalguard"
BOOT_MARKER="${TG_STATE}/boot_marker"
BOOT_COUNT_FILE="${TG_STATE}/boot_count"

disable_module() {
    # Multiple disable paths (Magisk / KSU / APatch / module data dir)
    touch "${TGDIR}/disable" 2>/dev/null
    touch "${MODDIR}/disable" 2>/dev/null
    touch "/data/adb/modules_update/thermalguard/disable" 2>/dev/null
    # Optional uninstall on next reboot
    # touch "${MODDIR}/remove" 2>/dev/null
}

# ─── Already disabled? Do nothing. ─────────────────────────────────
if [ -f "${TGDIR}/disable" ] || [ -f "${MODDIR}/disable" ]; then
    exit 0
fi

# ─── Bootloop protection ───────────────────────────────────────────
# Marker left from previous boot => that boot never reached service.sh success.
mkdir -p "${TG_STATE}" 2>/dev/null

if [ -f "${BOOT_MARKER}" ]; then
    BOOT_COUNT=$(cat "${BOOT_COUNT_FILE}" 2>/dev/null)
    case "${BOOT_COUNT}" in
        ''|*[!0-9]*) BOOT_COUNT=0 ;;
    esac
    BOOT_COUNT=$(( BOOT_COUNT + 1 ))
    echo "${BOOT_COUNT}" > "${BOOT_COUNT_FILE}" 2>/dev/null

    # Two consecutive incomplete boots → disable (stock thermal returns after reboot)
    if [ "${BOOT_COUNT}" -ge 2 ]; then
        disable_module
        rm -f "${BOOT_MARKER}" 2>/dev/null
        echo "0" > "${BOOT_COUNT_FILE}" 2>/dev/null
        exit 0
    fi
else
    echo "0" > "${BOOT_COUNT_FILE}" 2>/dev/null
fi

# Mark boot in progress. Cleared by service.sh only after daemon health check.
date +%s > "${BOOT_MARKER}" 2>/dev/null

# Minimal state init (no sysfs)
[ -f "${TG_STATE}/current_zone" ] || echo "normal" > "${TG_STATE}/current_zone"
[ -f "${TG_STATE}/prev_zone" ] || echo "normal" > "${TG_STATE}/prev_zone"

# NO failsafe, NO sysfs writes in post-fs-data.
exit 0
