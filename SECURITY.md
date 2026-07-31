# Security policy

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue.

Use GitHub's private vulnerability reporting or open a private Security
Advisory for this repository. Include:

- the affected version or commit;
- the macOS and ClamAV engine versions;
- reproduction steps;
- the expected and observed privilege boundary;
- whether a Discord webhook or local file path may have been exposed.

## Privilege model

AV Scan Scheduler separates installation privilege from runtime privilege:

- `sudo` is used to install immutable runtime files and the LaunchDaemon;
- the LaunchDaemon has a validated `UserName`;
- Homebrew tools, ClamAV tools, parsing, scans, logs, state, and Discord
  transport run only as that selected user;
- the runtime refuses to execute as root;
- signatures are stored in a private user-owned database and passed explicitly
  to both `freshclam` and `clamscan`;
- configuration, signatures, state, logs, and the webhook use user-private
  directories and are never modified by the root installer;
- scan targets and exclusions are parsed as data, never evaluated as shell
  code;
- detections are never automatically removed or quarantined;
- the webhook URL must not appear in command-line arguments or logs.

This separation prevents a user-managed Homebrew binary from becoming a
root-code-execution path.

The installer should be reviewed before it is run with `sudo`.

## Supported versions

Security fixes are applied to the latest release and the default branch.
