# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).  
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.3] - 2026-09-19

### Fixed

- VLESS/VMess WebSocket `ed=` early-data was left inside the path (e.g. `/x?ed=2560`); now maps to `max_early_data` like Karing — major throughput fix for WS nodes
- FakeIP DNS + TCP fast open + WS mux for plain VLESS WS/gRPC

## [1.2.2] - 2026-09-19

### Changed

- Faster UI refresh: parallel network probe, staggered monitor loop, shorter outbound start waits
- Built-in outbound auto-applies Kerio split when full-tunnel hijack is present (fixes crawl-speed internet)
- Outbound dial binds to LAN; TUN MTU 1400 + system stack for hotspot-friendly throughput
- Live rates show Mbps (Speedtest-scale) with snappier 0.5s sampling

## [1.2.1] - 2026-09-19

### Added

- Outbound profile Ping all + Auto-select best (TCP latency)
- Privileged sing-box start via route helper (`outbound-start` / `outbound-stop`)

### Fixed

- Built-in outbound TUN config for sing-box 1.10+ (`address` instead of deprecated `inet4_address`)
- Slow Built-in speeds vs other clients: DNS hijack, sniff, mixed stack, MTU 9000, private→direct
- Cleaner Outbound UI (collapsed details, latency badges)

## [1.2.0] - 2026-09-19

### Added

- NetworkSense + scenario-driven Overview UX (conflict, external outbound, repair)
- Kerio tunnel pin / ignoreInterfaces / route guard (`split-tunnel.sh guard`)
- Built-in outbound (sing-box) with in-app engine install, share-link + subscription import; external mode for V2Box/Clash
- Unified Network panel (live rates + topology map) on Overview
- Connectivity probes + network event log on Activity
- `scripts/fetch-sing-box.sh` to install the outbound sidecar

### Fixed

- Dual-VPN default-on-secondary-utun no longer flagged as a routing conflict
- Overview Connect/Disconnect actions when built-in outbound is up
- Kerio active detection when session/tunnel evidence disagrees
- Outbound ignore list no longer swallows the Kerio utun

## [1.1.0] - 2026-09-19

### Added

- Shared Python core (`core/keriosplit`) with dry-run engine and CLI
- Linux `ip route` adapter + Docker smoke test
- Portable release archives: `keriosplit-*-linux.tar.gz`, `keriosplit-*-windows.zip`
- Multi-platform GitHub Release workflow (macOS pkg/DMG + CLI archives)

### Changed

- Accessibility / Connect All hero layout polish on macOS
- Packaging and branding no longer show a personal credit line in the app or DMG README

### Notes

- **Linux and Windows are early previews** — not enough real-world testing yet. Please try them and [send feedback via Issues](https://github.com/PeakPy/kerio-split/issues/new/choose).
- Windows archive ships a stub engine (dry-run works; real routes need WinAPI next)
- macOS remains the full GUI companion

## [1.0.0] - 2026-09-13

First public release.

### Added

- Non-relocatable install; Connect All resumes after Accessibility is granted
- Passwordless route helper (one-time install)

[Unreleased]: https://github.com/PeakPy/kerio-split/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.0
[1.1.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.1.0
[1.0.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.0.0
