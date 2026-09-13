# Security Policy

## Supported versions

Fixes land on the latest release published from `main`.

## Privileged surface

Kerio Split installs a narrow helper:

- `/usr/local/libexec/keriosplit-ctl`
- `/etc/sudoers.d/keriosplit`

Treat edits to helper install, sudoers generation, and the tunnel engine as security-sensitive.

## Reporting a vulnerability

Do **not** open a public issue.

Use [GitHub private vulnerability reporting](https://github.com/PeakPy/kerio-split/security/advisories/new) on this repository.

Include version or commit, impact, and minimal steps to reproduce.

Reports are acknowledged when practical. We coordinate a fix before public disclosure when that is appropriate.
