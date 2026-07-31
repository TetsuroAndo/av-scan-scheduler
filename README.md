# AV Scan Scheduler

Scheduled file scans on macOS using the separately installed ClamAV® antivirus
engine, with low-priority execution and concise Discord notifications.

AV Scan Scheduler installs a scheduled launchd job, registered as a system
LaunchDaemon and configured to run as the selected non-root user. It:

- updates a private ClamAV signature database every day;
- scans the selected user's Downloads directory every three days;
- scans that user's home directory and `/Applications` every 21 days;
- sends clean, detected, and failed scan results to Discord;
- logs locally without deleting or quarantining files automatically.

The defaults are intentionally conservative. A false positive must never cause
an unattended file deletion.

## Security model

The installer uses `sudo` only to install immutable program files and register
the LaunchDaemon. The job has an explicit `UserName` and runs ClamAV tools,
Homebrew tools, notification code, and every scan as the selected user—never
as root.

This matters because a normal Homebrew installation is user-managed. Running a
Homebrew binary from a root daemon would turn a writable package path into a
privilege-escalation boundary.

Signatures live in a dedicated user-owned database. AV Scan Scheduler passes
the same path explicitly to:

```text
freshclam --datadir=...
clamscan --database=...
```

It also restricts scans to official signature databases, refuses unsigned
bytecode, rejects databases older than two days, disables filesystem crossing
and symlink following, and reports configured scan-limit overflows rather than
assuming they are clean.

See [SECURITY.md](SECURITY.md) for the trust boundary.

## Requirements

- macOS
- [Homebrew](https://brew.sh/)
- [ClamAV](https://www.clamav.net/)
- `jq`

Install dependencies as the account that will run scans:

```sh
brew install clamav jq
```

## Install

```sh
git clone https://github.com/TetsuroAndo/av-scan-scheduler.git
cd av-scan-scheduler
./install.sh
```

Checking out the versioned release tag keeps the code reviewed before `sudo`
identical to the code the installer executes. Release archives and checksums
are also published on GitHub.

The installer:

1. validates the selected local account and its home directory;
2. installs root-owned runtime files under
   `/Library/Application Support/AV Scan Scheduler`;
3. drops privileges and creates the `av-scan-scheduler` command symlink in the
   selected user's Homebrew `bin` directory;
4. initializes user-owned configuration and signatures without root;
5. renders and validates a LaunchDaemon with the selected `UserName`;
6. performs the initial private signature update as that user;
7. verifies that launchd accepted the service.

To select a different local account:

```sh
./install.sh --user another-user
```

To avoid network access during installation:

```sh
./install.sh --skip-update
```

AV Scan Scheduler currently supports one configured user per Mac.

### Upgrade from the initial preview

Running the `v0.1.0-alpha.2` installer over `v0.1.0-alpha.1` stops the legacy
job, migrates its user-owned configuration, signatures, webhook, state, and
logs, rewrites the private database path, and registers the new launchd label.
The legacy managed command and program files are removed only after the new job
has started successfully. Ordinary installation errors and handled signals
restore the previous data paths and job. The legacy label is disabled before
any data move, and rerunning the installer resumes a new-only partial migration
after an uncatchable interruption such as power loss or `SIGKILL`.

## Configure Discord

Create a webhook in the desired Discord channel, then run as the configured
user:

```sh
av-scan-scheduler configure-webhook
av-scan-scheduler notify-test
```

Input is hidden. The URL is stored at:

```text
~/Library/Application Support/AV Scan Scheduler/discord-webhook.url
```

The file uses mode `0600`; its parent directory uses `0700`. The secret URL is
provided to `curl` over standard input so it does not appear in process
arguments. Generated payloads override the webhook display name with
`AV Scan Scheduler`, and Discord mentions are disabled.

A webhook is a secret credential. Revoke it in Discord immediately if it is
ever exposed. Scan notifications disclose summary statistics and private local
log paths, but not clean filenames.

## Commands

```sh
av-scan-scheduler status
av-scan-scheduler version
av-scan-scheduler doctor
av-scan-scheduler update
av-scan-scheduler quick
av-scan-scheduler full
av-scan-scheduler configure-webhook
av-scan-scheduler notify-test
```

Do not run these commands with `sudo`. The runtime refuses root execution.

## Schedule

The LaunchDaemon runs once at load and receives a calendar trigger every day at
03:17 local time. It performs only work whose success interval has elapsed:

| Task | Default interval | Default scope |
| --- | ---: | --- |
| Signature update | 1 day | Private signature database |
| Quick scan | 3 days | `~/Downloads` |
| Full scan | 21 days | Home directory and `/Applications` |

If the Mac is asleep, macOS coalesces a missed calendar event and launches the
job after wake. Scans use `nice 15`, background process classification, and
low-priority I/O. They can still consume CPU and generate heat while parsing
large archives.

A completed full scan also satisfies the quick-scan interval. Interrupted,
incomplete, or failed scans never update success state.

Here, “quick” means a deliberately smaller target set. The ClamAV engine does
not provide an endpoint-security-style quick scan mode.

## Customize

User-owned configuration is stored under:

```text
~/Library/Application Support/AV Scan Scheduler/
```

Files include:

- `settings.conf`: update, scan, and log-retention intervals;
- `quick-paths`: one absolute quick-scan path per line;
- `full-paths`: one absolute full-scan path per line;
- `full-excludes`: one `--exclude-dir` regular expression per line;
- `freshclam.conf`: private-database configuration;
- `db/`: private signatures;
- `state/`: successful-run timestamps and the live PID lock.

Blank lines and lines beginning with `#` are ignored in path and exclusion
files. Configuration is parsed as data and is never sourced as shell code.

The default full scan excludes caches, cloud-backed storage, developer build
data, and common Docker/OrbStack storage. This avoids downloading cloud files
or spending many hours scanning disposable VM and build artifacts.

Re-running `install.sh` upgrades immutable runtime files and preserves existing
user configuration, webhook, signatures, logs, and run history.

## Logs and coverage

Private logs use mode `0600` under:

```text
~/Library/Logs/AV Scan Scheduler/
```

Logs older than 90 days are removed by default. Change
`LOG_RETENTION_DAYS` in `settings.conf` to adjust retention.

ClamAV scan exit codes are handled as follows:

- `0`: completed cleanly;
- `1`: completed and detected malware;
- any other value: scan failure.

Access-denied messages make the scan incomplete even if the scanner otherwise
exits with zero. Use the preflight check to inspect reachability:

```sh
av-scan-scheduler doctor
```

The doctor check verifies each configured target at its top level. It cannot
prove that every protected descendant is readable under macOS TCC. A clean
doctor result is therefore not a clean-scan guarantee; the completed scan log
and its coverage result are authoritative.

## macOS privacy protection

A non-root LaunchDaemon does not automatically receive macOS Transparency,
Consent, and Control (TCC) access to Downloads, Documents, Mail, Messages, or
other protected locations. Review `av-scan-scheduler doctor` and scan logs for
`Operation not permitted`.

AV Scan Scheduler never modifies the TCC database. If protected locations must
be scanned, grant Full Disk Access manually only after considering the
additional exposure that permission creates. An unsigned shell-based first
release may still be an awkward Full Disk Access target; a signed and notarized
helper is a future packaging goal.

## Process and real-time scanning

The Homebrew macOS build of `clamscan` does not expose the upstream `--memory`
process-memory option. AV Scan Scheduler does not scan running process memory.

The `clamonacc` on-access scanner distributed with the ClamAV engine is
designed for Linux and is not a macOS Endpoint Security implementation. AV
Scan Scheduler is a scheduled file-scanning tool, not an EDR, behavioral
monitor, or complete endpoint security suite.

See the upstream documentation for
[scanning](https://docs.clamav.net/manual/Usage/Scanning.html) and
[signature updates](https://docs.clamav.net/manual/Usage/SignatureManagement.html).

## Uninstall

Remove program files and the LaunchDaemon while preserving user data:

```sh
./uninstall.sh
```

Remove private signatures, configuration, logs, state, and webhook as well:

```sh
./uninstall.sh --purge
```

Homebrew, ClamAV, and any shared ClamAV database are never removed.

## Development

```sh
make lint
make test
```

Tests use fake ClamAV and Discord transports. They do not require root, alter
system launch services, send network requests, or contain a real webhook.

## License

AV Scan Scheduler is licensed under the [MIT License](LICENSE). It does not
include or redistribute ClamAV; it invokes `clamscan` and `freshclam` from a
separately installed ClamAV package. The ClamAV software is licensed under
GPLv2; see the
[upstream licensing](https://github.com/Cisco-Talos/clamav#licensing).

## Trademarks

AV Scan Scheduler is an independent project and is not sponsored by, endorsed
by, or affiliated with Cisco Systems, Inc. ClamAV® is a registered trademark
of Cisco Systems, Inc. and/or its affiliates in the United States and certain
other countries.
