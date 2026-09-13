# macOS

Shipping app for Kerio Split.

```bash
# from repo root
make build      # dist/KerioSplit.app
make release    # dist/*.pkg + .dmg
```

Requires macOS 13+, Apple Silicon, Xcode Command Line Tools.

Packaging lives in `Scripts/` (`release.sh`, `pkg/`). New Swift sources must be added to the `swiftc` invocation in `Scripts/release.sh`.
