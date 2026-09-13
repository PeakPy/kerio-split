# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).  
Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Installer no longer relocates the app outside `/Applications`
- Uninstall package removes app, helper, sudoers, and package receipts
- Connect All resumes after Accessibility is granted (no cancel/retry loop)

### Changed

- Route helper setup copy: “Install route helper” instead of “Allow once”
- Author credit limited to About / Settings

## [1.7.6] - 2026-09-13

### Added

- `.pkg` installer and uninstaller, plus DMG packaging
- Non-relocatable install via component plist + preinstall cleanup

### Changed

- Repository layout under `platforms/`, shared `config/`, OSS meta files

## [1.7.5] - 2026-09-09

### Added

- Connect / Disconnect All through the official Kerio VPN Client
- Menu bar controls and overview resource meters
- Helper-backed UI with appearance modes

[Unreleased]: https://github.com/PeakPy/kerio-split/compare/v1.7.6...HEAD
[1.7.6]: https://github.com/PeakPy/kerio-split/releases/tag/v1.7.6
[1.7.5]: https://github.com/PeakPy/kerio-split/releases/tag/v1.7.5
