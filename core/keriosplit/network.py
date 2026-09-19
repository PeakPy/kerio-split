"""Shared network-sense helpers for CLI / future Linux+Windows ports."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List


@dataclass
class NetworkSnapshot:
    lan_gateway: str = ""
    lan_interface: str = ""
    default_gateway: str = ""
    default_interface: str = ""
    kerio_interface: str = ""
    kerio_gateway: str = ""
    full_tunnel_hijack: bool = False
    secondary_tuns: List[str] = field(default_factory=list)
    conflict: bool = False
    conflict_detail: str = ""

    @property
    def has_kerio_tunnel(self) -> bool:
        return bool(self.kerio_interface or self.kerio_gateway or self.full_tunnel_hijack)


@dataclass
class ConnectivityReport:
    lan_ok: bool = False
    kerio_cidr_ok: bool = False
    internet_ok: bool = False
    detail: str = ""


def evaluate_conflict(*, split_active: bool, has_kerio: bool, missing_routes: List[str]) -> tuple[bool, str]:
    if not split_active:
        return False, ""
    if not has_kerio:
        return True, "Split is ON but Kerio tunnel disappeared."
    if missing_routes:
        return True, f"{len(missing_routes)} VPN route(s) missing."
    return False, ""
