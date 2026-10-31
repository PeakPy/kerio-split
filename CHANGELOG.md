# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).  
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.2] - 2026-10-31

### Added

- Routing conflicts now resolve themselves: if Kerio disappears (force-quit, crash, network drop) while split is ON, routes and DNS are restored automatically; if the tunnel is alive but routes are missing, only the missing routes are re-added (max 3 attempts, then it stops and shows the conflict)
- "Cancel connecting" button on the Overview hero while Connect All is running

### Changed

- Connect All gives up after 3 Connect clicks (7s apart) and tells the user the problem is on the Kerio side, instead of retrying for 90s; wait window is 60s
- Faster Connect All: tunnel polling every ~0.35s, apply retries every 0.6s, `scutil --dns` cached for 15s

### Fixed

- A failed `apply` was reported as success because its output mentions "hijack"; only the real success marker counts now
- `0/1` hijack detection matched unrelated routes such as `10.0/16`; route presence checks used prefix matching (`10.1` matched `10.10/16`) — both now compare exact destinations
- Route guard never recognised `/16`, `/8`, `/30` routes (netstat shortens them) and re-added all routes every tick; it now re-adds only the missing ones and ignores domains
- Restore now puts DNS back (previously left on the custom/VPN servers after Disconnect or a Kerio crash)
- Restore/apply used a stale saved LAN gateway after switching Wi-Fi; the live gateway wins and the snapshot is re-captured when split is not applied
- Resolved domain IPs were dropped from state on every apply, so Restore could miss host routes
- App re-pins to the new utun/gateway when Kerio reconnects on a different interface

## [1.3.1] - 2026-10-28

### Added

- In-app updater (Settings → App updates): checks GitHub Releases, downloads `KerioSplit.pkg` with progress and SHA-256 verification, installs with one password prompt and relaunches; optional automatic check every 6h; menu bar shows when an update exists

### Fixed

- Route helper no longer flips to "Setup needed" after a while: slower `sudo` probes are retried, overlapping probes are dropped, and a single transient failure is ignored
- Install/Remove helper no longer gets cut off by the 20s busy watchdog while the password dialog is open

## [1.3.0] - 2026-10-04

### Added

- VPN Routes and Bypass accept **domains** and wildcards (`mail.corp.com`, `*.corp.com`) in addition to IPv4/CIDR
- Split apply resolves domains to A records and installs host routes via Kerio or LAN
- Built-in outbound: corporate/bypass domains use local DNS (not FakeIP) and `direct` so Kerio/LAN routing still wins

## [1.2.9] - 2026-09-22

### Fixed

- Disconnect All no longer immediately Connect All again (auto-apply was re-entering while Kerio session still up)
- Wait up to 20s for Kerio session Disconnected; suppress auto-apply 90s after Disconnect
- Outbound `0/1` hijack no longer counted as Kerio tunnel (false “Kerio on” flicker)
- Route guard no longer toggles busy UI every ~10s
- Debounce Kerio-down detection (3 probes) to stop chip flicker
- Recognize Kerio bundle id `com.kerio.VPN.ie.agent`

## [1.2.8] - 2026-09-21

### Fixed

- Connect All no longer pretends success when Kerio daemon is up but Connect was never clicked (was endless waiting)
- Retries Kerio Connect click every ~8s while waiting for the tunnel
- Launches Kerio menu UI via bundle id when path discovery fails

### Added

- DIAG flight recorder: structured log of connect/click/network/busy flips; Activity → Copy flight log
- Log file: `~/Library/Logs/KerioSplit/flight-recorder.log`

## [1.2.7] - 2026-09-21

### Fixed

- Connect All one-shot: wait for Kerio tunnel IPv4 (not just session Connected), then retry apply up to 6 times — no second tap needed
- Hero UX when Kerio is up but split is off: badge `NEEDS SPLIT`, button `Apply Split`, process timeline stays visible

### Changed

- Outbound aligned with Karing practices: FakeIP DNS without proxy-detoured residual DNS, Mux only when link sets `mux=1`, TUN MTU 1400 for dual-VPN throughput
- Shell never treats outbound `172.19.0.x` as Kerio

## [1.2.6] - 2026-09-19

### Fixed

- Outbound auto-disconnect right after Connect: root-owned sing-box pid looked "dead" (`kill` → EPERM), watchdog killed a healthy session

## [1.2.5] - 2026-09-19

### Fixed

- Built-in outbound no longer nests inside Kerio: dial binds to `en*` only; Kerio CIDRs excluded from TUN auto_route
- FakeIP `198.18.0.0/15` was caught by private→direct and bypassed the proxy (looked Connected but traffic wrong)

## [1.2.4] - 2026-09-19

### Fixed

- Built-in outbound TUN (`172.19.0.1`) was mislabeled as Kerio — false Connected, empty SPEED, Kerio flicker
- Outbound page shows only profile tunnel + LAN rates (no Kerio card)
- Connect requires TUN to appear; dead engine clears Connected state

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

[Unreleased]: https://github.com/PeakPy/kerio-split/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.3.0
[1.2.9]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.9
[1.2.8]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.8
[1.2.7]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.7
[1.2.6]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.6
[1.2.5]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.5
[1.2.4]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.4
[1.2.3]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.3
[1.2.2]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.2
[1.2.1]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.1
[1.2.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.2.0
[1.1.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.1.0
[1.0.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.0.0
