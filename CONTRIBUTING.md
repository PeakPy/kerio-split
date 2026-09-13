# Contributing

Keep changes small and reviewable. Privileged networking code (`split-tunnel`, helper install, sudoers) needs the smallest safe diff.

## Branches

- `main` — default branch; release from here
- Feature work: `feat/…`, `fix/…`, `docs/…` off `main`

## Setup (macOS)

macOS 13+, Apple Silicon, Xcode Command Line Tools.

```bash
make build     # app → dist/KerioSplit.app
make release   # pkg + uninstall pkg + DMG → dist/
```

Version string lives in [`VERSION`](VERSION). `platforms/macos/Scripts/release.sh` reads it when packaging. If you add a new `.swift` file, append it to the `swiftc` list in that script.

## Packaging smoke test

1. Install `dist/KerioSplit.pkg` → confirm `/Applications/KerioSplit.app`
2. Launch → **Install route helper** → `sudo -n /usr/local/libexec/keriosplit-ctl ping`
3. Connect All once (Accessibility may be required)
4. Run `dist/KerioSplit-Uninstall.pkg` → app, helper, and receipt should be gone

## Pull requests

1. Branch from latest `main`
2. One concern per PR
3. Say why it matters and how you tested
4. Do not commit `dist/`, secrets, or a personal `config.json`

## Ports

Linux and Windows are empty placeholders. New OS work belongs under `platforms/<os>/` and should reuse `config/` where it makes sense.

## License

Contributions are accepted under the MIT License.
