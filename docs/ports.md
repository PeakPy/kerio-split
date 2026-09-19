# Ports & testing without Linux/Windows machines

Kerio Split stays a **companion**: official VPN client makes the tunnel; we edit routes.

## What Docker can and cannot do (on a Mac)

| Target | Docker on macOS? | What you can prove |
| --- | --- | --- |
| **Linux** | Yes (Desktop → Linux engine) | `ip route` apply/restore with a **fake** `kvnet0` |
| **Linux + real Kerio** | Poor fit | Kerio client wants a real VM/host, not a tiny container |
| **Windows** | **No** | Windows containers are not available on Mac Docker |

So: use Docker for **Linux route-engine confidence**, and a **tiny VM** for Kerio end-to-end.

## Recommended lab (small footprint)

1. **Unit / dry-run** (always, on Mac) — no Docker  
2. **Linux Docker smoke** — Alpine + `NET_ADMIN`, ~tens of MB image  
3. **Linux VM** (UTM Ubuntu Server minimal) — install `kerio-kvc` when you need real VPN  
4. **Windows VM** (UTM Windows 11 ARM, thin disk) — when Windows engine exists  

## Commands

```bash
# shared logic
make test-core

# linux route smoke in Docker
make test-linux-docker
```

## Architecture reminder

```text
core/keriosplit     shared CLI + config + dry-run
platforms/linux     iproute2 adapter
platforms/windows   stub (WinAPI later)
platforms/macos     shipping Swift app (unchanged for now)
```
