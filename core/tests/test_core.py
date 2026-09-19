#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "core"), str(ROOT / "platforms" / "linux"), str(ROOT / "platforms" / "windows")]

from keriosplit.config import ConfigError, SplitConfig  # noqa: E402
from keriosplit.dryrun import DryRunEngine  # noqa: E402
from keriosplit.cli import main as cli_main  # noqa: E402


class ConfigTests(unittest.TestCase):
    def test_example_config_loads(self):
        cfg = SplitConfig.load(ROOT / "config" / "config.example.json")
        self.assertIn("192.168.70.0/24", cfg.vpn_routes)
        self.assertTrue(cfg.remove_full_tunnel)

    def test_rejects_bad_cidr(self):
        path = ROOT / "config" / "config.example.json"
        # write temp bad file beside tests
        bad = Path("/tmp/keriosplit-bad-config.json")
        bad.write_text('{"vpnRoutes":["999.1.2.3/99"],"bypassRoutes":[],"options":{}}', encoding="utf-8")
        with self.assertRaises(ConfigError):
            SplitConfig.load(bad)


class DryRunTests(unittest.TestCase):
    def setUp(self):
        self.cfg = SplitConfig.load(ROOT / "config" / "config.example.json")
        self.engine = DryRunEngine()

    def test_ping(self):
        self.assertTrue(self.engine.ping().ok)

    def test_apply_lists_actions(self):
        result = self.engine.apply(self.cfg)
        self.assertTrue(result.ok)
        self.assertTrue(any("192.168.70.0/24" in a for a in result.actions))
        self.assertTrue(any("full-tunnel" in a for a in result.actions))

    def test_apply_without_tunnel_fails(self):
        engine = DryRunEngine(fake_tunnel=False)
        with self.assertRaises(RuntimeError):
            engine.apply(self.cfg)

    def test_restore(self):
        self.engine.apply(self.cfg)
        result = self.engine.restore(self.cfg)
        self.assertTrue(result.ok)
        self.assertFalse(self.engine.applied)


class CliTests(unittest.TestCase):
    def test_cli_status_dry_run(self):
        code = cli_main(["status", "--platform", "dry-run", "--config", str(ROOT / "config" / "config.example.json")])
        self.assertEqual(code, 0)

    def test_cli_apply_dry_run(self):
        code = cli_main(["apply", "--platform", "dry-run", "-v", "--config", str(ROOT / "config" / "config.example.json")])
        self.assertEqual(code, 0)


class NetworkSenseTests(unittest.TestCase):
    def test_conflict_when_tunnel_gone(self):
        from keriosplit.network import evaluate_conflict

        bad, msg = evaluate_conflict(split_active=True, has_kerio=False, missing_routes=[])
        self.assertTrue(bad)
        self.assertIn("disappeared", msg)

    def test_no_conflict_when_idle(self):
        from keriosplit.network import evaluate_conflict

        bad, _ = evaluate_conflict(split_active=False, has_kerio=False, missing_routes=["1.2.3.0/24"])
        self.assertFalse(bad)


if __name__ == "__main__":
    raise SystemExit(unittest.main(verbosity=2))
