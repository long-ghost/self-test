import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parents[1]
SKILL_DIR = ROOT / "module-test"
SKILL_MD = SKILL_DIR / "SKILL.md"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_frontmatter():
    text = SKILL_MD.read_text(encoding="utf-8")
    assert text.startswith("---")
    match = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    assert match, "invalid frontmatter"
    front = match.group(1)
    assert "name: module-test" in front
    assert "description:" in front
    assert "<" not in front.split("description:", 1)[1].splitlines()[0]


def test_html_report_renders_offline():
    mod = load_module("report_html", SKILL_DIR / "scripts" / "report_html.py")
    header = {
        "结论": "有条件通过",
        "范围": "示例模块",
        "需求来源": "用户口述",
        "需求确认": "用户已确认（2026-11-24 12:00）",
        "执行会话": "新会话",
        "判据构成": "M1 2 / M2 1 / M3 1（未覆盖或仅部分验证 0 条）",
        "用例冻结": "SHA256 0123456789abcdef / 冻结 2026-11-24 12:00",
        "本轮问题": "P0 0 / P1 0 / P2 0 / P3 0",
        "假设": "示例假设",
    }
    cases = [
        {"#": "1", "验收点": "A1", "方法": "判定表", "输入": "示例", "期望": "通过", "期望来源": "用户口述", "实测": "通过", "证据": "命令输出", "判定": "通过 M1"},
        {"#": "2", "验收点": "D1", "方法": "数据对账", "输入": "示例", "期望": "一致", "期望来源": "SQL 反算", "实测": "一致", "证据": "SQL", "判定": "通过 M2"},
    ]
    sections = {"九、未覆盖": "无", "十三、自我反证": "| 1 | 示例 | 假设 | 手段 | 否定 | 证据 |"}
    html = mod.render_html(header, cases, sections, [])
    assert "测试通过" in html
    assert "module-test" in html or "自测报告" in html
    assert "http://" not in html and "https://" not in html


def test_html_report_renders_l4():
    fixture = ROOT / "tests" / "fixtures" / "l4"
    mod = load_module("report_html", SKILL_DIR / "scripts" / "report_html.py")
    header = mod.parse_header((fixture / "report.md").read_text(encoding="utf-8"))
    cases = mod.parse_cases((fixture / "report.md").read_text(encoding="utf-8"))
    sections = mod._parse_sections((fixture / "report.md").read_text(encoding="utf-8"))
    l4 = json.loads((fixture / "l4-summary.json").read_text(encoding="utf-8"))
    html = mod.render_html(header, cases, sections, [], l4)
    assert "L4 端到端（Midscene）" in html
    assert "L4-DEMO-001" in html
    assert "l4/midscene/report.html" in html
    assert "shots/demo.png" in html
    assert "http://" not in html and "https://" not in html


def test_html_report_cli_accepts_l4():
    fixture = ROOT / "tests" / "fixtures" / "l4"
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "report.html"
        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "utf-8"
        result = subprocess.run(
            [
                sys.executable,
                "-X",
                "utf8",
                str(SKILL_DIR / "scripts" / "report_html.py"),
                "--report",
                str(fixture / "report.md"),
                "--cases",
                str(fixture / "cases.md"),
                "--l4",
                str(fixture / "l4-summary.json"),
                "--out",
                str(out),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
        )
        assert result.returncode == 0, result.stderr
        html = out.read_text(encoding="utf-8")
        assert "L4 端到端（Midscene）" in html
        assert "http://" not in html and "https://" not in html


def test_l4_summary_normalizes_and_redacts():
    fixture = ROOT / "tests" / "fixtures" / "l4"
    mod = load_module("l4_summary", SKILL_DIR / "scripts" / "l4_summary.py")
    secret = "sk-test-secret-1234"
    summary = mod.build_summary(
        fixture / "l4",
        fixture / "suite.json",
        secrets={"MIDSCENE_MODEL_API_KEY": secret},
        exit_code=0,
    )
    assert summary["counts"] == {"total": 1, "passed": 1, "failed": 0, "skipped": 0}
    assert summary["cases"][0]["caseId"] == "L4-DEMO-001"
    assert summary["cases"][0]["unmapped"] is False
    assert summary["cases"][0]["status"] == "passed"
    assert summary["redacted"] == ["MIDSCENE_MODEL_API_KEY"]
    assert secret not in json.dumps(summary, ensure_ascii=False)


def test_bug_report_help():
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    result = subprocess.run(
        [sys.executable, "-X", "utf8", str(SKILL_DIR / "scripts" / "bug_report.py"), "--help"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "bugs.json" in result.stdout or "缺陷" in result.stdout


if __name__ == "__main__":
    failures = []
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("PASS", name)
            except Exception as exc:
                failures.append((name, exc))
                print("FAIL", name, repr(exc))
    sys.exit(1 if failures else 0)
