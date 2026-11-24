#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""缺陷记录生成器：bugs.json -> bugs.xlsx + zentao_bugs.json（可选调用禅道 API）。

只写调用方指定的输出文件，不修改仓库业务文件。
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parents[1]
DEFAULT_OWNERS = SKILL_DIR / "references" / "code-owners.json"

SEVERITY = {
    "P0": {"label": "1-致命", "severity": 1, "pri": 1, "fill": "FFC7CE"},
    "P1": {"label": "2-严重", "severity": 2, "pri": 2, "fill": "FFD8A8"},
    "P2": {"label": "3-一般", "severity": 3, "pri": 3, "fill": "FFF3BF"},
    "P3": {"label": "4-轻微", "severity": 4, "pri": 4, "fill": "E9ECEF"},
}
TYPE_MAP = {
    "功能": {"label": "代码错误", "zentao": "codeerror"},
    "接口": {"label": "代码错误", "zentao": "codeerror"},
    "数据": {"label": "其他", "zentao": "others"},
    "规范": {"label": "标准规范", "zentao": "standard"},
}
DETAIL_HEADERS = [
    "缺陷编号", "所属产品", "所属模块", "缺陷标题", "严重等级", "优先级", "缺陷类型",
    "复现步骤", "预期结果", "实际结果", "接口地址", "请求方法", "请求参数",
    "响应摘要", "截图/证据", "责任人", "责任人来源", "测试环境", "用例编号",
    "发现时间", "禅道状态", "备注",
]
ZENTAO_HEADERS = [
    "所属产品", "所属模块", "所属项目", "所属执行", "缺陷标题", "严重程度",
    "优先级", "缺陷类型", "操作系统", "浏览器", "重现步骤", "结果", "期望",
    "关键词", "指派给", "抄送", "截止日期", "预计工时", "实际工时", "邮件通知",
]
WIDTHS = {
    "缺陷编号": 18, "所属产品": 14, "所属模块": 16, "缺陷标题": 36,
    "严重等级": 10, "优先级": 8, "缺陷类型": 10, "复现步骤": 48,
    "预期结果": 24, "实际结果": 28, "接口地址": 34, "请求方法": 9,
    "请求参数": 32, "响应摘要": 32, "截图/证据": 28, "责任人": 10,
    "责任人来源": 12, "测试环境": 10, "用例编号": 10, "发现时间": 19,
    "禅道状态": 10, "备注": 24, "操作系统": 10, "浏览器": 10,
    "重现步骤": 48, "结果": 28, "期望": 24, "关键词": 14,
    "指派给": 10, "抄送": 12, "截止日期": 12, "预计工时": 9,
    "实际工时": 9, "邮件通知": 9, "所属项目": 12, "所属执行": 12,
}


def warn(msg):
    print(f"[warn] {msg}", file=sys.stderr)


def text(v):
    if v is None:
        return ""
    if isinstance(v, (list, tuple)):
        return "\n".join(str(x) for x in v)
    return str(v)


def steps_text(bug):
    raw = bug.get("steps")
    if isinstance(raw, (list, tuple)):
        return "\n".join(f"{i}. {text(x)}" for i, x in enumerate(raw, 1))
    return text(raw)


def load_owners(path):
    p = Path(path) if path else DEFAULT_OWNERS
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        owners = data.get("owners") if isinstance(data, dict) else data
        return owners if isinstance(owners, dict) else {}
    except Exception as e:
        warn(f"责任人映射读取失败：{e}")
        return {}


def owner_from_map(owners, bug):
    module = text(bug.get("module")).strip()
    files = [text(x) for x in (bug.get("files") or [])]
    if module and module in owners:
        return owners[module], "映射表"
    for key, val in owners.items():
        if key.startswith("_") or not isinstance(val, str):
            continue
        if any(fnmatch.fnmatch(f, key) or f.startswith(key) for f in files):
            return val, "映射表"
    return None, ""


def git_author(repo, file_path, line=None):
    try:
        if line:
            cmd = ["git", "-C", str(repo), "blame", "-L", f"{line},{line}",
                   "--porcelain", "--", file_path]
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            name = ""
            for row in (out.stdout or "").splitlines():
                if row.startswith("author "):
                    name = row[7:].strip()
            if name:
                return name, "git blame"
        cmd = ["git", "-C", str(repo), "log", "-1", "--format=%an", "--", file_path]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        name = (out.stdout or "").strip().splitlines()
        if name:
            return name[0].strip(), "git log"
    except Exception:
        return None, ""
    return None, ""


def resolve_owner(bug, owners, repo):
    if text(bug.get("owner")).strip():
        return text(bug["owner"]).strip(), text(bug.get("owner_source")) or "用例指定"
    name, src = owner_from_map(owners, bug)
    if name:
        return name, src
    lines = bug.get("file_lines") or {}
    for f in (bug.get("files") or []):
        f = text(f)
        name, src = git_author(repo, f, lines.get(f) if isinstance(lines, dict) else None)
        if name:
            return name, src
    return "待确认", "未找到"


def normalize_bug(raw, idx, meta, owners, repo):
    bug = dict(raw or {})
    bug["severity"] = text(bug.get("severity") or "P2").upper()
    if bug["severity"] not in SEVERITY:
        warn(f"第 {idx} 条严重等级非法（{bug['severity']}），按 P2 处理")
        bug["severity"] = "P2"
    bug["type"] = text(bug.get("type") or "功能")
    if bug["type"] not in TYPE_MAP:
        warn(f"第 {idx} 条缺陷类型非法（{bug['type']}），按 功能 处理")
        bug["type"] = "功能"
    bug["module"] = text(bug.get("module") or "未分类")
    bug["product"] = text(bug.get("product") or meta.get("product") or "")
    bug["title"] = text(bug.get("title") or f"未命名缺陷-{idx}")
    bug["steps_text"] = steps_text(bug)
    bug["expected"] = text(bug.get("expected"))
    bug["actual"] = text(bug.get("actual"))
    bug["description"] = text(bug.get("description"))
    bug["preconditions"] = text(bug.get("preconditions"))
    bug["env"] = text(bug.get("env") or meta.get("env") or "")
    bug["test_case_id"] = text(bug.get("test_case_id"))
    bug["discovered_at"] = text(bug.get("discovered_at") or datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    bug["notes"] = text(bug.get("notes"))
    bug["screenshot"] = text(bug.get("screenshot"))
    bug["api_url"] = text(bug.get("api_url"))
    bug["api_method"] = text(bug.get("api_method"))
    bug["api_request"] = text(bug.get("api_request"))
    bug["api_response"] = text(bug.get("api_response"))
    bug["owner"], bug["owner_source"] = resolve_owner(bug, owners, repo)
    bug["bug_id"] = text(bug.get("bug_id") or
                        f"BUG-{datetime.now():%Y%m%d}-{idx:03d}")
    bug["zentao_status"] = text(bug.get("zentao_status") or "未提交")
    return bug


def validate(bug):
    missing = []
    if not bug["title"] or bug["title"].startswith("未命名"):
        missing.append("title")
    if not bug["module"] or bug["module"] == "未分类":
        missing.append("module")
    if not bug["steps_text"]:
        missing.append("steps")
    if not bug["expected"]:
        missing.append("expected")
    if not bug["actual"]:
        missing.append("actual")
    if not (bug["screenshot"] or bug["api_url"]):
        missing.append("screenshot/api_url")
    return missing


def zentao_steps(bug):
    parts = []
    if bug["preconditions"]:
        parts.append(f"<p><b>前置条件：</b>{bug['preconditions']}</p>")
    if bug["description"]:
        parts.append(f"<p><b>说明：</b>{bug['description']}</p>")
    parts.append("<p><b>复现步骤：</b></p><ol>")
    for s in [x for x in bug["steps_text"].splitlines() if x.strip()]:
        clean = re.sub(r"^\s*\d+[.、]\s*", "", s).strip()
        parts.append(f"<li>{clean}</li>")
    parts.append("</ol>")
    parts.append(f"<p><b>期望：</b>{bug['expected']}</p>")
    parts.append(f"<p><b>实际：</b>{bug['actual']}</p>")
    if bug["api_url"]:
        api = bug["api_url"]
        method = bug["api_method"].strip()
        if method and not api.upper().startswith(method.upper() + " "):
            api = f"{method} {api}"
        parts.append(f"<p><b>接口：</b>{api}</p>")
    if bug["screenshot"]:
        parts.append(f"<p><b>截图：</b>{bug['screenshot']}</p>")
    return "".join(parts)


def build_payload(bug, meta):
    sev = SEVERITY[bug["severity"]]
    return {
        "product": bug.get("zentao_product") or bug.get("product") or "",
        "module": bug.get("zentao_module") or bug.get("module") or "",
        "title": bug["title"],
        "severity": sev["severity"],
        "pri": sev["pri"],
        "type": TYPE_MAP[bug["type"]]["zentao"],
        "steps": zentao_steps(bug),
        "assignedTo": "" if bug["owner"] == "待确认" else bug["owner"],
        "openedBy": text(meta.get("tester") or "AI"),
        "os": bug.get("env") or "",
        "browser": text(bug.get("browser")),
        "version": text(bug.get("version")),
        "keywords": bug["module"],
    }


def build_excel(bugs, meta, out_path, input_dir):
    try:
        from openpyxl import Workbook
        from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
        from openpyxl.utils import get_column_letter
        from openpyxl.worksheet.datavalidation import DataValidation
    except ImportError:
        print("需要 openpyxl：python -m pip install openpyxl", file=sys.stderr)
        raise SystemExit(3)

    wb = Workbook()
    ws = wb.active
    ws.title = "缺陷明细"
    head_fill = PatternFill("solid", fgColor="1F4E78")
    head_font = Font(bold=True, color="FFFFFF")
    thin = Side(style="thin", color="D9DEE5")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    wrap = Alignment(wrap_text=True, vertical="top")

    ws.append(DETAIL_HEADERS)
    for c in range(1, len(DETAIL_HEADERS) + 1):
        cell = ws.cell(row=1, column=c)
        cell.fill = head_fill
        cell.font = head_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        cell.border = border
        ws.column_dimensions[get_column_letter(c)].width = WIDTHS.get(DETAIL_HEADERS[c - 1], 16)
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = f"A1:{get_column_letter(len(DETAIL_HEADERS))}{len(bugs) + 1}"

    for r, bug in enumerate(bugs, 2):
        vals = [
            bug["bug_id"], bug["product"], bug["module"], bug["title"],
            bug["severity"], SEVERITY[bug["severity"]]["pri"], bug["type"],
            bug["steps_text"], bug["expected"], bug["actual"], bug["api_url"],
            bug["api_method"], bug["api_request"], bug["api_response"],
            bug["screenshot"], bug["owner"], bug["owner_source"], bug["env"],
            bug["test_case_id"], bug["discovered_at"], bug["zentao_status"],
            bug["notes"],
        ]
        for c, v in enumerate(vals, 1):
            cell = ws.cell(row=r, column=c, value=v)
            cell.border = border
            cell.alignment = wrap
        sev_cell = ws.cell(row=r, column=5)
        sev_cell.fill = PatternFill("solid", fgColor=SEVERITY[bug["severity"]]["fill"])
        shot = bug["screenshot"]
        if shot:
            p = (input_dir / shot).resolve()
            if p.exists():
                sc = ws.cell(row=r, column=15)
                sc.hyperlink = str(p)
                sc.font = Font(color="0563C1", underline="single")

    dv_sev = DataValidation(type="list", formula1='"P0,P1,P2,P3"', allow_blank=False)
    dv_type = DataValidation(type="list", formula1='"功能,接口,数据,规范"', allow_blank=False)
    ws.add_data_validation(dv_sev)
    ws.add_data_validation(dv_type)
    if bugs:
        dv_sev.add(f"E2:E{len(bugs) + 1}")
        dv_type.add(f"G2:G{len(bugs) + 1}")

    ws2 = wb.create_sheet("禅道导入")
    ws2.append(ZENTAO_HEADERS)
    for c in range(1, len(ZENTAO_HEADERS) + 1):
        cell = ws2.cell(row=1, column=c)
        cell.fill = head_fill
        cell.font = head_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        cell.border = border
        ws2.column_dimensions[get_column_letter(c)].width = WIDTHS.get(ZENTAO_HEADERS[c - 1], 16)
    ws2.freeze_panes = "A2"
    for r, bug in enumerate(bugs, 2):
        sev = SEVERITY[bug["severity"]]
        vals = [
            bug["product"], bug.get("zentao_module") or bug["module"], "", "",
            bug["title"], sev["severity"], sev["pri"], TYPE_MAP[bug["type"]]["label"],
            bug["env"], "", bug["steps_text"], bug["actual"], bug["expected"],
            bug["module"], "" if bug["owner"] == "待确认" else bug["owner"], "",
            "", "", "", "0",
        ]
        for c, v in enumerate(vals, 1):
            cell = ws2.cell(row=r, column=c, value=v)
            cell.border = border
            cell.alignment = wrap

    ws3 = wb.create_sheet("说明")
    rows = [
        ("生成时间", datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
        ("轮次", text(meta.get("round"))),
        ("测试环境", text(meta.get("env"))),
        ("缺陷数", len(bugs)),
        ("待确认责任人", sum(1 for b in bugs if b["owner"] == "待确认")),
        ("禅道导入", "优先用「禅道导入」sheet；不同禅道版本列名可能不同，导入前用目标实例模板核对。"),
        ("API/MCP", "使用同目录 zentao_bugs.json；token 只从环境变量读取，不写入本文件。"),
        ("敏感信息", "本文件不应包含密码、token、cookie；请求参数中的手机号等请脱敏。"),
    ]
    for i, (k, v) in enumerate(rows, 1):
        ws3.cell(row=i, column=1, value=k).font = Font(bold=True)
        ws3.cell(row=i, column=2, value=v)
        ws3.column_dimensions["A"].width = 18
        ws3.column_dimensions["B"].width = 100

    out_path.parent.mkdir(parents=True, exist_ok=True)
    wb.save(out_path)


def send_zentao(payload, base, token, header, endpoint):
    errors = 0
    for bug in payload["bugs"]:
        product = bug.get("product") or os.getenv("ZENTAO_PRODUCT_ID", "")
        url = endpoint.format(base=base.rstrip("/"), product=product)
        req = urllib.request.Request(
            url, data=json.dumps(bug, ensure_ascii=False).encode("utf-8"),
            headers={header: token, "Content-Type": "application/json"},
            method="POST")
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = resp.read().decode("utf-8", "ignore")
                print(f"[zentao] {bug['title']} -> HTTP {resp.status} {body[:160]}")
        except urllib.error.HTTPError as e:
            errors += 1
            print(f"[zentao] {bug['title']} -> HTTP {e.code} {e.read().decode('utf-8', 'ignore')[:160]}",
                  file=sys.stderr)
        except Exception as e:
            errors += 1
            print(f"[zentao] {bug['title']} -> {type(e).__name__}: {e}", file=sys.stderr)
    return errors


def main():
    ap = argparse.ArgumentParser(description="缺陷记录生成器（Excel + 禅道 payload）")
    ap.add_argument("--input", required=True, help="bugs.json 路径")
    ap.add_argument("--out", default="", help="输出 Excel；默认同目录 bugs.xlsx")
    ap.add_argument("--payload-out", default="", help="输出禅道 payload；默认同目录 zentao_bugs.json")
    ap.add_argument("--owners", default=str(DEFAULT_OWNERS), help="责任人映射 JSON")
    ap.add_argument("--repo", default=".", help="git 仓库根目录")
    ap.add_argument("--zentao", action="store_true", help="真正调用禅道 API")
    ap.add_argument("--zentao-dry-run", action="store_true", help="只打印将发送的 payload")
    ap.add_argument("--allow-incomplete", action="store_true", help="字段不全时仍生成 Excel")
    args = ap.parse_args()

    input_path = Path(args.input).resolve()
    if not input_path.exists():
        print(f"找不到输入文件：{input_path}", file=sys.stderr)
        return 2
    raw = json.loads(input_path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        meta = {k: v for k, v in raw.items() if k != "bugs"}
        raw_bugs = raw.get("bugs") or []
    else:
        meta, raw_bugs = {}, raw
    if not raw_bugs:
        print("0 条缺陷，跳过生成（报告写「缺陷记录：0 条」即可）")
        return 0

    owners = load_owners(args.owners)
    repo = Path(args.repo).resolve()
    bugs = [normalize_bug(b, i, meta, owners, repo) for i, b in enumerate(raw_bugs, 1)]

    incomplete = []
    for b in bugs:
        miss = validate(b)
        if miss:
            incomplete.append((b["bug_id"], miss))
            warn(f"{b['bug_id']} 缺字段：{', '.join(miss)}")

    out = Path(args.out) if args.out else input_path.with_name("bugs.xlsx")
    payload_out = (Path(args.payload_out) if args.payload_out
                   else input_path.with_name("zentao_bugs.json"))
    build_excel(bugs, meta, out, input_path.parent)

    endpoint = os.getenv(
        "ZENTAO_BUG_ENDPOINT",
        "{base}/api.php/v1/products/{product}/bugs")
    payload = {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "round": text(meta.get("round")),
        "endpoint": endpoint,
        "bugs": [build_payload(b, meta) for b in bugs],
    }
    payload_out.parent.mkdir(parents=True, exist_ok=True)
    payload_out.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"Excel: {out}")
    print(f"ZenTao payload: {payload_out}")
    print(f"缺陷 {len(bugs)} 条；责任人待确认 {sum(1 for b in bugs if b['owner'] == '待确认')} 条")

    if args.zentao_dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=1)[:4000])
        return 0

    if args.zentao:
        base = os.getenv("ZENTAO_BASE_URL", "")
        token = os.getenv("ZENTAO_TOKEN", "")
        header = os.getenv("ZENTAO_TOKEN_HEADER", "Token")
        if not base or not token:
            print("缺少 ZENTAO_BASE_URL / ZENTAO_TOKEN，未发送。Excel 与 payload 已生成。",
                  file=sys.stderr)
            return 2
        errors = send_zentao(payload, base, token, header, endpoint)
        if errors:
            print(f"禅道写入失败 {errors} 条", file=sys.stderr)
            return 1

    if incomplete and not args.allow_incomplete:
        print("存在字段不全的缺陷，补全后重跑；或加 --allow-incomplete 先出草稿。",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
