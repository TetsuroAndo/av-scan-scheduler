# Changelog

All notable changes to AV Scan Scheduler will be documented in this file.

## Unreleased

Fixed:

- Record a scan as successful when coverage was incomplete but no malware was
  detected. Previously any unreadable item (permission-protected paths, files
  in use) forced the exit status to 2, which skipped `mark_success` entirely.
  The `*.last-success` timestamp was therefore never written, `last_reference()`
  kept falling back to `installed-at`, and `is_due` stayed permanently true - so
  the scheduler started a fresh full scan on every launchd tick instead of
  honouring `FULL_INTERVAL_SECONDS`. Because full is evaluated before quick,
  this also starved quick scans completely.
- Distinguish a coverage-driven exit status of 2 from clamscan's own exit
  status of 2, so a genuine scanner failure is still never recorded as success.
- Report incomplete coverage with an accurate notification instead of the
  generic "scan failed" message.

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
