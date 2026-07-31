# Changelog

All notable changes to AV Scan Scheduler will be documented in this file.

## 0.1.0-alpha.1 - 2026-07-31

Initial public preview:

- AV Scan Scheduler project, CLI, launchd label, and local paths;
- non-root scheduled ClamAV execution through a system LaunchDaemon configured
  with the selected user's `UserName`;
- private signature database with daily updates;
- three-day quick and 21-day full scan intervals;
- lightweight due-work checks every six hours so sleeping MacBooks catch up
  promptly after wake;
- low-priority CPU and I/O scheduling;
- Discord result notifications with secret-safe transport;
- root-refusing runtime and user-owned configuration, state, logs, and secrets;
- rollback-capable, restartable migration from the original ClamAV-Hook preview;
- installer, upgrade-preserving uninstaller, doctor command, tests, and CI;
- documentation that ClamAV® is a separately installed engine and a Cisco
  trademark.
