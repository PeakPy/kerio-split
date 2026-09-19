from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import List, Optional, Tuple

from keriosplit.config import SplitConfig
from keriosplit.engine import EngineResult, RouteEngine, TunnelInfo, require_tunnel

STATE_DIR = Path(os.environ.get("KERIOSPLIT_STATE", "/var/lib/keriosplit"))
STATE_FILE = STATE_DIR / "managed-routes.txt"


def _run(args: List[str], check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, check=check)


class LinuxIpEngine(RouteEngine):
    """Apply/restore split routes with `ip` (iproute2)."""

    def ping(self) -> EngineResult:
        if shutil.which("ip") is None:
            return EngineResult(ok=False, message="ip (iproute2) not found")
        return EngineResult(ok=True, message="linux ip engine ready")

    def detect_tunnel(self) -> TunnelInfo:
        # Prefer Kerio virtual NIC naming, then generic tun/tap.
        candidates = _list_ifaces()
        for pattern in (r"^kvnet", r"^kerio", r"^tun", r"^tap", r"^wg"):
            for name in candidates:
                if re.match(pattern, name):
                    gw = _iface_gateway(name) or _peer_gateway(name)
                    if _iface_has_v4(name) or gw:
                        return TunnelInfo(
                            present=True,
                            interface=name,
                            gateway=gw or "",
                            detail=f"detected {name}",
                        )
        # Full-tunnel hijack without obvious iface name
        if _has_full_tunnel_hijack():
            return TunnelInfo(
                present=True,
                interface="",
                gateway="",
                detail="full-tunnel hijack routes present (0.0.0.0/1 + 128.0.0.0/1)",
            )
        return TunnelInfo(present=False, detail="no kvnet/tun interface found")

    def status(self, config: SplitConfig) -> EngineResult:
        tun = self.detect_tunnel()
        managed = _read_managed()
        lines = [
            f"tunnel={'up' if tun.present else 'down'}",
            f"interface={tun.interface or '-'}",
            f"gateway={tun.gateway or '-'}",
            f"vpnRoutes={len(config.vpn_routes)}",
            f"bypassRoutes={len(config.bypass_routes)}",
            f"managedRoutes={len(managed)}",
            f"fullTunnelHijack={'yes' if _has_full_tunnel_hijack() else 'no'}",
        ]
        return EngineResult(ok=True, message="\n".join(lines))

    def apply(self, config: SplitConfig) -> EngineResult:
        need_root()
        tun = require_tunnel(self)
        actions: List[str] = []

        if config.remove_full_tunnel:
            for net in ("0.0.0.0/1", "128.0.0.0/1"):
                if _route_exists(net):
                    _run(["ip", "route", "del", net])
                    actions.append(f"del {net}")

        # Drop previous managed routes then re-add
        for prev in _read_managed():
            _run(["ip", "route", "del", prev])
            actions.append(f"del managed {prev}")

        lan_gw = _default_via(exclude=tun.interface)
        managed: List[str] = []

        for route in config.vpn_routes:
            dest = _normalize_dest(route)
            if tun.gateway:
                cmd = ["ip", "route", "replace", dest, "via", tun.gateway]
                if tun.interface:
                    cmd += ["dev", tun.interface]
            elif tun.interface:
                cmd = ["ip", "route", "replace", dest, "dev", tun.interface]
            else:
                return EngineResult(ok=False, message="tunnel has no gateway/interface for vpn routes")
            proc = _run(cmd)
            if proc.returncode != 0:
                return EngineResult(
                    ok=False,
                    message=f"failed vpn route {dest}: {proc.stderr.strip() or proc.stdout}",
                    actions=actions,
                )
            managed.append(dest)
            actions.append(" ".join(cmd))

        for route in config.bypass_routes:
            dest = _normalize_dest(route)
            if not lan_gw:
                return EngineResult(ok=False, message="no LAN default gateway for bypass routes", actions=actions)
            cmd = ["ip", "route", "replace", dest, "via", lan_gw]
            proc = _run(cmd)
            if proc.returncode != 0:
                return EngineResult(
                    ok=False,
                    message=f"failed bypass route {dest}: {proc.stderr.strip() or proc.stdout}",
                    actions=actions,
                )
            managed.append(dest)
            actions.append(" ".join(cmd))

        _write_managed(managed)
        return EngineResult(ok=True, message="split tunnel applied", actions=actions)

    def restore(self, config: SplitConfig) -> EngineResult:
        need_root()
        actions: List[str] = []
        for dest in _read_managed() or [_normalize_dest(r) for r in config.vpn_routes + config.bypass_routes]:
            _run(["ip", "route", "del", dest])
            actions.append(f"del {dest}")
        _write_managed([])
        return EngineResult(ok=True, message="split routes restored", actions=actions)


def need_root() -> None:
    if os.geteuid() != 0:
        raise RuntimeError("linux apply/restore require root (sudo)")


def _normalize_dest(route: str) -> str:
    return route if "/" in route else f"{route}/32"


def _list_ifaces() -> List[str]:
    proc = _run(["ip", "-o", "link", "show"])
    names: List[str] = []
    for line in proc.stdout.splitlines():
        # 2: eth0: <...>
        parts = line.split(":", 2)
        if len(parts) >= 2:
            names.append(parts[1].strip().split("@", 1)[0])
    return names


def _iface_has_v4(name: str) -> bool:
    proc = _run(["ip", "-4", "-o", "addr", "show", "dev", name])
    return bool(proc.stdout.strip())


def _iface_gateway(name: str) -> str:
    proc = _run(["ip", "-4", "route", "show", "dev", name])
    for line in proc.stdout.splitlines():
        m = re.search(r"\bvia\s+(\d+\.\d+\.\d+\.\d+)", line)
        if m:
            return m.group(1)
    return ""


def _peer_gateway(name: str) -> str:
    proc = _run(["ip", "-4", "-o", "addr", "show", "dev", name])
    # peer 10.8.0.1
    m = re.search(r"\bpeer\s+(\d+\.\d+\.\d+\.\d+)", proc.stdout)
    return m.group(1) if m else ""


def _default_via(exclude: str = "") -> str:
    proc = _run(["ip", "-4", "route", "show", "default"])
    for line in proc.stdout.splitlines():
        if exclude and f"dev {exclude}" in line:
            continue
        m = re.search(r"\bvia\s+(\d+\.\d+\.\d+\.\d+)", line)
        if m:
            return m.group(1)
    return ""


def _has_full_tunnel_hijack() -> bool:
    return _route_exists("0.0.0.0/1") and _route_exists("128.0.0.0/1")


def _route_exists(dest: str) -> bool:
    proc = _run(["ip", "-4", "route", "show", dest])
    return bool(proc.stdout.strip())


def _read_managed() -> List[str]:
    if not STATE_FILE.is_file():
        return []
    return [ln.strip() for ln in STATE_FILE.read_text().splitlines() if ln.strip()]


def _write_managed(routes: List[str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text("\n".join(routes) + ("\n" if routes else ""), encoding="utf-8")
