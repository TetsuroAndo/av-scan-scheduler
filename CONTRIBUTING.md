# Contributing

Contributions are welcome.

Before opening a pull request:

```sh
make lint
make test
```

Changes to the installer, uninstaller, LaunchDaemon, configuration parser, or
Discord transport should explain their effect on the root privilege boundary.
Tests must not use a real webhook, perform external network requests, or modify
the host's launch services.

Report security-sensitive findings privately as described in
[SECURITY.md](SECURITY.md).
