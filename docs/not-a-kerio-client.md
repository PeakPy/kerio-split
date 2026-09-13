# Why Kerio Split is not a Kerio VPN client

GFI’s VPN article catalog ([section 9815](https://support.keriocontrol.gfi.com/en-us/section/9815-articles)) documents **three** ways onto a Kerio Control network: proprietary **Kerio VPN**, **IPsec/L2TP**, and **OpenVPN**. There is **no protocol spec** and **no supported third-party Kerio VPN protocol client**.

| Fact | Source |
| --- | --- |
| Kerio VPN uses TCP+UDP **4090**; TLS control + AES-GCM data | [118520](https://support.keriocontrol.gfi.com/article/118520-configuring-vpn-server-interface), [118409](https://support.keriocontrol.gfi.com/article/118409-kerio-vpn-cipher-algorithm), [118249](https://support.keriocontrol.gfi.com/article/118249-kerio-vpn-client-specifications) |
| UDP data plane; “UDP CONNECT not received” if blocked | [118366](https://support.keriocontrol.gfi.com/article/118366-unable-to-establish-data-tunnel-udp-traffic-is-probably-blocked) |
| `libkvnet` is LGPL **virtual NIC**, not the handshake | [118590](https://support.keriocontrol.gfi.com/article/118590-configuring-kerio-control-vpn-client-for-linux) |
| **Linux** connects via `/etc/init.d/kerio-kvc start` + `/etc/kerio-kvc.conf` | [118590](https://support.keriocontrol.gfi.com/article/118590-configuring-kerio-control-vpn-client-for-linux) |
| Linux GUIs such as [YAKG](https://github.com/AlirezaAzadbakht/yakg) wrap that official service. They are **not** Kerio protocol clients | YAKG README |
| **macOS** connects in the GUI; no public connect CLI equivalent to `kerio-kvc` | [118581](https://support.keriocontrol.gfi.com/article/118581-configuring-kerio-control-vpn-client-in-macos), [118400](https://support.keriocontrol.gfi.com/article/118400-kerio-vpn-client-persistent-connection) |
| macOS `user.cfg` fields: `server`, `username`, `password`, `savePassword`, `persistent` | [118595](https://support.keriocontrol.gfi.com/article/118595-deleting-kerio-control-vpn-client-entries-on-macos) |
| `launchctl load com.kerio.kvpncsvc.plist` starts the **service**, not a tunnel | [118565](https://support.keriocontrol.gfi.com/article/118565-kerio-control-vpn-client-service-is-not-running-on-mac) |
| Admin JSON-RPC configures the **appliance**, not a laptop VPN session | [API sample](https://manuals.gfi.com/en/kerio/api/control/reference/sample_communication.html) |

Kerio Split therefore:

1. Opens the official Kerio client (or a real IPsec/OpenVPN profile), then waits for a tunnel
2. Can set documented `savePassword` / `persistent` flags in `user.cfg` (never the password blob)
3. Applies split routes after a real tunnel exists

You **cannot** uninstall Kerio Control VPN Client and still use proprietary Kerio VPN from this app.
