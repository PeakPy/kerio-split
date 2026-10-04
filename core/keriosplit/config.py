from __future__ import annotations

import ipaddress
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, List, Optional


class ConfigError(ValueError):
    pass


_DOMAIN_RE = re.compile(
    r"^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$",
    re.IGNORECASE,
)


@dataclass
class SplitConfig:
    vpn_routes: List[str] = field(default_factory=list)
    bypass_routes: List[str] = field(default_factory=list)
    remove_full_tunnel: bool = True
    restore_lan_default: bool = True
    custom_dns: List[str] = field(default_factory=list)
    connect_backend: str = "kerioClient"
    path: Optional[Path] = None

    @classmethod
    def load(cls, path: Path) -> "SplitConfig":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ConfigError(f"cannot read config: {exc}") from exc
        if not isinstance(raw, dict):
            raise ConfigError("config root must be an object")

        opts = raw.get("options") or {}
        if opts is None:
            opts = {}
        if not isinstance(opts, dict):
            raise ConfigError("options must be an object")

        cfg = cls(
            vpn_routes=_normalize_routes(raw.get("vpnRoutes") or []),
            bypass_routes=_normalize_routes(raw.get("bypassRoutes") or []),
            remove_full_tunnel=bool(opts.get("removeFullTunnel", True)),
            restore_lan_default=bool(opts.get("restoreLanDefault", True)),
            custom_dns=[str(x).strip() for x in (opts.get("customDns") or []) if str(x).strip()],
            connect_backend=str(opts.get("connectBackend") or "kerioClient"),
            path=path,
        )
        cfg.validate()
        return cfg

    def validate(self) -> None:
        if not self.vpn_routes and not self.bypass_routes:
            raise ConfigError("vpnRoutes and bypassRoutes are both empty")
        for item in self.vpn_routes + self.bypass_routes:
            _parse_route_target(item)


def _normalize_routes(items: Any) -> List[str]:
    if not isinstance(items, list):
        raise ConfigError("route lists must be arrays")
    out: List[str] = []
    for item in items:
        s = str(item).strip()
        if not s or s.startswith("#"):
            continue
        out.append(s)
    return out


def _looks_like_ip_or_cidr(value: str) -> bool:
    return bool(re.match(r"^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$", value))


def _parse_route_target(value: str) -> None:
    if _looks_like_ip_or_cidr(value) or "/" in value:
        try:
            if "/" in value:
                ipaddress.ip_network(value, strict=False)
            else:
                ipaddress.ip_address(value)
        except ValueError as exc:
            raise ConfigError(f"invalid host/CIDR: {value}") from exc
        return
    if _DOMAIN_RE.match(value) and "://" not in value and " " not in value:
        return
    raise ConfigError(f"invalid route target (IP/CIDR/domain): {value}")
