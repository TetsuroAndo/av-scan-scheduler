# Changelog

All notable changes to AV Scan Scheduler will be documented in this file.

## 0.1.0-alpha.2 (unreleased)

- renamed the project, CLI, launchd label, and local paths to AV Scan Scheduler;
- added a rollback-capable, restartable migration from the initial preview
  installation;
- changed the lightweight due-work check from once daily to every six hours so
  sleeping MacBooks catch up promptly after wake;
- clarified that ClamAV® is a separately installed engine and a Cisco
  trademark;
- retained the non-root runtime, private database, schedule, and Discord
  notification behavior.

## 0.1.0-alpha.1 - 2026-07-31

Initial public preview:

- non-root scheduled ClamAV execution through a system LaunchDaemon configured
  with the selected user's `UserName`;
- private signature database with daily updates;
- three-day quick and 21-day full scan intervals;
- low-priority CPU and I/O scheduling;
- Discord result notifications with secret-safe transport;
- root-refusing runtime and user-owned configuration, state, logs, and secrets;
- installer, upgrade-preserving uninstaller, doctor command, tests, and CI.
