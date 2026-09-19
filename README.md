# Kerio Split

<img src="assets/branding/banner-hero.png" alt="Kerio Split" width="100%">

Split tunneling for **Kerio Control VPN**.

Kerio’s client often pushes full-tunnel routes (`0/1` + `128.0/1`). Kerio Split strips that and applies only the routes you configure.

This project does **not** implement the Kerio VPN protocol. It starts the official client (or an admin-approved IPsec/OpenVPN path), waits for a tunnel, then edits routes. Details: [docs/not-a-kerio-client.md](docs/not-a-kerio-client.md). Kerio® is a trademark of its owners.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](platforms/macos)
[![Linux CLI](https://img.shields.io/badge/Linux-CLI-green.svg)](platforms/linux)
[![Windows](https://img.shields.io/badge/Windows-preview-lightgrey.svg)](platforms/windows)

## Install

Download from [Releases](https://github.com/PeakPy/kerio-split/releases).

| Artifact | Platform |
| --- | --- |
| `KerioSplit.pkg` / `.dmg` | **macOS** app (Apple Silicon) — primary, best-tested |
| `keriosplit-*-linux.tar.gz` | **Linux** CLI (`ip route`) — early preview |
| `keriosplit-*-windows.zip` | **Windows** CLI — early preview (engine stub) |

> **Linux & Windows are early previews.** They have not been tested enough in real Kerio setups yet (CI covers dry-run + a Linux Docker route smoke only). Please try them on your machine and **[open an issue with feedback](https://github.com/PeakPy/kerio-split/issues/new/choose)** — what worked, what broke, OS/distro, and steps. That feedback is how these ports become trustworthy.

### macOS

```bash
make release-macos
open dist/KerioSplit.pkg
```

Unsigned builds: right-click → **Open**.

1. Open **Kerio Split**
2. **Install route helper** (one admin password)
3. **Connect All**
4. Edit routes under VPN Routes / Bypass / Settings

Config: `~/Library/Application Support/KerioSplit/Config/config.json`  
Example: [`config/config.example.json`](config/config.example.json)

### Linux (early preview — please test & report)

Not production-ready yet. Docker smoke ≠ real Kerio. If you run it, tell us what happened.

```bash
make release-linux
tar -tzf dist/keriosplit-*-linux.tar.gz | head
# on a Linux host:
#   tar -xzf keriosplit-*-linux.tar.gz && cd keriosplit-*-linux
#   sudo ./bin/keriosplit apply -v
```

See [platforms/linux/README.md](platforms/linux/README.md). Smoke without Kerio: `make test-linux-docker`.

### Windows (early preview — please test & report)

Engine is a stub; shared CLI/dry-run only for now. Still useful to validate packaging — please file issues with your results.

```bash
make release-windows
```

See [platforms/windows/README.md](platforms/windows/README.md).

## Shared CLI (any OS)

```bash
make test-core
PYTHONPATH=core:platforms/linux:platforms/windows \
  python3 -m keriosplit status --platform dry-run
```

## Layout

```text
core/              shared Python config + CLI + dry-run
platforms/macos/   SwiftUI app, helper, pkg/DMG
platforms/linux/   iproute2 adapter + Docker smoke
platforms/windows/ WinAPI stub
config/            shared config example
docs/              architecture + ports
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Ehsan Akbari
