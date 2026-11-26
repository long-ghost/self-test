"""把 Midscene Test 运行结果归一化为 l4-summary.json。

summary.json 的字段随 Midscene 版本变化，这里做多形状容错：
- 顶层数组，或 {cases|results|caseResults|files|projects} 嵌套
- 状态字段可能是 status / result / state / passed
- 无法解析时用 result.md 计数兜底，仍无法对上 suite 的用例标 unmapped
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

SENSITIVE_KEY = re.compile(r"(apikey|api_key|token|cookie|authorization|password|passwd|secret)", re.I)
IMAGE_RE = re.compile(r"[^\s\"'<>|]+\.(?:png|jpe?g|webp|gif)", re.I)
STATUS_MAP = {
    "passed": "passed",
    "pass": "passed",
    "success": "passed",
    "succeeded": "passed",
    "ok": "passed",
    "通过": "passed",
    "成功": "passed",
    "failed": "failed",
    "fail": "failed",
    "failure": "failed",
    "error": "failed",
    "errored": "failed",
    "失败": "failed",
    "错误": "failed",
    "skipped": "skipped",
    "skip": "skipped",
    "pending": "skipped",
    "跳过": "skipped",
}


def _read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None


def _norm_status(value) -> str:
    if isinstance(value, bool):
        return "passed" if value else "failed"
    if value is None:
        return ""
    text = str(value).strip().lower()
    return STATUS_MAP.get(text, text)


def _first(entry: dict, keys: tuple[str, ...], default=""):
    for key in keys:
        if key in entry and entry[key] not in (None, "", [], {}):
            return entry[key]
    return default


def _case_like(node) -> bool:
    if not isinstance(node, dict):
        return False
    has_name = any(key in node for key in ("name", "title", "caseName", "caseId"))
    has_status = any(key in node for key in ("status", "result", "state", "passed"))
    return has_name and has_status


def _extract_entries(node, bucket: list[dict], depth: int = 0) -> None:
    if depth > 6:
        return
    if isinstance(node, list):
        if node and all(isinstance(item, dict) for item in node) and any(_case_like(item) for item in node):
            bucket.extend(item for item in node if isinstance(item, dict))
            return
        for item in node:
            _extract_entries(item, bucket, depth + 1)
        return
    if isinstance(node, dict):
        if _case_like(node) and any(isinstance(node.get(key), list) for key in ("steps", "stepResults")):
            bucket.append(node)
            return
        for value in node.values():
            _extract_entries(value, bucket, depth + 1)


def _steps(entry: dict) -> list[dict]:
    raw = _first(entry, ("steps", "stepResults", "step_results"), [])
    if not isinstance(raw, list):
        return []
    steps: list[dict] = []
    for index, item in enumerate(raw, 1):
        if not isinstance(item, dict):
            steps.append({"index": index, "node": "", "status": _norm_status(item), "error": ""})
            continue
        node = str(_first(item, ("node", "nodeName", "name", "type", "action"), ""))
        status = _norm_status(_first(item, ("status", "result", "state", "passed"), ""))
        error = str(_first(item, ("error", "message", "errorMessage", "reason"), ""))
        raw_index = _first(item, ("index", "step", "order"), index)
        try:
            step_index = int(raw_index)
        except (TypeError, ValueError):
            step_index = index
        steps.append({"index": step_index, "node": node, "status": status, "error": error})
    return steps


def _collect_images(node, bucket: list[str], depth: int = 0) -> None:
    if depth > 6:
        return
    if isinstance(node, str):
        for match in IMAGE_RE.finditer(node):
            value = match.group(0)
            if value not in bucket:
                bucket.append(value)
        return
    if isinstance(node, list):
        for item in node:
            _collect_images(item, bucket, depth + 1)
        return
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(value, str) and SENSITIVE_KEY.search(key):
                continue
            _collect_images(value, bucket, depth + 1)


def _counts_from_markdown(text: str) -> dict[str, int]:
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    cell_hits = {"passed": 0, "failed": 0, "skipped": 0}
    for line in text.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [cell.strip().lower() for cell in line.strip().strip("|").split("|")]
        for cell in cells:
            status = STATUS_MAP.get(cell, "")
            if status:
                cell_hits[status] += 1
    if any(cell_hits.values()):
        return cell_hits
    patterns = {
        "passed": r"(\d+)\s*(?:passed|pass|通过)",
        "failed": r"(\d+)\s*(?:failed|fail|失败)",
        "skipped": r"(\d+)\s*(?:skipped|skip|跳过)",
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, text, re.I)
        if match:
            counts[key] = int(match.group(1))
    return counts


def _redact_value(value, secrets: list[str]):
    if isinstance(value, str):
        for secret in secrets:
            if secret and secret in value:
                value = value.replace(secret, "***")
        return value
    if isinstance(value, list):
        return [_redact_value(item, secrets) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if SENSITIVE_KEY.search(str(key)):
                result[key] = "***"
            else:
                result[key] = _redact_value(item, secrets)
        return result
    return value


def _secret_values(payload) -> list[str]:
    values: list[str] = []

    def walk(node):
        if isinstance(node, dict):
            for item in node.values():
                walk(item)
        elif isinstance(node, list):
            for item in node:
                walk(item)
        elif isinstance(node, (str, int, float)) and str(node).strip():
            text = str(node)
            if len(text) >= 4 and text not in values:
                values.append(text)

    walk(payload)
    values.sort(key=len, reverse=True)
    return values


def _normalize_rel(value: str) -> str:
    return value.replace("\\", "/").lstrip("./")


def build_summary(
    results_dir: str | Path,
    suite_path: str | Path,
    staged_path: str | Path | None = None,
    console_path: str | Path | None = None,
    secrets: dict | None = None,
    exit_code: int = 0,
    shots_map: dict | None = None,
) -> dict:
    results = Path(results_dir)
    suite_data = _read_json(Path(suite_path)) or {}
    suite_cases = suite_data.get("cases") if isinstance(suite_data, dict) else []
    if not isinstance(suite_cases, list):
        suite_cases = []
    suite_cases = [item for item in suite_cases if isinstance(item, dict)]

    entries: list[dict] = []
    result_md_text = ""
    if results.is_dir():
        for path in sorted(results.rglob("summary.json")):
            payload = _read_json(path)
            if payload is None:
                continue
            _extract_entries(payload, entries)
        markdown_files = sorted(results.rglob("result.md"))
        if markdown_files:
            result_md_text = markdown_files[0].read_text(encoding="utf-8-sig", errors="replace")

    # console 只用于脱敏兜底：l4-run 已先脱敏写入，这里不再回填到产物
    console_text = ""
    if console_path and Path(console_path).is_file():
        console_text = Path(console_path).read_text(encoding="utf-8-sig", errors="replace")

    shots = shots_map or {}
    normalized: list[dict] = []
    used: set[int] = set()
    counts = {"passed": 0, "failed": 0, "skipped": 0}

    for suite_case in suite_cases:
        name = str(suite_case.get("name", "")).strip()
        su_file = _normalize_rel(str(suite_case.get("file", "")))
        matched_index = None
        for index, entry in enumerate(entries):
            if index in used:
                continue
            entry_name = str(_first(entry, ("name", "title", "caseName"), "")).strip()
            entry_file = _normalize_rel(str(_first(entry, ("file", "path", "document", "documentPath", "source"), "")))
            if name and entry_name == name:
                matched_index = index
                break
            if su_file and entry_file and entry_file.endswith(su_file):
                matched_index = index
                break
            if su_file and entry_file and su_file.endswith(Path(entry_file).name):
                matched_index = index
                break
        if matched_index is None:
            counts["failed"] += 1
            normalized.append(
                {
                    "caseId": str(suite_case.get("caseId", "")),
                    "name": name,
                    "file": str(suite_case.get("file", "")),
                    "status": "missing",
                    "criterion": str(suite_case.get("criterion") or "M3"),
                    "crossVerifiedBy": list(suite_case.get("crossVerifiedBy") or []),
                    "steps": [],
                    "failedStep": None,
                    "screenshots": list(shots.get(str(suite_case.get("caseId", "")), [])),
                    "evidenceLevel": str(suite_case.get("criterion") or "M3"),
                    "unmapped": True,
                }
            )
            continue

        used.add(matched_index)
        entry = entries[matched_index]
        status = _norm_status(_first(entry, ("status", "result", "state", "passed"), ""))
        if status not in counts:
            status = "failed"
        counts[status] += 1
        steps = _steps(entry)
        failed_step = next((step for step in steps if step["status"] == "failed"), None)
        images = list(shots.get(str(suite_case.get("caseId", "")), []))
        if not images:
            found: list[str] = []
            _collect_images(entry, found)
            images = [value for value in found if value.startswith("shots/")]
        normalized.append(
            {
                "caseId": str(suite_case.get("caseId", "")),
                "name": name or str(_first(entry, ("name", "title", "caseName"), "")),
                "file": str(suite_case.get("file", "")),
                "status": status,
                "criterion": str(suite_case.get("criterion") or "M3"),
                "crossVerifiedBy": list(suite_case.get("crossVerifiedBy") or []),
                "steps": steps,
                "failedStep": failed_step,
                "screenshots": images,
                "evidenceLevel": str(suite_case.get("criterion") or "M3"),
                "unmapped": False,
            }
        )

    for index, entry in enumerate(entries):
        if index in used:
            continue
        status = _norm_status(_first(entry, ("status", "result", "state", "passed"), ""))
        if status not in counts:
            status = "failed"
        counts[status] += 1
        steps = _steps(entry)
        images: list[str] = []
        _collect_images(entry, images)
        name = str(_first(entry, ("name", "title", "caseName"), ""))
        normalized.append(
            {
                "caseId": str(_first(entry, ("caseId", "id", "key"), Path(_normalize_rel(str(_first(entry, ("file", "path", "document"), "")))).stem or "UNMAPPED")),
                "name": name,
                "file": str(_first(entry, ("file", "path", "document", "documentPath", "source"), "")),
                "status": status,
                "criterion": "M3",
                "crossVerifiedBy": [],
                "steps": steps,
                "failedStep": next((step for step in steps if step["status"] == "failed"), None),
                "screenshots": [value for value in images if value.startswith("shots/")],
                "evidenceLevel": "M3",
                "unmapped": False,
            }
        )

    if not normalized and result_md_text:
        counts = _counts_from_markdown(result_md_text)

    staged_files: list[dict] = []
    run_id = ""
    suite_sha = ""
    if staged_path and Path(staged_path).is_file():
        staged = _read_json(Path(staged_path))
        if isinstance(staged, dict):
            run_id = str(staged.get("runId", ""))
            suite_sha = str(staged.get("suiteSha256", ""))
            raw_files = staged.get("files", [])
            if isinstance(raw_files, list):
                staged_files = [item for item in raw_files if isinstance(item, dict)]
    if not run_id:
        run_id = results.name or datetime.now().strftime("%Y%m%d-%H%M%S")

    secret_payload = secrets or {}
    secret_values = _secret_values(secret_payload)
    summary = {
        "schemaVersion": 1,
        "runId": run_id,
        "suiteSha256": suite_sha,
        "exitCode": int(exit_code),
        "counts": {
            "total": len(normalized) if normalized else sum(counts.values()),
            "passed": counts["passed"],
            "failed": counts["failed"],
            "skipped": counts["skipped"],
        },
        "cases": normalized,
        "stagedFiles": staged_files,
        "redacted": sorted(str(key) for key in secret_payload.keys()) if isinstance(secret_payload, dict) else [],
    }
    if console_text and not normalized:
        summary["consoleTail"] = "\n".join(console_text.splitlines()[-40:])
    return _redact_value(summary, secret_values)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="归一化 Midscene 运行结果为 l4-summary.json")
    parser.add_argument("--results", required=True)
    parser.add_argument("--suite", required=True)
    parser.add_argument("--staged", default="")
    parser.add_argument("--console", default="")
    parser.add_argument("--out", required=True)
    parser.add_argument("--secrets-json", default="")
    parser.add_argument("--secrets-env", default="", help="逗号分隔的环境变量名，只取值不落盘")
    parser.add_argument("--shots-map", default="")
    parser.add_argument("--exit-code", type=int, default=0)
    args = parser.parse_args(argv)

    secrets = _read_json(Path(args.secrets_json)) if args.secrets_json else {}
    if not isinstance(secrets, dict):
        secrets = {}
    if args.secrets_env:
        for name in re.split(r"[,;]", args.secrets_env):
            name = name.strip()
            value = os.environ.get(name, "")
            if name and value:
                secrets[name] = value
    shots = _read_json(Path(args.shots_map)) if args.shots_map else {}
    summary = build_summary(
        args.results,
        args.suite,
        args.staged or None,
        args.console or None,
        secrets if isinstance(secrets, dict) else {},
        args.exit_code,
        shots if isinstance(shots, dict) else {},
    )
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    counts = summary["counts"]
    print(
        "l4-summary: {pass} passed / {fail} failed / {skip} skipped".format(
            **{"pass": counts["passed"], "fail": counts["failed"], "skip": counts["skipped"]}
        )
    )
    print(str(out_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
