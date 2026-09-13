# Architecture

Kerio Split is a companion for Kerio Control VPN. It does not speak the Kerio protocol.

Flow:

1. Bring up a real tunnel (official Kerio client, or IPsec/OpenVPN when configured)
2. Detect the tunnel interface
3. Apply split routes from config
4. Optionally remove Kerio’s full-tunnel routes (`0/1` + `128.0/1`)

## Tree

| Path | Role |
| --- | --- |
| `config/` | Example JSON shared across ports |
| `platforms/macos/` | Shipping SwiftUI app, helper, packaging |
| `platforms/linux/` | Placeholder for a future port |
| `platforms/windows/` | Placeholder for a future port |

## macOS

```text
App (SwiftUI)
  → HelperService (one-time helper install, then passwordless sudo)
  → keriosplit-ctl
  → split-tunnel.sh
```

## Config

Runtime (macOS): `~/Library/Application Support/KerioSplit/Config/config.json`  
Example: [`config/config.example.json`](../config/config.example.json)

See also [not-a-kerio-client.md](not-a-kerio-client.md).
