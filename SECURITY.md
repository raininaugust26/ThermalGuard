# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x | Yes |
| < 1.0 | No (development) |

Security fixes target the latest release on the `main` branch.

## What This Project Is

ThermalGuard is a Magisk / KernelSU / APatch module that adjusts thermal throttle curves on rooted Android devices. It requires root and writes to sysfs nodes under `/sys/class/thermal`, `/sys/devices/system/cpu`, and power supply paths.

Because the module runs as root and can affect device temperature, incorrect use or malicious modification can cause hardware damage, data loss, or boot failure.

## Reporting a Vulnerability

Please **do not** open a public issue for security vulnerabilities.

Report privately via one of these channels:

- GitHub Security Advisories on this repository (preferred):  
  https://github.com/raininaugust26/ThermalGuard/security/advisories/new
- Email: raininaugust26@gmail.com

Include as much of the following as you can:

- Module version (`module.prop` `version` field)
- Root solution (Magisk / KernelSU / APatch) and version
- Android version and device / SoC
- Description of the issue and potential impact
- Steps to reproduce
- Any relevant log excerpts (redact personal data)

## What Counts as a Security Issue

- A change that can bypass or disable absolute thermal limits (CPU/GPU die 85°C, battery 48°C)
- A fail-safe that can be skipped, leaving tweaks applied after critical temperature
- A path that writes to the wrong sysfs node and can brick or destabilize a device
- Injection or path traversal in scripts that execute attacker-controlled strings
- Anything in the WebUI that can be abused to run arbitrary root commands without user intent

## What Is Not a Security Issue

- Device-specific thermal paths that are missing or wrong (report as a bug)
- Performance not improving on a particular phone
- Warranty or longevity concerns when the module is used as designed

## Disclosure Process

1. You report the issue privately.
2. We confirm receipt and assess impact.
3. A fix is prepared and tested.
4. A release or patch is published.
5. Credit is given to the reporter unless they request otherwise.

Please allow reasonable time for a fix before public disclosure.

## Scope Limits

- This project does not provide support for bypassing bootloader locks, DRM, or device attestation.
- This project does not accept contributions that remove thermal protection entirely.
- Researchers must not perform destructive testing on production devices without consent.

## Safe Use Reminder

- Always keep original values backed up (the installer writes backups under `/data/adb/thermalguard/backup/`).
- Absolute limits are enforced in code and must not be weakened.
- If the module is disabled or removed, stock thermal behavior returns after reboot once backup values are restored.

Thank you for helping keep ThermalGuard and its users safe.
