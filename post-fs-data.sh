#!/system/bin/sh
# ThermalGuard — post-fs-data.sh
# Runs early in boot, before most services start.
# Minimal: boot marker + early fail-safe check only. No tweaks yet.

TGDIR="/data/adb/thermalguard"
TG_STATE="${TGDIR}/state"
TG_BIN="${TGDIR}/bin"
BOOT_MARKER="${TG_STATE}/boot_marker"
BOOT_COUNT_FILE="${TG_STATE}/boot_count"
FAILSAFE_DISABLE="${TGDIR}/disable"

# ─── Bootloop protection ───────────────────────────────────────────
# If boot fails twice in a row, disable the module.
if [ -f "${BOOT_MARKER}" ]; then
    # Marker exists from previous boot = previous boot may have failed
    BOOT_COUNT=$(cat "${BOOT_COUNT_FILE}" 2>/dev/null || echo "0")
    BOOT_COUNT=$(( BOOT_COUNT + 1 ))
    echo "${BOOT_COUNT}" > "${BOOT_COUNT_FILE}" 2>/dev/null

    if [ "${BOOT_COUNT}" -ge 2 ]; then
        # Two consecutive unclean boots — disable module
        touch "${FAILSAFE_DISABLE}" 2>/dev/null
        rm -f "${BOOT_MARKER}" 2>/dev/null
        echo "0" > "${BOOT_COUNT_FILE}" 2>/dev/null
        # Also create Magisk/KSU disable flag
        touch "/data/adb/modules/thermalguard/disable" 2>/dev/null
        exit 0
    fi
else
    # First boot (or marker was cleared) — reset counter
    echo "0" > "${BOOT_COUNT_FILE}" 2>/dev/null
fi

# Create/update boot marker (will be cleared by service.sh after successful boot)
date +%s > "${BOOT_MARKER}" 2>/dev/null

# ─── Early state init ──────────────────────────────────────────────
mkdir -p "${TG_STATE}" 2>/dev/null
mkdir -p "${TGDIR}/logs" 2>/dev/null

# Ensure zone state files exist
[ -f "${TG_STATE}/current_zone" ] || echo "normal" > "${TG_STATE}/current_zone"
[ -f "${TG_STATE}/prev_zone" ] || echo "normal" > "${TG_STATE}/prev_zone"

# ─── Early failsafe: restore originals if previous session left locks ──
if [ -f "${TG_STATE}/lockout_until" ]; then
    LOCKOUT=$(cat "${TG_STATE}/lockout_until" 2>/dev/null || echo "0")
    NOW=$(date +%s 2>/dev/null || echo 0)
    if [ "${NOW}" -lt "${LOCKOUT}" ]; then
        # Still in lockout — run failsafe to ensure clean state
        if [ -f "${TG_BIN}/failsafe.sh" ]; then
            sh "${TG_BIN}/failsafe.sh" "boot_lockout_check" 2>/dev/null
        fi
    fi
fi

# post-fs-data exits here — service.sh handles the main daemon
exit 0
