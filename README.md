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

- Menu bar icon for quick Connect All / Disconnect All / Open
- **Connect All** — starts the official Kerio VPN Client (clicks **Connect** in the menu extra when Accessibility allows), waits for a real `utun` tunnel, then applies split. Not a Kerio protocol client. Never uses `scutil --nc start` on the Kerio Network Extension profile.
- **Disconnect All** — restores LAN routes, then clicks **Disconnect** in the official Kerio client (same Accessibility path). Does not leave the VPN session up.
- Auto-apply when Kerio connects (optional, Settings)
- Light / Dark / System appearance
- Passwordless privileged helper (one-time install)
- VPN + bypass routes, DNS options, import/export config
- Notifications when split is applied or restored
- Kerio tunnel probe on the overview dashboard
- Live CPU / app RAM / system memory on the dashboard

## Requirements

- macOS 13+
- **Kerio Control VPN Client** (proprietary Kerio VPN on TCP/UDP 4090) **or** a real alternative the firewall admin enabled:
  - macOS **L2TP over IPsec** (System Settings) — [GFI 118441](https://support.keriocontrol.gfi.com/article/118441-configuring-ipsec-vpn-client-on-macos)
  - **OpenVPN** (Kerio Control 9.5+, profile from `https://<firewall>:4081`) — [GFI 123937](https://support.keriocontrol.gfi.com/article/123937-openvpn-integration-in-kerio-control)
- Xcode Command Line Tools (`xcode-select --install`)
- Admin password **once** (helper install)

## Why Kerio Split is not a Kerio VPN client

GFI’s VPN article catalog ([section 9815](https://support.keriocontrol.gfi.com/en-us/section/9815-articles)) documents **three** ways onto a Kerio Control network: proprietary **Kerio VPN**, **IPsec/L2TP**, and **OpenVPN**. There is **no protocol spec** and **no supported third-party Kerio VPN protocol client**.

| Fact | Source |
| --- | --- |
| Kerio VPN uses TCP+UDP **4090**; TLS control + AES-GCM data | [118520](https://support.keriocontrol.gfi.com/article/118520-configuring-vpn-server-interface), [118409](https://support.keriocontrol.gfi.com/article/118409-kerio-vpn-cipher-algorithm), [118249](https://support.keriocontrol.gfi.com/article/118249-kerio-vpn-client-specifications) |
| UDP data plane; “UDP CONNECT not received” if blocked | [118366](https://support.keriocontrol.gfi.com/article/118366-unable-to-establish-data-tunnel-udp-traffic-is-probably-blocked) |
| `libkvnet` is LGPL **virtual NIC**, not the handshake | [118590](https://support.keriocontrol.gfi.com/article/118590-configuring-kerio-control-vpn-client-for-linux) |
| **Linux** connects via `/etc/init.d/kerio-kvc start` + `/etc/kerio-kvc.conf` | [118590](https://support.keriocontrol.gfi.com/article/118590-configuring-kerio-control-vpn-client-for-linux) |
| Linux GUIs such as [YAKG](https://github.com/AlirezaAzadbakht/yakg) wrap that official service (`systemctl start kerio-kvc`). They are **not** Kerio protocol clients | YAKG README: “YAKG is not a VPN implementation. It does not speak the Kerio protocol.” |
| **macOS** connects in the GUI; there is no public connect CLI equivalent to `kerio-kvc` | [118581](https://support.keriocontrol.gfi.com/article/118581-configuring-kerio-control-vpn-client-in-macos), [118400](https://support.keriocontrol.gfi.com/article/118400-kerio-vpn-client-persistent-connection) |
| macOS `user.cfg` fields: `server`, `username`, `password`, `savePassword`, `persistent` | [118595](https://support.keriocontrol.gfi.com/article/118595-deleting-kerio-control-vpn-client-entries-on-macos) / [manuals](https://manuals.gfi.com/en/kerio/control/content/vpn/deleting-vpn-client-entries-on-os-x-1583.html) |
| `launchctl load com.kerio.kvpncsvc.plist` starts the **service**, not a tunnel | [118565](https://support.keriocontrol.gfi.com/article/118565-kerio-control-vpn-client-service-is-not-running-on-mac) |
| No `kvpncadm` connect CLI in the catalog | (no article) |
| Admin JSON-RPC (`:4081/admin/api/jsonrpc/`) configures the **appliance**, does not start a laptop VPN | [API sample](https://manuals.gfi.com/en/kerio/api/control/reference/sample_communication.html) |
| Third-party **IPsec** clients are documented (native macOS L2TP, Shrew Soft, strongSwan) — not Kerio protocol | [118441](https://support.keriocontrol.gfi.com/article/118441-configuring-ipsec-vpn-client-on-macos), [118351](https://support.keriocontrol.gfi.com/article/118351-configuring-shrew-soft-vpn-client) |

Kerio Split therefore:

1. Opens the official Kerio client (clicks Connect in the menu extra when allowed) or a real IPsec/OpenVPN profile, then waits for `utun`
2. Can set documented `savePassword` / `persistent` flags in `~/.kerio/vpnclient/user.cfg` (never the `D3S:` password blob)
3. Applies split routes after a real tunnel exists

You **cannot** uninstall Kerio Control VPN Client and still use proprietary Kerio VPN from this app. You **can** uninstall it if the admin enables IPsec or OpenVPN and you connect with macOS/System Settings or Tunnelblick.

## Build / distribute

```bash
make release
open dist/KerioSplit-Mehrad.dmg
```

Drag **KerioSplit** onto **Applications** in the DMG (that icon is a shortcut to `/Applications`).

## First run

1. Open **Kerio Split**
2. Tap **Allow once** and enter your Mac password in the system dialog (only time Kerio Split asks)
3. Tap **Connect All** — starts the official Kerio client, then split applies when the tunnel is up. If Accessibility is off, click **Connect** in Kerio yourself; Kerio Split cannot log in.
4. Tap **Disconnect All** when you are done — split routes are removed and Kerio is disconnected the same way (click **Disconnect** in Kerio if Accessibility is off).
5. Manage routes under **VPN Routes** / **Bypass** / **Settings**

If Connect All still asks for a password, open **Settings → Route helper → Recheck** or tap **Allow once** again. The helper must pass `sudo -n` for your macOS user.

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
