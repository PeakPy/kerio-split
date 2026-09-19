# Linux

CLI route engine for Kerio Split (`ip route`).

**Early preview.** Automated Docker smoke exists; real Kerio + production hosts are **not** covered enough yet. Please run it and [report results](https://github.com/PeakPy/kerio-split/issues/new/choose) (distro, kernel, Kerio client version, apply/restore outcome).

## Release archive

From [Releases](https://github.com/PeakPy/kerio-split/releases) download `keriosplit-*-linux.tar.gz`, or build:

```bash
make release-linux
```

## Quick test (no root, no Docker)

From repo root:

```bash
PYTHONPATH=core:platforms/linux:platforms/windows \
  python3 -m keriosplit apply --platform dry-run -v
```

Unit tests:

```bash
make test-core
```

## Docker smoke (real `ip route`, fake tunnel)

```bash
make test-linux-docker
```

This does **not** install Kerio VPN Client. It creates a dummy `kvnet0`, fakes full-tunnel hijack routes, runs `apply` / `restore`, and checks the routing table.

## Real Kerio on Linux

Use a small VM (Ubuntu Server) or bare metal:

1. Install [Kerio Control VPN Client for Linux](https://support.keriocontrol.gfi.com/article/118590-configuring-kerio-control-vpn-client-for-linux)
2. Connect with `kerio-kvc`
3. `sudo ./bin/keriosplit apply --config /path/to/config.json -v`
