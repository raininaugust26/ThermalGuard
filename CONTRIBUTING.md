# Contributing to ThermalGuard

Thanks for your interest in improving ThermalGuard.

## Before You Start

- This is a root module that modifies thermal and CPU/GPU sysfs nodes.
- Wrong paths or thresholds can cause overheating, instability, or bootloops.
- The module always keeps absolute fail-safe limits. Contributions must not remove or weaken them.

Hard limits that **must never** be changed by a PR:

| Limit | Value |
|-------|-------|
| CPU/GPU die temperature | 85°C |
| Battery temperature | 48°C |

## Ways to Contribute

- Report bugs (use the issue templates)
- Improve documentation
- Add or fix SoC path maps (`soc/*.conf`)
- Improve WebUI accessibility or clarity
- Fix shell portability issues (POSIX `sh` only)

## Development Setup

1. Clone the repository.
2. Read the module scripts under `bin/`, `service.sh`, and `customize.sh`.
3. For SoC work, see [docs/SOC_GUIDE.md](docs/SOC_GUIDE.md).
4. For fail-safe behavior, see [docs/FAILSAFE_EXPLAINED.md](docs/FAILSAFE_EXPLAINED.md).

Testing on a real device is required for anything that writes to sysfs.

## Pull Request Guidelines

### Code style

- Shell: POSIX `sh` only. No bash-only features.
- Keep scripts readable; prefer clear names over clever tricks.
- Do not add dependencies that are not present on stock Android.
- WebUI: keep dark mode default, 4.5:1 contrast, 44px touch targets.

### What PRs should include

- A clear description of the problem and the fix
- Device and SoC info if the change is device-specific
- Confirmation that absolute limits are unchanged
- For SoC maps: evidence that the sysfs paths exist on at least one device

### What PRs must not include

- Removal of thermal protection
- Overclocking beyond stock limits
- Changes that make fail-safe optional or disableable from the UI
- Instructions for spoofing temperature sensors

## Commit Messages

Use short, imperative subjects. Examples:

```
Fix battery temp parsing on MTK devices
Add Tensor path map for GPU devfreq
Document cpuset throttle behavior in Limit zone
```

## Reporting Issues

- Use the provided issue templates.
- Include module version, Magisk/KernelSU/APatch version, Android version, and SoC.
- Attach relevant lines from `/data/adb/thermalguard/logs/daemon.log` when possible.
- Do not post private data (serial numbers, IMEI, emails).

## Community Conduct

Be respectful. No harassment, spam, or bad-faith PRs. Maintainers may close issues or PRs that are abusive, off-topic, or unsafe.

## License

By contributing, you agree that your contributions are licensed under the same license as this repository (GPL-3.0).
