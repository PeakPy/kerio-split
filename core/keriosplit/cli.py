from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from .config import ConfigError, SplitConfig
from .dryrun import DryRunEngine
from .engine import EngineResult, RouteEngine


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_config_path() -> Path:
    env = os.environ.get("KERIOSPLIT_CONFIG")
    if env:
        return Path(env)
    example = _repo_root() / "config" / "config.example.json"
    return example


def build_engine(platform: str) -> RouteEngine:
    name = platform.lower().strip()
    if name in ("dry-run", "dryrun", "fake"):
        fake = os.environ.get("KERIOSPLIT_FAKE_TUNNEL", "1") != "0"
        return DryRunEngine(fake_tunnel=fake)
    if name == "linux":
        from keriosplit_linux.engine import LinuxIpEngine  # type: ignore

        return LinuxIpEngine()
    if name == "windows":
        from keriosplit_windows.engine import WindowsRouteEngine  # type: ignore

        return WindowsRouteEngine()
    if name == "macos":
        raise SystemExit(
            "macos platform engine is not wired into this CLI yet — use the Swift app / split-tunnel.sh"
        )
    raise SystemExit(f"unknown platform: {platform}")


def _print_result(result: EngineResult, verbose: bool) -> int:
    print(result.message)
    if verbose and result.actions:
        print("— actions —")
        for action in result.actions:
            print(f"  • {action}")
    return 0 if result.ok else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="keriosplit",
        description="Kerio Split shared CLI (companion — not a Kerio protocol client)",
    )
    parser.add_argument(
        "command",
        choices=["ping", "status", "apply", "restore"],
        help="engine command",
    )
    parser.add_argument(
        "--platform",
        default=os.environ.get("KERIOSPLIT_PLATFORM", "dry-run"),
        help="dry-run | linux | windows (default: dry-run)",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="path to config.json (default: config/config.example.json)",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    config_path = args.config or default_config_path()
    try:
        config = SplitConfig.load(config_path)
    except ConfigError as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return 2

    try:
        engine = build_engine(args.platform)
    except ImportError as exc:
        print(f"platform import failed: {exc}", file=sys.stderr)
        return 2

    if args.command == "ping":
        return _print_result(engine.ping(), args.verbose)
    if args.command == "status":
        return _print_result(engine.status(config), args.verbose)
    if args.command == "apply":
        try:
            return _print_result(engine.apply(config), args.verbose)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1
    if args.command == "restore":
        return _print_result(engine.restore(config), args.verbose)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
