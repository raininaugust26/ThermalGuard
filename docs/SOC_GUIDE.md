# SoC Guide

How ThermalGuard detects chipsets and how to add or fix a path map.

## Why Path Maps Exist

Thermal and CPU frequency nodes are not the same on every SoC:

| SoC family | Typical markers | CPU freq | GPU |
|------------|-----------------|----------|-----|
| Qualcomm | `qcom`, `sm8*`, `msm*`, `sdm*` | `cpufreq/policy*` | Adreno via `kgsl-3d0` |
| MediaTek | `mt6*`, `mt8*`, `dimensity` | `cpufreq/policy*` | Mali via `devfreq` |
| Samsung Exynos | `exynos`, `s5e*`, `universal` | `cpufreq/policy*` | Mali via `devfreq` |
| Google Tensor | `gs*`, `zuma`, `tensor` | `cpufreq/policy*` | Mali via `devfreq` |

Unknown SoCs run in **read-only mode**: temperature monitoring may work, but active tweaks are skipped.

## Detection Flow

1. `customize.sh` reads `ro.hardware`, `ro.board.platform`, `ro.product.board`.
2. It also greps `/proc/cpuinfo` for known keywords.
3. If a match is found, the matching file from `soc/` is copied to  
   `/data/adb/thermalguard/soc_detected.conf`.
4. `service.sh` loads that conf for thermal zone type regexes.
5. If detection fails, `state/soc_id` is set to `unknown` and read-only mode is enabled.

## File Format

Each file in `soc/*.conf` is a simple `KEY=value` list. Example (`qcom.conf`):

```
SOC_ID="qcom"
SOC_LABEL="Qualcomm Snapdragon"
CPUFREQ_POLICY_GLOB="/sys/devices/system/cpu/cpufreq/policy*"
CPU_SCALING_MAX_FREQ="scaling_max_freq"
THERMAL_TYPE_CPU="cpu|tsens|cluster|core"
THERMAL_TYPE_GPU="gpu|adreno"
BATTERY_TEMP_NODE="/sys/class/power_supply/battery/temp"
GPU_FREQ_GLOB="/sys/class/kgsl/kgsl-3d0"
CHARGE_CURRENT_NODE="constant_charge_current_max"
```

### Important keys

| Key | Meaning |
|-----|---------|
| `SOC_ID` | Short id used in status and logs |
| `THERMAL_TYPE_CPU` | Regex matched against `thermal_zone*/type` for CPU/die |
| `THERMAL_TYPE_GPU` | Regex for GPU zones |
| `THERMAL_TYPE_SKIN` | Regex for skin/case temperature |
| `BATTERY_TEMP_NODE` | Power supply temp node (often 0.1°C units) |
| `CHARGE_CURRENT_NODE` | Charging current max node (µA on many devices) |

Paths that do not exist are skipped at runtime. The module must not crash if a node is missing.

## How to Probe a Device

On a rooted phone (ADB shell or terminal app):

```sh
# Thermal zones
for z in /sys/class/thermal/thermal_zone*; do
  echo "$(basename "$z") type=$(cat "$z/type" 2>/dev/null) temp=$(cat "$z/temp" 2>/dev/null)"
done

# CPU frequency policies
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo "$p max=$(cat "$p/scaling_max_freq" 2>/dev/null)"
done

# GPU
ls -l /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null
ls -d /sys/class/devfreq/*mali* /sys/class/devfreq/*gpu* 2>/dev/null

# Battery temp (usually 0.1°C units)
cat /sys/class/power_supply/battery/temp 2>/dev/null

# Charging current nodes
for b in /sys/class/power_supply/*battery*; do
  echo "$b"
  cat "$b/constant_charge_current_max" 2>/dev/null
done
```

Record:

1. Which `thermal_zone` `type` values look like CPU, GPU, skin, battery.
2. Whether `scaling_max_freq` is writable.
3. Whether battery temp is in 0.1°C or raw °C (compare with a known value).

## Adding a New SoC Map

1. Create `soc/<name>.conf` based on the closest existing map (usually `qcom.conf` or `mtk.conf`).
2. Adjust `SOC_ID`, `SOC_LABEL`, and type regexes to match the device.
3. Update detection patterns in `customize.sh` (`detect_soc`) if the board strings are new.
4. Test on real hardware:
   - Installer reports the correct SoC
   - `state/soc_id` is not `unknown`
   - Temperatures in WebUI / `status.json` look sane
   - Limit zone step-down actually changes `scaling_max_freq`
5. Open a PR with device model, SoC, Android version, and probe output.

## Common Pitfalls

| Problem | Cause | Fix |
|---------|-------|-----|
| Read-only on a known chip | Detection keywords missing | Add board/platform strings to `detect_soc` |
| GPU never steps down | Wrong `THERMAL_TYPE_GPU` or missing kgsl/devfreq node | Probe GPU nodes; adjust regex |
| Battery shows 0 or huge number | Wrong unit assumption | Confirm 0.1°C vs °C on that device |
| Zone always Critical | No valid sensor path | Check thermal zone `type` strings; improve regex |
| Charging control no effect | Node not writable or different path | Confirm writable `constant_charge_current*` |

## Read-Only Mode

Read-only mode is intentional safety behavior:

- Monitoring can still run.
- Writes to cpufreq, charging, and trip points are skipped.
- UI shows a read-only banner and a share-logs button.

Do not force full mode on an unknown SoC without a tested path map.

## Submitting a Map

PRs for SoC maps should include:

- Device + SoC name
- Probe output for thermal zones and cpufreq
- Confirmation that fail-safe still runs (do not touch absolute limits)
- Any device-specific caveats (firmware-locked thermal, TrustZone, etc.)

See also: [FAILSAFE_EXPLAINED.md](FAILSAFE_EXPLAINED.md), [CONTRIBUTING.md](../CONTRIBUTING.md).
