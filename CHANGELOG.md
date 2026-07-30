# Changelog

All notable changes to ClamAV-Hook will be documented in this file.

## 0.1.0-alpha.1 - 2026-07-31

Initial public preview:

- non-root scheduled ClamAV execution through a user-scoped LaunchDaemon;
- private signature database with daily updates;
- three-day quick and 21-day full scan intervals;
- low-priority CPU and I/O scheduling;
- Discord result notifications with secret-safe transport;
- root-refusing runtime and user-owned configuration, state, logs, and secrets;
- installer, upgrade-preserving uninstaller, doctor command, tests, and CI.
