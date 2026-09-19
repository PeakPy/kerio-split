from __future__ import annotations

from .config import SplitConfig
from .engine import EngineResult, RouteEngine, TunnelInfo, require_tunnel


class DryRunEngine(RouteEngine):
    """Records planned actions without touching the system.

    Used in CI and local tests when no real VPN / root is available.
    Set KERIOSPLIT_FAKE_TUNNEL=1 (default in dry-run) to pretend a tunnel exists.
    """

    def __init__(self, fake_tunnel: bool = True, interface: str = "tun0", gateway: str = "10.8.0.1"):
        self.fake_tunnel = fake_tunnel
        self.interface = interface
        self.gateway = gateway
        self.applied = False

    def ping(self) -> EngineResult:
        return EngineResult(ok=True, message="dry-run engine ready", actions=["ping"])

    def detect_tunnel(self) -> TunnelInfo:
        if not self.fake_tunnel:
            return TunnelInfo(present=False, detail="dry-run: fake tunnel disabled")
        return TunnelInfo(
            present=True,
            interface=self.interface,
            gateway=self.gateway,
            detail=f"dry-run fake tunnel {self.interface}",
        )

    def status(self, config: SplitConfig) -> EngineResult:
        tun = self.detect_tunnel()
        lines = [
            f"tunnel={'up' if tun.present else 'down'}",
            f"interface={tun.interface or '-'}",
            f"gateway={tun.gateway or '-'}",
            f"vpnRoutes={len(config.vpn_routes)}",
            f"bypassRoutes={len(config.bypass_routes)}",
            f"applied={self.applied}",
            "mode=dry-run",
        ]
        return EngineResult(ok=True, message="\n".join(lines), actions=["status"])

    def apply(self, config: SplitConfig) -> EngineResult:
        tun = require_tunnel(self)
        actions: list[str] = []
        if config.remove_full_tunnel:
            actions.append(f"delete full-tunnel 0/1 and 128.0/1 on {tun.interface}")
        for route in config.vpn_routes:
            actions.append(f"add vpn {route} via {tun.gateway} dev {tun.interface}")
        for route in config.bypass_routes:
            actions.append(f"add bypass {route} via lan")
        self.applied = True
        return EngineResult(
            ok=True,
            message=f"dry-run apply ok ({len(actions)} actions)",
            actions=actions,
        )

    def restore(self, config: SplitConfig) -> EngineResult:
        actions = [f"remove managed route {r}" for r in config.vpn_routes + config.bypass_routes]
        if config.restore_lan_default:
            actions.append("restore lan default route")
        self.applied = False
        return EngineResult(
            ok=True,
            message=f"dry-run restore ok ({len(actions)} actions)",
            actions=actions,
        )
