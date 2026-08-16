# Kerio Split

macOS utility for **split tunneling** with Kerio Control VPN Client.

Kerio often installs full-tunnel routes (`0/1` + `128.0/1`). This app removes that hijack and lets you decide, in the UI:

- **VPN routes** — traffic that must go through Kerio  
- **Bypass routes** — traffic forced onto the LAN gateway  
- **DNS / tunnel options** — full-tunnel removal, LAN default, custom DNS, auto-apply  
- **Appearance** — System / Light / Dark (Settings), with adaptive UI for both modes  
- **Import / Export** — share `config.json`; validate CIDR/IP on add  

Maintained by Mehrad Technical Team.

## Features

- Menu bar icon for quick Connect / Disconnect / Open
- Light / Dark / System appearance
- Passwordless privileged helper (one-time install)
- VPN + bypass routes, DNS options, import/export config
- Notifications when split is applied or restored
- Kerio tunnel probe on the overview dashboard
- Live CPU / app RAM / system memory on the dashboard

## Requirements

- macOS 13+
- Kerio Control VPN Client
- Xcode Command Line Tools (`xcode-select --install`)
- Admin password **once** (helper install)

## Build / distribute

```bash
make release
open dist/KerioSplit-Mehrad.dmg
```

Drag **KerioSplit** onto **Applications** in the DMG (that icon is a shortcut to `/Applications`).

## First run

1. Connect Kerio in System Settings  
2. Open **Kerio Split**  
3. Tap **Install helper (one-time)** and enter your Mac password  
4. Manage routes under **VPN Routes** / **Bypass** / **Settings**  
5. Tap **Connect Split** — no password on later connects  

Uninstall helper anytime from **Settings**.

## Config file

Runtime config:

`~/Library/Application Support/KerioSplit/Config/config.json`

Example: `Config/config.example.json`

## CLI

```bash
# after helper install (passwordless)
sudo -n /usr/local/libexec/keriosplit-ctl apply
sudo -n /usr/local/libexec/keriosplit-ctl restore
sudo -n /usr/local/libexec/keriosplit-ctl status

# or directly
sudo ./Scripts/split-tunnel.sh apply
```

## Layout

```
Config/           example JSON + legacy targets.txt
Scripts/          engine, ctl, helper installer, release
KerioSplit/       SwiftUI app
Makefile
```
