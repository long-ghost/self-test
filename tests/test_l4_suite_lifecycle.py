"""L4 suite 生命周期命令与稳定 cache id 的单元测试（unittest，不依赖 pytest）。

运行：python -m unittest tests.test_l4_suite_lifecycle -v
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parents[1]
SUITE_SCRIPT = ROOT / "module-test" / "scripts" / "l4_suite.py"


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = _load_module("l4_suite_lifecycle", SUITE_SCRIPT)


class LifecycleTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = pathlib.Path(tmp.name)
        self.e2e_root = self.base / "E2E测试"
        self.midscene = self.e2e_root / "e2e" / "midscene"
        self.cases_dir = self.midscene / "cases"
        self.cases_dir.mkdir(parents=True)
        patcher = mock.patch.dict(os.environ, {"E2E_ROOT": str(self.e2e_root)})
        patcher.start()
        self.addCleanup(patcher.stop)

    # ---- helpers ----
    def _write_case(self, case_id="L4-DDASH-001", name="登录"):
        path = self.cases_dir / f"{case_id}.yaml"
        path.write_text(
            f"cases:\n  - name: {name}\n    tags:\n      - smoke\n",
            encoding="utf-8",
        )
        return path

    def _suite(self, cases=None):
        if cases is None:
            cases = [
                {
                    "caseId": "L4-DDASH-001",
                    "file": "cases/L4-DDASH-001.yaml",
                    "name": "登录",
                    "tags": ["smoke"],
                    "criterion": "M3",
                    "lastStatus": "",
                }
            ]
        return {
            "schemaVersion": 1,
            "project": "web",
            "module": "驾驶舱",
            "cases": cases,
        }

    def _suite_path(self):
        return self.midscene / "suite.json"

    def _write_suite(self, suite):
        path = self._suite_path()
        mod.write_suite(path, suite)
        return path

    def _read_suite(self, path=None):
        return json.loads((path or self._suite_path()).read_text(encoding="utf-8"))

    def _promote_args(self, suite_path, status, **kwargs):
        return argparse.Namespace(
            suite=str(suite_path),
            case_id=kwargs.get("case_id", "L4-DDASH-001"),
            status=status,
            date=kwargs.get("date", "2026-11-26"),
            authorize=kwargs.get("authorize", True),
            bug_id=kwargs.get("bug_id", ""),
            note=kwargs.get("note", ""),
        )

    # ---- ① 改 lastStatus 后 stable_cache_id 不变 ----
    def test_01_cache_id_ignores_last_status(self):
        self._write_case()
        suite = self._suite()
        before = mod.stable_cache_id(self.base, suite)
        suite["cases"][0]["lastStatus"] = "passed"
        suite["cases"][0]["consecutivePasses"] = 3
        suite["cases"][0]["maturity"] = "stable"
        after = mod.stable_cache_id(self.base, suite)
        self.assertEqual(before, after)
        self.assertTrue(before.startswith("l4-ddash-"))

    # ---- ② 改用例 YAML 字节后 id 变 ----
    def test_02_cache_id_changes_with_yaml_bytes(self):
        path = self._write_case()
        suite = self._suite()
        before = mod.stable_cache_id(self.base, suite)
        path.write_text(
            "cases:\n  - name: 登录改\n    tags:\n      - regression\n",
            encoding="utf-8",
        )
        after = mod.stable_cache_id(self.base, suite)
        self.assertNotEqual(before, after)

    # ---- ③ collect 合并保留 lifecycle 字段 ----
    def test_03_collect_preserves_lifecycle_fields(self):
        self._write_case()
        confirmed = {"at": "2026-11-20", "bugId": "BUG-OLD", "note": "旧 bug"}
        suite = self._suite()
        suite["cases"][0].update(
            {
                "maturity": "stable",
                "consecutivePasses": 2,
                "confirmedBug": confirmed,
            }
        )
        suite_path = self._write_suite(suite)
        args = argparse.Namespace(
            repo_root=str(self.base),
            suite=str(suite_path),
            module="",
            project="",
            date="2026-11-26",
            authorize=True,
        )
        self.assertEqual(mod.cmd_collect(args), 0)
        case = self._read_suite(suite_path)["cases"][0]
        self.assertEqual(case["maturity"], "stable")
        self.assertEqual(case["consecutivePasses"], 2)
        self.assertEqual(case["confirmedBug"], confirmed)

    # ---- ④ confirmed-bug 收到 passed 仍是 confirmed-bug ----
    def test_04_confirmed_bug_not_auto_promoted_by_passed(self):
        suite = self._suite()
        suite["cases"][0].update(
            {
                "maturity": "confirmed-bug",
                "confirmedBug": {"at": "2026-11-20", "bugId": "BUG-1", "note": ""},
            }
        )
        suite_path = self._write_suite(suite)
        mod.cmd_promote(self._promote_args(suite_path, "passed"))
        case = self._read_suite(suite_path)["cases"][0]
        self.assertEqual(case["maturity"], "confirmed-bug")
        self.assertEqual(case["lastStatus"], "passed")

    # ---- ⑤ 连续 3 次 passed 后 maturity=stable ----
    def test_05_three_passes_promote_to_stable(self):
        suite_path = self._write_suite(self._suite())
        for _ in range(3):
            mod.cmd_promote(self._promote_args(suite_path, "passed"))
        case = self._read_suite(suite_path)["cases"][0]
        self.assertEqual(case["maturity"], "stable")
        self.assertGreaterEqual(case["consecutivePasses"], 3)

    # ---- ⑥ failed 后 consecutivePasses=0 ----
    def test_06_failed_resets_consecutive_passes(self):
        suite_path = self._write_suite(self._suite())
        for _ in range(2):
            mod.cmd_promote(self._promote_args(suite_path, "passed"))
        self.assertEqual(self._read_suite(suite_path)["cases"][0]["consecutivePasses"], 2)
        mod.cmd_promote(self._promote_args(suite_path, "failed", note="boom"))
        case = self._read_suite(suite_path)["cases"][0]
        self.assertEqual(case["consecutivePasses"], 0)
        self.assertEqual(case["lastStatus"], "failed")
        self.assertEqual(case["lastFailure"]["reason"], "boom")

    # ---- ⑦ select --kind regression 只含 stable + confirmed-bug ----
    def test_07_select_regression_only_stable_and_bug(self):
        cases = []
        for idx, maturity in enumerate(("stable", "confirmed-bug", "draft", "candidate"), 1):
            case = {
                "caseId": f"L4-DDASH-{idx:03d}",
                "file": f"cases/L4-DDASH-{idx:03d}.yaml",
                "name": f"用例{idx}",
                "tags": [],
                "criterion": "M3",
                "maturity": maturity,
            }
            if maturity == "confirmed-bug":
                case["confirmedBug"] = {"at": "2026-11-20", "bugId": "BUG-2", "note": ""}
            cases.append(case)
        suite_path = self._write_suite(self._suite(cases))
        out = self.base / "selected.json"
        args = argparse.Namespace(
            suite=str(suite_path), kind="regression", out=str(out)
        )
        self.assertEqual(mod.cmd_select(args), 0)
        selected = json.loads(out.read_text(encoding="utf-8"))
        ids = [c["caseId"] for c in selected["cases"]]
        self.assertEqual(ids, ["L4-DDASH-001", "L4-DDASH-002"])
        self.assertEqual(selected["schemaVersion"], 1)

    # ---- ⑧ cache-id 子命令 stdout 只有 id 一行 ----
    def test_08_cache_id_subcommand_stdout_single_line(self):
        self._write_case()
        suite_path = self._write_suite(self._suite())
        env = os.environ.copy()
        env["E2E_ROOT"] = str(self.e2e_root)
        env["PYTHONIOENCODING"] = "utf-8"
        result = subprocess.run(
            [sys.executable, "-X", "utf8", str(SUITE_SCRIPT), "cache-id",
             "--repo-root", str(self.base), "--suite", str(suite_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().splitlines()
        self.assertEqual(len(lines), 1, repr(result.stdout))
        self.assertTrue(lines[0].startswith("l4-ddash-"), lines[0])

    # ---- 补充：upsert deprecated 转调 promote ----
    def test_09_upsert_deprecated_delegates_to_promote(self):
        suite_path = self._write_suite(self._suite())
        stderr = mock.patch("sys.stderr", new_callable=lambda: __import__("io").StringIO())
        buf = stderr.start()
        try:
            rc = mod.main([
                "upsert", "--suite", str(suite_path), "--case-id", "L4-DDASH-001",
                "--status", "passed", "--authorize",
            ])
        finally:
            stderr.stop()
        self.assertEqual(rc, 0)
        self.assertIn("upsert is deprecated; use promote", buf.getvalue())
        case = self._read_suite(suite_path)["cases"][0]
        self.assertEqual(case["lastStatus"], "passed")

    # ---- 补充：fixed 显式转正为 candidate ----
    def test_10_fixed_promotes_confirmed_bug_to_candidate(self):
        suite = self._suite()
        suite["cases"][0].update(
            {
                "maturity": "confirmed-bug",
                "consecutivePasses": 0,
                "confirmedBug": {"at": "2026-11-20", "bugId": "BUG-3", "note": ""},
            }
        )
        suite_path = self._write_suite(suite)
        mod.cmd_promote(self._promote_args(suite_path, "fixed"))
        case = self._read_suite(suite_path)["cases"][0]
        self.assertEqual(case["maturity"], "candidate")
        self.assertEqual(case["consecutivePasses"], 0)
        self.assertEqual(case.get("confirmedBug", {}), {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
