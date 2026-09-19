from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import List, Optional

from .config import SplitConfig


@dataclass
class TunnelInfo:
    present: bool
    interface: str = ""
    gateway: str = ""
    detail: str = ""


@dataclass
class EngineResult:
    ok: bool
    message: str
    actions: List[str] = field(default_factory=list)


class RouteEngine(ABC):
    """OS-specific tunnel detection and route apply/restore."""

    @abstractmethod
    def ping(self) -> EngineResult:
        ...

    @abstractmethod
    def detect_tunnel(self) -> TunnelInfo:
        ...

    @abstractmethod
    def status(self, config: SplitConfig) -> EngineResult:
        ...

    @abstractmethod
    def apply(self, config: SplitConfig) -> EngineResult:
        ...

    @abstractmethod
    def restore(self, config: SplitConfig) -> EngineResult:
        ...


def require_tunnel(engine: RouteEngine) -> TunnelInfo:
    info = engine.detect_tunnel()
    if not info.present:
        raise RuntimeError(
            info.detail or "no VPN tunnel detected — connect Kerio (or IPsec/OpenVPN) first"
        )
    return info
