# Contributing

Keep changes small and reviewable. Privileged networking code (`split-tunnel`, helper install, sudoers) needs the smallest safe diff.

## Branches

- `main` — stable; releases and tags come from here
- `develop` — ongoing work and testing before merge to `main`
- Feature work: `feat/…`, `fix/…`, `docs/…` off `develop` (or `main` for tiny docs fixes)

Open PRs into `develop` for normal changes; merge `develop` → `main` when shipping a release.

## Setup (macOS)

macOS 13+, Apple Silicon, Xcode Command Line Tools.

```bash
make build           # app → dist/KerioSplit.app
make release-macos   # pkg + uninstall pkg + DMG → dist/
make release-all     # macOS + Linux tar.gz + Windows zip
```

Version string lives in [`VERSION`](VERSION). `platforms/macos/Scripts/release.sh` and `scripts/package-cli.sh` read it when packaging. If you add a new `.swift` file, append it to the `swiftc` list in the macOS release script.

## Packaging smoke test

1. Install `dist/KerioSplit.pkg` → confirm `/Applications/KerioSplit.app`
2. Launch → **Install route helper** → `sudo -n /usr/local/libexec/keriosplit-ctl ping`
3. Connect All once (Accessibility may be required)
4. Run `dist/KerioSplit-Uninstall.pkg` → app, helper, and receipt should be gone
5. `make test-core` and (optional) `make test-linux-docker`

## Pull requests

1. Branch from latest `develop` (or `main` for tiny docs fixes)
2. One concern per PR
3. Say why it matters and how you tested
4. Do not commit `dist/`, secrets, or a personal `config.json`

## Ports

- Linux: `platforms/linux/` — `ip route` engine + Docker smoke
- Windows: `platforms/windows/` — stub; shared CLI/dry-run works today
- Shared logic: `core/keriosplit/`

See [docs/ports.md](docs/ports.md).

## License

Contributions are accepted under the MIT License.
