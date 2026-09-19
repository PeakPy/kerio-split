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
| `config/` | Shared JSON example |
| `core/keriosplit/` | Shared Python CLI + config + dry-run engine |
| `platforms/macos/` | Shipping SwiftUI app + helper |
| `platforms/linux/` | `ip route` adapter + Docker smoke |
| `platforms/windows/` | Stub (WinAPI later) |

## Shared CLI

```bash
PYTHONPATH=core:platforms/linux:platforms/windows \
  python3 -m keriosplit status --platform dry-run
```

Platforms: `dry-run` (CI), `linux`, `windows` (stub).

See [ports.md](ports.md) for Docker / VM testing without owning those machines day-to-day.

## macOS (shipping)

```text
App (SwiftUI)
  → HelperService
  → keriosplit-ctl
  → split-tunnel.sh
```

## Config

Runtime (macOS): `~/Library/Application Support/KerioSplit/Config/config.json`  
Example: [`config/config.example.json`](../config/config.example.json)

See also [not-a-kerio-client.md](not-a-kerio-client.md).
