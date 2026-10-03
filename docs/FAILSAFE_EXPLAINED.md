# Fail-Safe Explained

How ThermalGuard protects the device when things go wrong.

## Design Rule

**Safety first, performance second, always reversible.**

The module shapes throttle curves. It does not remove thermal protection.  
Absolute limits are enforced in code and cannot be raised from the WebUI.

## Absolute Limits

| Sensor | Limit | Effect when exceeded |
|--------|-------|----------------------|
| CPU / GPU die | 85°C | Force Critical zone |
| Battery | 48°C | Force Critical zone |

These limits are hard-coded in the zone engine and fail-safe scripts.  
UI sliders and profiles cannot increase them.

## Zones

| Zone | Device temp (defaults) | Behavior |
|------|------------------------|----------|
| Normal | &lt; 38°C | No tweaks |
| Push | 38–42°C | Raise stock throttle trip points; keep max clock |
| Limit | 42–45°C | Step down max freq, reduce charging current, throttle background cpusets |
| Critical | &gt; 45°C | Fail-safe: restore all backups, lock module |

Defaults come from `config/profiles.json`.  
Hysteresis (default 2°C) prevents rapid zone flapping.

## Fail-Safe Triggers

Fail-safe runs when any of these is true:

1. **Zone engine resolves Critical** — temperature at or above the critical threshold (profile-dependent, never above absolute limits in practice for device temp).
2. **CPU/GPU die ≥ 85°C** — immediate Critical regardless of profile.
3. **Battery ≥ 48°C** — immediate Critical regardless of profile.
4. **Missing or invalid temperature sensor** — treated as Critical (fail closed).
5. **Manual invocation** — `bin/failsafe.sh <reason>` from shell.

## What Fail-Safe Restores

`bin/failsafe.sh` writes original values from `/data/adb/thermalguard/backup/`:

- CPU `scaling_max_freq` for every cpufreq policy
- GPU max clock (kgsl and/or devfreq)
- Charging current nodes
- Thermal trip points
- Background `cpuset` assignments
- CPU boost flags (cleared)

Backups are created at install time by `customize.sh`.  
If a backup file is missing, that node is left alone (no blind writes of zeros).

## Lockout

After fail-safe:

- A lockout timer is written to `state/lockout_until` (default **300 seconds**).
- While locked, the daemon does not apply new tweaks.
- When the timer expires, the module resumes in Normal zone.
- A notification is sent when possible (e.g. `termux-notification` if installed).

Lockout cannot be skipped from the WebUI. It is intentional.

## Bootloop Protection

Implemented in `post-fs-data.sh`:

1. On each early boot, a marker file `state/boot_marker` is written.
2. `service.sh` clears the marker **only after** a health check (daemon wrote `status.json` successfully).
3. If the previous boot left a marker (unclean/failed boot), `boot_count` increases.
4. After **two** consecutive incomplete boots:
   - Module creates `/data/adb/thermalguard/disable`
   - Also creates `/data/adb/modules/thermalguard/disable`
   - Marker is cleared; count resets
5. **Important (v1.0.1+):** `post-fs-data.sh` never writes thermal/cpufreq/charging sysfs nodes. Fail-safe restore runs only from the late-start daemon, not during early boot.

This avoids writing unknown or firmware-guarded paths too early (known bootloop cause on some Samsung devices).

See also: [BOOTLOOP_RECOVERY.md](BOOTLOOP_RECOVERY.md).

## Sensor Validation

- Temperature reads are range-checked before use.
- Battery values are normalized (often 0.1°C units → °C).
- `0` or empty reads are not trusted as “cold”; they fail closed toward Critical if no other sensor works.
- Device temperature falls back in order: CPU die → skin → battery. If all fail → Critical.

## Read-Only Mode

If SoC detection fails:

- Active tweaks are skipped (no writes to cpufreq/charging).
- Monitoring and zone logic may still run.
- UI shows a read-only banner.

This avoids writing unknown paths on unsupported hardware.

## Conflict Refusal

The installer checks for other thermal modules (names such as `thermal_manager`, `thermal_disable`, etc.).  
If an active conflicting module is found, install is aborted.

ThermalGuard will not fight another module for the same sysfs nodes.

## SELinux

Rules live in `sepolicy.rule`.  
The project does **not** set SELinux to permissive.

## What Fail-Safe Does Not Do

- It does not spoof sensors.
- It does not guarantee zero hardware risk on a misconfigured device.
- It does not replace kernel/firmware thermal protection.

## User Responsibilities

- Install only on devices you can recover (custom recovery / known-good root).
- Keep the module updated; re-read this doc if you fork it.
- If you modify thresholds, keep absolute limits unchanged.
- Prefer Automatic profile unless you understand your SoC thermal behavior.

## Debugging Fail-Safe

```sh
# Current status
cat /data/adb/thermalguard/status.json

# Zone state
cat /data/adb/thermalguard/state/current_zone
cat /data/adb/thermalguard/state/lockout_until

# History / failsafe events
cat /data/adb/thermalguard/state/history.log

# Daemon log
cat /data/adb/thermalguard/logs/daemon.log
```

To restore stock behavior manually:

```sh
sh /data/adb/thermalguard/bin/failsafe.sh manual_restore
```

Then reboot if needed. Disabling the module (`disable` file + reboot) also returns to stock thermal behavior after backups are applied or the module is removed.

## Related Docs

- [SOC_GUIDE.md](SOC_GUIDE.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
- [SECURITY.md](../SECURITY.md)
