# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).  
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

- Windows archive ships a stub engine (dry-run works; real routes need WinAPI next)
- macOS remains the full GUI companion

## [1.0.0] - 2026-09-13

First public release.

### Added

- macOS app with Connect All / Disconnect All through the official Kerio VPN Client
- Split routes, bypass routes, menu bar, appearance modes
- `.pkg` installer and uninstaller, plus DMG
- Non-relocatable install; Connect All resumes after Accessibility is granted
- Passwordless route helper (one-time install)

[Unreleased]: https://github.com/PeakPy/kerio-split/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.1.0
[1.0.0]: https://github.com/PeakPy/kerio-split/releases/tag/v1.0.0
