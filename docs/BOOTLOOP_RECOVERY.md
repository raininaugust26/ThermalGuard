# Bootloop Recovery

If ThermalGuard causes a bootloop (device stuck on logo / restart loop), use one of the methods below. **Method A is preferred.**

Affected report: Samsung Galaxy A05s (SM-A057F, Snapdragon 680 / SM6225) on v1.0.0.  
Fixed in **v1.0.1+**: no sysfs writes in `post-fs-data.sh`, Samsung-safe runtime mode, POSIX zone engine, minimal `sepolicy.rule`.

---

## Method A — Magisk / KernelSU / APatch Safe Mode (no PC)

Modules are disabled in safe mode.

1. Force restart: hold **Volume Down + Power** for ~10–15 seconds until the screen turns off.
2. Press **Power** to boot again.
3. **Immediately** when the Samsung / boot logo appears, **hold Volume Down** and keep holding until the system finishes booting.
4. If safe mode works, open your root manager and **disable** or **remove** ThermalGuard.
5. Reboot normally.

Notes:
- KernelSU / APatch: same idea — hold **Volume Down** during boot for safe mode.
- Some builds need Volume **Up** instead. Try both if one fails.

---

## Method B — ADB (USB debugging was enabled)

```sh
adb wait-for-device
adb shell su -c "touch /data/adb/modules/thermalguard/disable"
adb reboot
```

If that is not enough:

```sh
adb shell su -c "rm -rf /data/adb/modules/thermalguard"
adb shell su -c "rm -rf /data/adb/thermalguard"
adb reboot
```

---

## Method C — Custom recovery (TWRP / OrangeFox / PitchBlack)

1. Boot recovery: **Volume Up + Power** (Samsung common combo; hold until recovery).
2. Mount **Data** (`/data`).
3. Create empty file:
   - `/data/adb/modules/thermalguard/disable`
4. Optional full remove: delete folder `/data/adb/modules/thermalguard` and `/data/adb/thermalguard`.
5. Reboot system.

---

## Method D — Last resort (no root UI, no recovery usable)

Samsung **Download Mode** + stock firmware via Odin:

1. Force restart, then hold **Volume Down + Power** → Download Mode warning screen → **Volume Up** to continue.
2. Flash official stock firmware for **SM-A057F** (match CSC/region).
3. This wipes the Magisk module (and typically user data depending on options).

Only do this if A–C failed. This can trip Knox warranty bit if not already tripped.

---

## What v1.0.1 Changes (why A05s looped)

| Area | v1.0.0 risk | v1.0.1 fix |
|------|-------------|------------|
| `post-fs-data.sh` | Ran failsafe restore (sysfs writes) early in boot | **No sysfs writes** in post-fs-data |
| Bootloop protect | Slow / incomplete | Marker cleared only after daemon health check; disable after 2 bad boots |
| `zone_engine.sh` | Bash-only `;;&` (breaks on Android `mksh`) | POSIX `if/elif` |
| `sepolicy.rule` | Broad rules + `sysfs_thermal` (may not exist on Samsung) | Minimal rules only |
| Samsung runtime | Wrote trip points / charging nodes | **Samsung-safe**: monitor + limited step-down only |
| SoC detect | Missing SM6225/Holi | Added `holi` / `sm6150` / `sm6225` |

---

## After Recovery

1. Stay on stock thermal until you install **v1.0.1 or newer**.
2. Prefer **Automatic** profile on Samsung.
3. If the device still loops after installing v1.0.1, use Method A/B again and report:
   - Magisk/KSU/APatch version
   - `/data/adb/thermalguard/logs/daemon.log` (if readable)
   - Whether safe mode worked

---

## Hard Limits (unchanged)

- CPU/GPU die: **85°C**
- Battery: **48°C**

Fail-safe restores backups and locks the module for 5 minutes after Critical zone. Hard limits are never raised from the UI.
