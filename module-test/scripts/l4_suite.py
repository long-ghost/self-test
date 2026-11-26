"""L4 Midscene 套件清单工具：collect / upsert / promote / select / cache-id / explain / export。

套件清单固定为产物根 E2E_ROOT/e2e/midscene/suite.json（默认 <repo>/E2E测试/），一个 YAML 文件只放一条用例。
不依赖 PyYAML：只解析 cases 列表的 name / tags，其余字段以 suite 为准。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import date
from pathlib import Path
import os

CASE_ID_RE = re.compile(r"^L4-[A-Z0-9]+-\d{3}$")
STATUSES = ("passed", "failed", "skipped")
PROMOTE_STATUSES = ("passed", "failed", "skipped", "fixed")
STATUS_CN = {"passed": "通过", "failed": "失败", "skipped": "跳过"}
LIFECYCLE_KEYS = ("maturity", "consecutivePasses", "lastFailure", "confirmedBug")


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


def _module_slug(case_id: str) -> str:
    """模块码小写：L4-DDASH-001 -> ddash；非法编号回退 l4。"""
    match = CASE_ID_RE.match(str(case_id))
    if not match:
        return "l4"
    return str(case_id).split("-")[1].lower()


def stable_cache_id(repo: Path, suite: dict) -> str:
    """按 caseId 排序，拼 caseId|file|YAML 字节 sha256，取整体 sha256 前 8 位。

    只读 caseId / file / YAML 文件内容，绝不读 lastStatus / consecutivePasses /
    maturity 等会被回写的字段，保证执行状态变化不会让 cache id 漂移。
    """
    repo = Path(repo).resolve()
    root = _e2e_root(repo) / "e2e" / "midscene"
    cases = sorted(
        [case for case in suite.get("cases", []) if isinstance(case, dict)],
        key=lambda case: str(case.get("caseId") or ""),
    )
    chunks: list[str] = []
    for case in cases:
        case_id = str(case.get("caseId") or "")
        rel = str(case.get("file") or "")
        yaml_path = (root / rel).resolve()
        try:
            raw = yaml_path.read_bytes()
        except OSError:
            raw = b""
        yaml_sha = hashlib.sha256(raw).hexdigest()
        chunks.append("|".join((case_id, rel, yaml_sha)))

    payload = "\n".join(chunks)
    sha8 = hashlib.sha256(payload.encode("utf-8")).hexdigest()[:8]
    slug = _module_slug(cases[0].get("caseId", "")) if cases else "l4"
    return f"l4-{slug}-{sha8}"


def cmd_cache_id(args: argparse.Namespace) -> int:
    repo = Path(args.repo_root).resolve()
    root = _e2e_root(repo) / "e2e" / "midscene"
    suite_path = Path(args.suite).resolve() if args.suite else root / "suite.json"
    suite = load_suite(suite_path)
    # stdout 只输出 id 一行，供 PowerShell 捕获；不打印日志。
    print(stable_cache_id(repo, suite))
    return 0


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
        "maturity": "draft",
        "consecutivePasses": 0,
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
            merge_keys = (
                "firstSeen", "lastVerified", "lastStatus", "requirementRef",
                "criterion", "crossVerifiedBy",
            ) + LIFECYCLE_KEYS
            for key in merge_keys:
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


def _apply_lifecycle(target: dict, status: str, verified: str, bug_id: str, note: str) -> None:
    """按 promote 规则回写生命周期字段（confirmed-bug 不自动转正）。"""
    maturity = str(target.get("maturity") or "draft")
    if status == "passed":
        if maturity == "confirmed-bug":
            # 反目标：确认是 bug 的用例不能被连续 pass 洗白。
            pass
        else:
            count = int(target.get("consecutivePasses") or 0) + 1
            target["consecutivePasses"] = count
            if count >= 3:
                target["maturity"] = "stable"
    elif status in ("failed", "skipped"):
        target["consecutivePasses"] = 0
        if status == "failed":
            target["lastFailure"] = {
                "at": verified,
                "reason": note,
                "cacheReplan": False,
            }
        if status == "failed" and bug_id:
            target["maturity"] = "confirmed-bug"
            target["confirmedBug"] = {
                "at": verified,
                "bugId": bug_id,
                "note": note,
            }
    elif status == "fixed":
        # 显式修复转正：回到 candidate，清确认信息，重新计数。
        target["maturity"] = "candidate"
        target["consecutivePasses"] = 0
        target["confirmedBug"] = {}


def _promote_write(args: argparse.Namespace) -> int:
    """promote / upsert 共用的写回逻辑。"""
    suite_path = Path(args.suite).resolve()
    if not suite_path.is_file():
        print(f"ERROR: suite 不存在：{suite_path}", file=sys.stderr)
        return 1
    suite = load_suite(suite_path)
    target = next((item for item in suite["cases"] if str(item.get("caseId")) == args.case_id), None)
    if target is None:
        print(f"ERROR: suite 中没有用例 {args.case_id}", file=sys.stderr)
        return 1
    if args.status not in PROMOTE_STATUSES:
        print(f"ERROR: status 只能是 {'/'.join(PROMOTE_STATUSES)}", file=sys.stderr)
        return 1
    verified = args.date or date.today().isoformat()
    print(f"{args.case_id}: lastStatus={args.status} lastVerified={verified}")
    if not args.authorize:
        print("未传 --authorize，只打印，未写回 suite.json")
        return 0
    target["lastStatus"] = args.status
    target["lastVerified"] = verified
    bug_id = str(getattr(args, "bug_id", "") or "")
    note = str(getattr(args, "note", "") or "")
    _apply_lifecycle(target, args.status, verified, bug_id, note)
    write_suite(suite_path, suite)
    print(f"已写回：{suite_path}")
    return 0


def cmd_promote(args: argparse.Namespace) -> int:
    return _promote_write(args)


def cmd_upsert(args: argparse.Namespace) -> int:
    print("upsert is deprecated; use promote", file=sys.stderr)
    return _promote_write(args)


def _history_for_case(repo: Path, case_id: str) -> list[dict]:
    """只读聚合 E2E测试/*/l4/l4-summary.json 中该用例的历史状态。"""
    repo = Path(repo).resolve()
    history: list[dict] = []
    for summary in sorted(_e2e_root(repo).glob("*/l4/l4-summary.json")):
        try:
            payload = json.loads(summary.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        cases = payload.get("cases", []) if isinstance(payload, dict) else []
        for case in cases:
            if isinstance(case, dict) and str(case.get("caseId")) == case_id:
                history.append({
                    "runId": str(payload.get("runId") or ""),
                    "status": str(case.get("status") or ""),
                })
                break
    return history


def cmd_explain(args: argparse.Namespace) -> int:
    repo = Path(args.repo_root).resolve()
    root = _e2e_root(repo) / "e2e" / "midscene"
    suite_path = Path(args.suite).resolve() if args.suite else root / "suite.json"
    suite = load_suite(suite_path)
    target = next((item for item in suite["cases"] if str(item.get("caseId")) == args.case_id), None)
    if target is None:
        print(f"ERROR: suite 中没有用例 {args.case_id}", file=sys.stderr)
        return 1
    print(f"用例：{args.case_id}")
    print(f"生命周期：maturity={target.get('maturity') or 'draft'} "
          f"consecutivePasses={int(target.get('consecutivePasses') or 0)} "
          f"lastStatus={target.get('lastStatus') or ''} "
          f"lastVerified={target.get('lastVerified') or ''}")
    if target.get("lastFailure"):
        print(f"最近失败：{target['lastFailure']}")
    if target.get("confirmedBug"):
        print(f"确认缺陷：{target['confirmedBug']}")
    history = _history_for_case(repo, args.case_id)
    if not history:
        print("无历史")
    else:
        print(f"历史（最近 {min(5, len(history))} 次，共 {len(history)} 次）：")
        for item in history[-5:]:
            print(f"  - {item['runId'] or '(无 runId)'}  {item['status']}")
    return 0


def cmd_select(args: argparse.Namespace) -> int:
    suite_path = Path(args.suite).resolve()
    if not suite_path.is_file():
        print(f"ERROR: suite 不存在：{suite_path}", file=sys.stderr)
        return 1
    suite = load_suite(suite_path)
    kind = args.kind
    if kind not in ("regression", "stable", "bug", "all"):
        print(f"ERROR: kind 只能是 regression/stable/bug/all", file=sys.stderr)
        return 1

    def eligible(case: dict) -> bool:
        maturity = str(case.get("maturity") or "draft")
        if kind in ("regression", "all"):
            return maturity in ("stable", "confirmed-bug")
        if kind == "stable":
            return maturity == "stable"
        return maturity == "confirmed-bug"

    selected = {
        "schemaVersion": 1,
        "project": suite.get("project", "web"),
        "module": suite.get("module", ""),
        "cases": [case for case in suite["cases"] if eligible(case)],
    }
    text = json.dumps(selected, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8", newline="\n")
    else:
        print(text, end="")
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

    cache_id = sub.add_parser("cache-id", help="输出稳定 cache id（stdout 只有 id 一行）")
    cache_id.add_argument("--repo-root", default=".")
    cache_id.add_argument("--suite", default="")
    cache_id.set_defaults(func=cmd_cache_id)

    promote = sub.add_parser("promote", help="更新执行结果并推进生命周期")
    promote.add_argument("--suite", required=True)
    promote.add_argument("--case-id", required=True)
    promote.add_argument("--status", required=True, choices=PROMOTE_STATUSES)
    promote.add_argument("--date", default="")
    promote.add_argument("--bug-id", default="")
    promote.add_argument("--note", default="")
    promote.add_argument("--authorize", action="store_true")
    promote.set_defaults(func=cmd_promote)

    upsert = sub.add_parser("upsert", help="[deprecated] 用 promote 代替")
    upsert.add_argument("--suite", required=True)
    upsert.add_argument("--case-id", required=True)
    upsert.add_argument("--status", required=True, choices=PROMOTE_STATUSES)
    upsert.add_argument("--date", default="")
    upsert.add_argument("--bug-id", default="")
    upsert.add_argument("--note", default="")
    upsert.add_argument("--authorize", action="store_true")
    upsert.set_defaults(func=cmd_upsert)

    select = sub.add_parser("select", help="按成熟度筛选回归用例")
    select.add_argument("--suite", required=True)
    select.add_argument("--kind", required=True, choices=("regression", "stable", "bug", "all"))
    select.add_argument("--out", default="")
    select.set_defaults(func=cmd_select)

    explain = sub.add_parser("explain", help="打印用例生命周期与历史摘要")
    explain.add_argument("--repo-root", default=".")
    explain.add_argument("--suite", default="")
    explain.add_argument("--case-id", required=True)
    explain.set_defaults(func=cmd_explain)

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
