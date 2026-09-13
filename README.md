# Kerio Split

<img src="assets/branding/banner-hero.png" alt="Kerio Split" width="100%">

Split tunneling for **Kerio Control VPN** on macOS.

Kerio’s client often pushes full-tunnel routes (`0/1` + `128.0/1`). Kerio Split strips that and applies only the routes you configure.

This project does **not** implement the Kerio VPN protocol. It starts the official client (or an admin-approved IPsec/OpenVPN path), waits for a tunnel, then edits routes. Details: [docs/not-a-kerio-client.md](docs/not-a-kerio-client.md). Kerio® is a trademark of its owners.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](platforms/macos)

## Install

Download the latest **`.pkg`** from [Releases](https://github.com/PeakPy/kerio-split/releases), or build locally:

```bash
make release
open dist/KerioSplit.pkg
```

| File | What it does |
| --- | --- |
| `KerioSplit.pkg` | Installs into `/Applications` |
| `KerioSplit-Uninstall.pkg` | Removes the app, helper, sudoers, and support files |
| `KerioSplit.dmg` | Both packages in one disk image |

Unsigned builds: right-click the package → **Open**. Apple Silicon only for now.

### First run

1. Open **Kerio Split**
2. **Install route helper** (one admin password)
3. **Connect All**
4. Edit routes under VPN Routes / Bypass / Settings

Config path: `~/Library/Application Support/KerioSplit/Config/config.json`  
Example: [`config/config.example.json`](config/config.example.json)

```bash
sudo -n /usr/local/libexec/keriosplit-ctl apply
sudo -n /usr/local/libexec/keriosplit-ctl restore
sudo -n /usr/local/libexec/keriosplit-ctl status
```

## What it does

- Menu bar: Connect All / Disconnect All / Open
- Connect All starts Kerio (Accessibility click when allowed), waits for the tunnel, applies split
- Disconnect All restores LAN routes, then disconnects Kerio
- VPN + bypass routes, DNS options, import/export
- Light / Dark / System appearance
- Narrow passwordless helper after one install

## Requirements

- macOS 13+ (arm64)
- Kerio Control VPN Client, or L2TP/IPsec / OpenVPN set up by your admin
- Xcode Command Line Tools to build from source

## Layout

```text
platforms/macos/   SwiftUI app, helper scripts, pkg packaging
platforms/linux/   reserved for a future port
platforms/windows/ reserved for a future port
config/            shared config example
docs/              architecture notes
assets/branding/   icon and README artwork
scripts/           branding sync used by the macOS build
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Ehsan Akbari
