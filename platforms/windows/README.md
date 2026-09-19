# Windows

Route engine stub — not implemented yet. Shared CLI and dry-run work today.

## Release archive

From [Releases](https://github.com/PeakPy/kerio-split/releases) download `keriosplit-*-windows.zip`, or build:

```bash
make release-windows
```

Inside the archive:

```bat
set PYTHONPATH=%CD%\lib
python -m keriosplit ping --platform dry-run
```

## Can we test with Docker on a Mac?

**No.** Docker Desktop on macOS only runs **Linux** containers. Windows containers need a Windows host/VM.

## Lightweight options on Apple Silicon

| Option | Size / notes |
| --- | --- |
| [UTM](https://mac.getutm.app/) + Windows 11 ARM | Real Windows; best for Kerio Client + routes |
| Parallels / VMware Fusion | Same idea, paid |
| Cloud Windows ARM/x64 VM | If local disk is tight |

Until the WinAPI engine exists, use `--platform dry-run` to validate shared config/CLI.

## Shared tests (on macOS)

```bash
make test-core
```
