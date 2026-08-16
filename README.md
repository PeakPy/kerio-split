# Kerio Split

macOS utility that applies **split tunneling** for Kerio Control VPN Client.

Kerio typically pushes full-tunnel routes (`0.0.0.0/1` + `128.0.0.0/1`). This app removes those hijacks and keeps only the destinations you list (e.g. internal SSH hosts) on the VPN. Everything else stays on the normal interface.

Maintained by Mehrad Technical Team.

## Requirements

- macOS 13+
- Kerio Control VPN Client
- Xcode Command Line Tools (`xcode-select --install`) or full Xcode
- Admin password (route changes)

## Quick start

```bash
# Build .app + DMG into ./dist
make release

open dist/KerioSplit-Mehrad.dmg
```

Drag **KerioSplit** onto **Applications** in the DMG window (that icon is a shortcut to `/Applications`, not a copy of your disk).

Then:

1. Connect Kerio in System Settings  
2. Open Kerio Split → **Connect Split**  
3. Disconnect Split when finished (Kerio session stays up)

## Configuration

Default destinations: `Config/targets.txt`

At runtime the app copies/edits targets under:

`~/Library/Application Support/KerioSplit/Config/targets.txt`

One host or CIDR per line:

```
192.168.70.0/24
# 10.10.10.5
```

## CLI (optional)

```bash
sudo ./Scripts/split-tunnel.sh apply
sudo ./Scripts/split-tunnel.sh restore
sudo ./Scripts/split-tunnel.sh status
```

Capture a before/after network snapshot:

```bash
./Scripts/diagnose.sh before
./Scripts/diagnose.sh after
```

## Layout

```
Config/           default route targets
Scripts/          split-tunnel + diagnose + release
KerioSplit/       SwiftUI sources + assets
Makefile          build / release / clean
```

## License

Internal Mehrad use.
