from __future__ import annotations

from keriosplit.config import SplitConfig
from keriosplit.engine import EngineResult, RouteEngine, TunnelInfo


class WindowsRouteEngine(RouteEngine):
    """Placeholder — real WinAPI / route.exe implementation comes next.

    On a Mac you cannot run Windows containers. Test on a tiny UTM/Hyper-V VM.
    Dry-run platform still covers shared config/CLI behaviour in CI.
    """

    def ping(self) -> EngineResult:
        return EngineResult(
            ok=False,
            message="windows engine not implemented yet — use --platform dry-run or a Windows VM",
        )

    def detect_tunnel(self) -> TunnelInfo:
        return TunnelInfo(present=False, detail="windows engine not implemented")

    def status(self, config: SplitConfig) -> EngineResult:
        return EngineResult(ok=False, message="windows engine not implemented")

    def apply(self, config: SplitConfig) -> EngineResult:
        return EngineResult(ok=False, message="windows engine not implemented")

    def restore(self, config: SplitConfig) -> EngineResult:
        return EngineResult(ok=False, message="windows engine not implemented")
