"""L4 Midscene 套件清单工具：collect / upsert / export。

套件清单固定为产物根 E2E_ROOT/e2e/midscene/suite.json（默认 <repo>/E2E测试/），一个 YAML 文件只放一条用例。
不依赖 PyYAML：只解析 cases 列表的 name / tags，其余字段以 suite 为准。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path
import os

CASE_ID_RE = re.compile(r"^L4-[A-Z0-9]+-\d{3}$")
STATUSES = ("passed", "failed", "skipped")
STATUS_CN = {"passed": "通过", "failed": "失败", "skipped": "跳过"}


def _e2e_root(repo: Path) -> Path:
    """产物根：环境变量 E2E_ROOT > project-profile.md 的 E2E_ROOT= > <repo>/E2E测试。"""
    import re as _re
    raw = os.environ.get("E2E_ROOT", "").strip()
    if not raw:
        skill_root = Path(__file__).resolve().parent.parent
        profile = skill_root / "references" / "project-profile.md"
        if profile.is_file():
            for line in profile.read_text(encoding="utf-8").splitlines():
                match = _re.match(r"^\s*E2E_ROOT\s*[:=]\s*(.+?)\s*$", line)
                if match:
                    raw = _unquote(match.group(1))
                    break
    if not raw:
        raw = "E2E测试"
    path = Path(raw)
    return path.resolve() if path.is_absolute() else (repo / path).resolve()


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def parse_cases(text: str) -> list[dict]:
    """轻量解析顶层 cases 列表，返回 [{'name': str, 'tags': [str]}]。"""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line and not line.startswith((" ", "\t")) and re.match(r"^cases\s*:\s*(?:#.*)?$", line.rstrip()):
            start = index
            break
    if start is None:
        return []

    cases: list[dict] = []
    current: dict | None = None
    item_indent: int | None = None
    content_indent = 0
    tag_block = False
    tag_indent = 0

    for raw in lines[start + 1 :]:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        stripped = raw.strip()

        if item_indent is None:
            match = re.match(r"^(\s*)-\s+(.*)$", raw)
            if not match:
                if indent == 0:
                    break
                continue
            item_indent = len(match.group(1))
            content_indent = item_indent + 2

        if indent < item_indent:
            break
        if indent == item_indent and stripped.startswith("-"):
            current = {"name": "", "tags": []}
            cases.append(current)
            tag_block = False
            inline = stripped[1:].strip()
            match = re.match(r"^name\s*:\s*(.+)$", inline)
            if match:
                current["name"] = _unquote(match.group(1))
            continue
        if current is None:
            continue

        if indent == content_indent:
            match = re.match(r"^name\s*:\s*(.+)$", stripped)
            if match:
                current["name"] = _unquote(match.group(1))
                tag_block = False
                continue
            match = re.match(r"^tags\s*:\s*(.*)$", stripped)
            if match:
                value = match.group(1).strip()
                if value.startswith("[") and value.endswith("]"):
                    current["tags"] = [
                        _unquote(part.strip())
                        for part in value[1:-1].split(",")
                        if part.strip()
                    ]
                    tag_block = False
                elif value:
                    current["tags"] = [_unquote(value)]
                    tag_block = False
                else:
                    tag_block = True
                    tag_indent = indent
                continue
            tag_block = False
        elif tag_block and indent > tag_indent and stripped.startswith("-"):
            current["tags"].append(_unquote(stripped[1:].strip()))
        else:
            tag_block = False

    return cases


def load_suite(path: Path) -> dict:
    if not path.is_file():
        return {"schemaVersion": 1, "project": "web", "module": "", "cases": []}
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError(f"suite 必须是对象：{path}")
    data.setdefault("schemaVersion", 1)
    data.setdefault("project", "web")
    data.setdefault("module", "")
    data.setdefault("cases", [])
    if not isinstance(data["cases"], list):
        raise ValueError("suite.cases 必须是数组")
    return data


def write_suite(path: Path, suite: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(suite, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def _case_files(root: Path) -> list[Path]:
    cases_dir = root / "cases"
    if not cases_dir.is_dir():
        return []
    files = sorted(
        [p for p in cases_dir.rglob("*.yaml") if not p.name.endswith(".draft.yaml")]
        + [p for p in cases_dir.rglob("*.yml") if not p.name.endswith(".draft.yml")]
    )
    return files


def _entry_defaults(case_id: str, rel: str, parsed: dict, today: str) -> dict:
    return {
        "caseId": case_id,
        "file": rel,
        "name": parsed["name"],
        "tags": parsed["tags"],
        "requirementRef": "",
        "criterion": "M3",
        "crossVerifiedBy": [],
        "firstSeen": today,
        "lastVerified": "",
        "lastStatus": "",
    }


def cmd_collect(args: argparse.Namespace) -> int:
    repo = Path(args.repo_root).resolve()
    root = _e2e_root(repo) / "e2e" / "midscene"
    suite_path = Path(args.suite).resolve() if args.suite else root / "suite.json"
    suite = load_suite(suite_path)

    errors: list[str] = []
    parsed_entries: list[dict] = []
    if not root.is_dir():
        errors.append(f"未找到 {root}（先创建 E2E_ROOT/e2e/midscene/cases/）")

    today = args.date or date.today().isoformat()
    for path in _case_files(root):
        rel = path.relative_to(root).as_posix()
        try:
            cases = parse_cases(path.read_text(encoding="utf-8-sig"))
        except OSError as exc:
            errors.append(f"{rel} 读取失败：{exc}")
            continue
        if len(cases) != 1:
            errors.append(f"{rel} 含 {len(cases)} 条用例；契约要求一个文件只放一条")
            continue
        if not cases[0]["name"]:
            errors.append(f"{rel} 缺 cases[0].name")
            continue
        case_id = path.stem
        if not CASE_ID_RE.match(case_id):
            errors.append(f"{rel} 文件名不是合法用例编号（L4-<模块码>-NNN）")
            continue
        parsed_entries.append(_entry_defaults(case_id, rel, cases[0], today))

    if errors:
        for item in errors:
            print(f"ERROR: {item}", file=sys.stderr)
        return 1

    existing_by_id = {str(item.get("caseId")): item for item in suite["cases"]}
    existing_by_file = {str(item.get("file")): item for item in suite["cases"]}
    merged: list[dict] = []
    added: list[str] = []
    updated: list[str] = []
    for entry in sorted(parsed_entries, key=lambda item: item["caseId"]):
        old = existing_by_id.get(entry["caseId"]) or existing_by_file.get(entry["file"])
        if old:
            for key in ("firstSeen", "lastVerified", "lastStatus", "requirementRef", "criterion", "crossVerifiedBy"):
                if key in old and old[key] not in (None, ""):
                    entry[key] = old[key]
            if old.get("file") != entry["file"] or old.get("name") != entry["name"]:
                updated.append(entry["caseId"])
        else:
            added.append(entry["caseId"])
        merged.append(entry)

    merged_ids = {entry["caseId"] for entry in merged}
    merged_files = {entry["file"] for entry in merged}
    removed = [
        str(item.get("caseId"))
        for item in suite["cases"]
        if str(item.get("caseId")) not in merged_ids and str(item.get("file")) not in merged_files
    ]

    module = args.module or suite.get("module") or ""
    if not module:
        print("WARN: suite.module 为空，请用 --module 指定被测模块名", file=sys.stderr)
    suite = {
        "schemaVersion": 1,
        "project": args.project or suite.get("project") or "web",
        "module": module,
        "cases": merged,
    }

    print(f"套件：{suite_path}")
    print(f"扫描：{len(parsed_entries)} 条 / 新增 {len(added)} / 更新 {len(updated)} / 移除 {len(removed)}")
    if added:
        print("  新增：" + "、".join(added))
    if updated:
        print("  更新：" + "、".join(updated))
    if removed:
        print("  移除：" + "、".join(removed))

    if not args.authorize:
        print("未传 --authorize，只打印差异，未写回 suite.json")
        return 0
    write_suite(suite_path, suite)
    print(f"已写回：{suite_path}")
    return 0


def cmd_upsert(args: argparse.Namespace) -> int:
    suite_path = Path(args.suite).resolve()
    if not suite_path.is_file():
        print(f"ERROR: suite 不存在：{suite_path}", file=sys.stderr)
        return 1
    suite = load_suite(suite_path)
    target = next((item for item in suite["cases"] if str(item.get("caseId")) == args.case_id), None)
    if target is None:
        print(f"ERROR: suite 中没有用例 {args.case_id}", file=sys.stderr)
        return 1
    if args.status not in STATUSES:
        print(f"ERROR: status 只能是 {'/'.join(STATUSES)}", file=sys.stderr)
        return 1
    verified = args.date or date.today().isoformat()
    print(f"{args.case_id}: lastStatus={args.status} lastVerified={verified}")
    if not args.authorize:
        print("未传 --authorize，只打印，未写回 suite.json")
        return 0
    target["lastStatus"] = args.status
    target["lastVerified"] = verified
    write_suite(suite_path, suite)
    print(f"已写回：{suite_path}")
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    suite_path = Path(args.suite).resolve()
    if not suite_path.is_file():
        print(f"ERROR: suite 不存在：{suite_path}", file=sys.stderr)
        return 1
    suite = load_suite(suite_path)
    lines = [
        "| 用例编号 | 业务断言 | 判据 | 交叉核验 | 实测 | 证据 | 判定 |",
        "|---|---|---|---|---|---|---|",
    ]
    for item in suite["cases"]:
        status = str(item.get("lastStatus") or "")
        criterion = str(item.get("criterion") or "M3")
        cross = "；".join(str(part) for part in item.get("crossVerifiedBy") or []) or "—"
        actual = STATUS_CN.get(status, "—")
        verdict = f"{actual} {criterion}" if status else "—"
        evidence = f"l4/midscene/report.html" if status else "—"
        lines.append(
            "| {caseId} | {name} | {criterion} | {cross} | {actual} | {evidence} | {verdict} |".format(
                caseId=item.get("caseId", "—"),
                name=item.get("name", "—"),
                criterion=criterion,
                cross=cross,
                actual=actual,
                evidence=evidence,
                verdict=verdict,
            )
        )
    text = "\n".join(lines) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8", newline="\n")
        print(f"已写入：{args.out}")
    else:
        print(text, end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="L4 Midscene 套件清单工具")
    sub = parser.add_subparsers(dest="command", required=True)

    collect = sub.add_parser("collect", help="扫描 cases/ 生成或更新 suite.json")
    collect.add_argument("--repo-root", default=".")
    collect.add_argument("--suite", default="")
    collect.add_argument("--module", default="")
    collect.add_argument("--project", default="")
    collect.add_argument("--date", default="")
    collect.add_argument("--authorize", action="store_true")
    collect.set_defaults(func=cmd_collect)

    upsert = sub.add_parser("upsert", help="更新单条用例执行结果")
    upsert.add_argument("--suite", required=True)
    upsert.add_argument("--case-id", required=True)
    upsert.add_argument("--status", required=True, choices=STATUSES)
    upsert.add_argument("--date", default="")
    upsert.add_argument("--authorize", action="store_true")
    upsert.set_defaults(func=cmd_upsert)

    export = sub.add_parser("export", help="输出十五节可粘贴的 Markdown 表")
    export.add_argument("--suite", required=True)
    export.add_argument("--out", default="")
    export.set_defaults(func=cmd_export)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
