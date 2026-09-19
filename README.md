# Kerio Split

<img src="assets/branding/banner-hero.png" alt="Kerio Split" width="100%">

**Cross-platform split tunneling companion for Kerio Control VPN.**

Kerio’s official client often installs full-tunnel routes (`0.0.0.0/1` + `128.0.0.0/1`). Kerio Split waits for a real tunnel, then replaces that with **only the routes you configure** — so LAN and the rest of the internet stay local.

| | |
| --- | --- |
| **What it is** | Route companion after the official VPN client is up |
| **What it is not** | A Kerio protocol client ([why](docs/not-a-kerio-client.md)) |
| **Platforms** | macOS · Linux · Windows |
| **License** | [MIT](LICENSE) |

[![CI](https://github.com/PeakPy/kerio-split/actions/workflows/ci.yml/badge.svg)](https://github.com/PeakPy/kerio-split/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/PeakPy/kerio-split)](https://github.com/PeakPy/kerio-split/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## Platforms at a glance

| Platform | Deliverable | Maturity | Notes |
| --- | --- | --- | --- |
| **macOS** | Native SwiftUI app + menu bar | **Stable** | Connect All / Disconnect All via official Kerio client; passwordless route helper |
| **Linux** | Portable CLI (`ip route`) | **Early preview** | Works against real `ip`; needs more testing with live Kerio (`kerio-kvc`) |
| **Windows** | Portable CLI package | **Early preview** | Shared CLI + dry-run today; WinAPI route engine still stubbed |

Same config shape on every OS: [`config/config.example.json`](config/config.example.json).

macOS also offers **Outbound** (built-in sing-box or external V2Box/Clash), Kerio **pin/ignore**, and **route guard** so a second VPN does not steal corporate CIDRs.

> **We need your help on Linux & Windows.** Those builds are not battle-tested enough yet. If you try a release archive, please [open a feedback issue](https://github.com/PeakPy/kerio-split/issues/new?template=port_feedback.md) — OS version, what you ran, and what worked or broke.

---

## Download

Get the latest build from **[Releases](https://github.com/PeakPy/kerio-split/releases)**.

| File | Use on |
| --- | --- |
| `KerioSplit.pkg` / `KerioSplit.dmg` | macOS (Apple Silicon) |
| `KerioSplit-Uninstall.pkg` | macOS removal |
| `keriosplit-*-linux.tar.gz` | Linux |
| `keriosplit-*-windows.zip` | Windows |

---

## macOS

Native app for macOS 13+ (arm64).

1. Install the `.pkg` (unsigned builds: right-click → **Open**)
2. Launch **Kerio Split** → **Install route helper** (one admin password)
3. **Connect All** — starts Kerio, waits for the tunnel, applies split
4. Manage routes under VPN Routes / Bypass / Settings

Runtime config:

`~/Library/Application Support/KerioSplit/Config/config.json`

Build from source:

```bash
make release-macos
open dist/KerioSplit.pkg
```

Details: [platforms/macos](platforms/macos)

---

## Linux

CLI that applies/restores split routes with `iproute2` after Kerio (or another tunnel) is up.

**Preview status:** CI runs unit dry-run + a Docker `ip route` smoke test. Real Kerio on bare metal/VM still needs community validation.

```bash
# from a release archive
tar -xzf keriosplit-*-linux.tar.gz && cd keriosplit-*-linux
./bin/keriosplit ping
sudo ./bin/keriosplit apply -v
sudo ./bin/keriosplit restore
./bin/keriosplit status
```

From this repo:

```bash
make release-linux
make test-linux-docker   # fake tunnel smoke, no Kerio binary
```

Requirements: Python 3.9+, `ip` (iproute2), root for apply/restore.  
Docs: [platforms/linux/README.md](platforms/linux/README.md) · testing notes: [docs/ports.md](docs/ports.md)

---

## Windows

CLI package aimed at the same workflow as Linux. The **route engine is still a stub**; shared config parsing and `--platform dry-run` work today.

**Preview status:** not enough real Windows + Kerio testing yet — please report anything you try.

```bat
REM from a release zip
set PYTHONPATH=%CD%\lib
python -m keriosplit ping --platform dry-run
```

From this repo:

```bash
make release-windows
```

Docs: [platforms/windows/README.md](platforms/windows/README.md)

---

## Shared core

All platforms share one Python core for config + engine contract + dry-run:

```text
core/keriosplit/          config, CLI, dry-run engine
platforms/macos/          SwiftUI app + helper packaging
platforms/linux/          iproute2 adapter + Docker smoke
platforms/windows/        Windows adapter (stub → WinAPI)
config/                   example config.json
```

```bash
make test-core
PYTHONPATH=core:platforms/linux:platforms/windows \
  python3 -m keriosplit status --platform dry-run
```

Architecture: [docs/architecture.md](docs/architecture.md)

---

## How it works

```text
Official Kerio client (or IPsec / OpenVPN)
        ↓  tunnel is up
Kerio Split engine
        ↓  remove full-tunnel hijack (optional)
        ↓  add VPN + bypass CIDRs from config
Done — only your networks go through the VPN
```

---

## Contributing

- Branches: `main` (stable / releases), `develop` (integration)
- macOS packaging and Linux/Windows CLI: see [CONTRIBUTING.md](CONTRIBUTING.md)
- Port feedback template: [Issues](https://github.com/PeakPy/kerio-split/issues/new/choose)
- Security: [SECURITY.md](SECURITY.md)

```bash
make help
make release-all    # macOS pkg/DMG + Linux tar.gz + Windows zip
```

---

## License

[MIT](LICENSE) © Ehsan Akbari

Kerio® is a trademark of its owners. This project is not affiliated with GFI / Kerio.
