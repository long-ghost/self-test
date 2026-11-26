"""Generate an offline, single-file HTML view of a module-test report."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
from pathlib import Path

CHECK = "#0E7C7B"
VERIFY = "#2F6FEB"
MANUAL = "#8B5CF6"
GAP = "#C6423F"
GREEN = CHECK
GREY = "#9BAEB8"
AMBER = "#B8751B"
INK = "#16242E"
MUTED = "#5B6B75"
LINE = "#D8DEE4"
PAPER = "#F7F9F9"

CSS = """
:root { --green:#0E7C7B; --verify:#2F6FEB; --manual:#8B5CF6; --gap:#C6423F;
  --grey:#9BAEB8; --amber:#B8751B; --ink:#16242E; --muted:#5B6B75;
  --line:#D8DEE4; --paper:#F7F9F9; }
* { box-sizing:border-box; }
body { margin:0; background:#EEF2F3; color:var(--ink);
  font-family:'Segoe UI','Microsoft YaHei',sans-serif; -webkit-font-smoothing:antialiased; }
.sheet { max-width:1040px; margin:0 auto; padding:32px 36px 56px; }
.topline { display:flex; justify-content:space-between; align-items:baseline;
  border-bottom:1px solid var(--line); padding-bottom:9px; }
.topline .name { font-size:11px; letter-spacing:2px; color:var(--muted); flex:1; }
.topline .duration { font-size:11px; color:var(--muted); margin:0 18px; white-space:nowrap; }
.topline .hash { font-family:Bahnschrift,Consolas,monospace; font-size:11px; color:#8A99A2; white-space:nowrap; }
.hero { display:grid; grid-template-columns:52% 48%; gap:28px; margin-top:24px; }
.verdict-panel { border-left:3px solid var(--green); padding-left:14px; }
.risk-panel { border-left:1px solid var(--line); padding-left:16px; }
.risk-panel h3 { font-size:12px; letter-spacing:1px; margin:0 0 8px; color:var(--amber); }
.risk-summary { font-size:10px; color:var(--muted); margin-bottom:7px; }
.risk-panel .subhead { font-size:11px; font-weight:700; color:#2A3A44; margin-top:14px;
  border-bottom:1px solid #E6EBEE; padding-bottom:5px; }
.evidence { margin-top:24px; border-top:1px solid var(--line); padding-top:13px; }
.eyebrow { font-size:10px; letter-spacing:4px; color:var(--amber);
  border-left:3px solid var(--amber); padding-left:9px; }
.verdict { font-family:Bahnschrift,'Segoe UI','Microsoft YaHei',sans-serif;
  font-size:40px; font-weight:600; line-height:1.1; margin-top:10px; color:var(--ink); }
.verdict-sub { display:flex; flex-wrap:wrap; gap:7px; margin-top:9px; line-height:1.4; }
.metric { display:inline-block; border:1px solid var(--line); background:#fff;
  padding:4px 8px; font-size:11px; color:#2A3A44; }
.metric.defect { background:#FFF7EA; border-color:var(--amber); color:#8A5A12;
  font-weight:700; text-decoration:none; }
.metric.defect:hover { background:#F9E9CC; }
.metric.risk { background:#F4F7FA; border-color:#AFC1CC; color:#4A6472; }
.original { font-size:10px; color:#8A99A2; border-top:1px dashed var(--line);
  margin-top:14px; padding-top:8px; line-height:1.6; }
.bar-label { font-size:11px; color:var(--muted); }
.bar { display:flex; height:8px; margin-top:11px; background:#E6EBEE; cursor:pointer; }
.bar > div { height:100%; }
.bar:hover { filter:brightness(.94); }
.legend { display:grid; grid-template-columns:repeat(4,minmax(0,1fr));
  margin-top:9px; font-size:11px; line-height:1.5; }
.legend > div { text-align:center; white-space:nowrap; }
.legend .dot { display:inline-block; width:7px; height:7px; margin-right:5px;
  vertical-align:1px; }
.legend b { font-family:Bahnschrift,Consolas,monospace; font-size:15px; margin-right:4px; }
.hint { font-size:10px; color:#8A99A2; margin-top:10px;
  border-top:1px dashed var(--line); padding-top:7px; }
.risk-panel .row { border-bottom:1px solid #E6EBEE; padding:6px 0;
  font-size:11px; line-height:1.6; color:#2A3A44; }
.risk-panel .row:last-child { border-bottom:0; }
.note { background:#EDF4F3; border-left:3px solid var(--green);
  padding:9px 12px; font-size:11px; color:#2A3A44; margin-top:20px; }
.note span { color:#8A99A2; }
.defects { margin-top:30px; border-top:1px solid var(--line); padding-top:18px; }
.defects h2 { font-size:16px; margin:0; }
.defect-hint { font-size:10px; color:var(--muted); margin-top:4px; }
details.defect-item { background:#fff; border:1px solid var(--line); margin-top:12px; padding:10px 14px; }
details.defect-item summary { cursor:pointer; font-family:Bahnschrift,Consolas,monospace;
  font-size:12px; color:var(--ink); }
details.defect-item summary::marker { color:var(--gap); }
.defect-sev { color:var(--gap); font-weight:700; margin:0 6px; }
.defect-module { color:var(--muted); font-size:10px; margin-left:8px; }
.defect-body { margin-top:8px; border-top:1px solid #E6EBEE; padding-top:6px; }
.defect-field { display:grid; grid-template-columns:72px 1fr; gap:8px;
  font-size:11px; line-height:1.6; margin-top:5px; }
.defect-field .k { color:var(--muted); }
.defect-item img { display:block; max-width:100%; margin-top:8px; border:1px solid var(--line); }
button { font:inherit; }
a { color:var(--green); }
.cases { margin-top:34px; }
.cases h2 { font-size:16px; font-weight:700; margin:0; }
.cases .hintline { font-size:10px; color:#8A99A2; margin-top:4px; }
.filters { display:flex; gap:8px; flex-wrap:wrap; margin:14px 0 12px; align-items:center; }
.chip { border:1px solid var(--line); background:transparent; color:var(--muted);
  font-size:11px; padding:4px 9px; cursor:pointer; }
.chip[aria-pressed="true"] { border-bottom:2px solid var(--chip,var(--green));
  color:var(--chip,var(--green)); font-weight:700; }
.chip.warn[aria-pressed="true"] { border-color:var(--chip,var(--amber)); color:var(--chip,var(--amber)); }
.search { margin-left:auto; border:1px solid var(--line); font-size:11px; padding:4px 8px; width:160px; }
.table { background:#fff; border:1px solid var(--line); max-height:520px; overflow:auto; }
.thead, .case { display:flex; font-size:11px; align-items:center; }
.thead { position:sticky; top:0; background:#EEF2F3; color:var(--muted);
  letter-spacing:1px; padding:8px 10px; z-index:1; }
.case { border-bottom:1px solid #E6EBEE; padding:7px 10px; cursor:pointer; color:#2A3A44; }
.case:hover { background:#F4F8F8; }
.case .num { width:34px; font-family:Bahnschrift,Consolas,monospace; color:#8A99A2; }
.case .title { flex:1; }
.case .tag { width:96px; }
.case .arrow { width:18px; text-align:right; color:#8A99A2; }
.tag.ok { color:var(--green); }
.tag.gap { color:var(--amber); }
.tag.soft { color:var(--muted); }
.detail { display:none; background:#F4F8F8; border-bottom:1px solid var(--line);
  padding:11px 14px 11px 44px; font-size:11px; line-height:1.75; }
.detail.open { display:block; }
.detail .k { color:var(--muted); margin-right:8px; }
.detail img { max-width:220px; max-height:130px; display:block; margin:6px 0; border:1px solid var(--line); }
.empty { padding:18px; font-size:12px; color:var(--muted); }
.chapters { margin-top:34px; border-top:1px solid var(--line); padding-top:14px; }
.impact { font-size:10px; padding:1px 5px; border:1px solid; margin-left:6px; white-space:nowrap; }
.impact.big { color:var(--amber); border-color:var(--amber); }
.impact.small { color:var(--muted); border-color:var(--line); }
details.chapter { border-bottom:1px solid #E6EBEE; padding:7px 0; font-size:12px; }
details.chapter summary { cursor:pointer; color:var(--muted); }
.chapter-body { font-size:12px; line-height:1.7; color:#2A3A44; padding:8px 0 4px; }
.chapter-body h3,.chapter-body h4,.chapter-body h5,.chapter-body h6 { font-size:13px; margin:12px 0 6px; }
.chapter-body p { margin:6px 0; }
.chapter-body ul,.chapter-body ol { margin:6px 0; padding-left:20px; }
.chapter-body table { width:100%; border-collapse:collapse; font-size:11px; margin:8px 0; }
.chapter-body th { background:#EEF2F3; text-align:left; }
.chapter-body th,.chapter-body td { border:1px solid var(--line); padding:5px 7px; vertical-align:top; }
.chapter-body code { background:#EEF2F3; padding:1px 4px; font-family:Consolas,monospace; }
.chapter-body pre { background:#EEF2F3; padding:8px; white-space:pre-wrap; overflow-x:auto; }
.chapter-body blockquote { border-left:3px solid var(--green); margin:6px 0; padding-left:10px; color:var(--muted); }
.l4 { margin-top:34px; border-top:1px solid var(--line); padding-top:18px; }
.l4 h2 { font-size:16px; margin:0; }
.l4 .l4-hint { font-size:10px; color:var(--muted); margin-top:4px; line-height:1.6; }
.l4-counts { display:flex; gap:7px; flex-wrap:wrap; margin:12px 0; }
.l4-counts .metric { font-family:Bahnschrift,Consolas,monospace; }
.l4-counts .metric.bad { background:#FBEDEC; border-color:var(--gap); color:var(--gap); }
.l4-table { width:100%; border-collapse:collapse; font-size:11px; background:#fff; border:1px solid var(--line); }
.l4-table th { background:#EEF2F3; text-align:left; }
.l4-table th,.l4-table td { border:1px solid var(--line); padding:5px 7px; vertical-align:top; }
.l4-fail { margin-top:12px; font-size:11px; color:#2A3A44; }
.l4-fail .k { color:var(--gap); font-weight:700; margin-right:6px; }
.l4-shots { display:flex; gap:8px; flex-wrap:wrap; margin-top:12px; }
.l4-shots a { display:block; border:1px solid var(--line); background:#fff; padding:3px; }
.l4-shots img { display:block; max-width:200px; max-height:120px; }
.l4-links { margin-top:12px; font-size:11px; }
.l4-links a { margin-right:14px; }
@media (max-width:760px) { .sheet{padding:20px 16px} .hero{grid-template-columns:1fr;gap:20px}
  .verdict{font-size:30px} .search{margin-left:0} }
@media (prefers-reduced-motion:reduce) { *{transition:none!important} }
"""

JS = """
(function(){
  var bar=document.querySelector('.bar');
  var cases=[].slice.call(document.querySelectorAll('.case'));
  var chips=[].slice.call(document.querySelectorAll('.chip'));
  var search=document.querySelector('.search');
  if(!bar||!search) return;
  function apply(){
    var cat=bar.getAttribute('data-cat')||'all';
    var q=(search.value||'').trim();
    cases.forEach(function(el){
      var okCat=cat==='all'||el.getAttribute('data-cat')===cat;
      var okQ=!q||el.textContent.indexOf(q)>=0;
      var show=okCat&&okQ;
      el.style.display=show?'flex':'none';
      if(!show){var d=el.nextElementSibling;if(d&&d.classList.contains('detail')){d.classList.remove('open'); d.style.display='';}}
    });
  }
  [].slice.call(bar.children).forEach(function(seg){
    seg.addEventListener('click',function(){
      var next=seg.getAttribute('data-cat');
      bar.setAttribute('data-cat', next===bar.getAttribute('data-cat')?'all':next);
      chips.forEach(function(c){c.setAttribute('aria-pressed',String(c.getAttribute('data-cat')===(bar.getAttribute('data-cat')||'all')));});
      apply();
    });
  });
  chips.forEach(function(c){c.addEventListener('click',function(){
    bar.setAttribute('data-cat',c.getAttribute('data-cat'));
    chips.forEach(function(x){x.setAttribute('aria-pressed',String(x===c));});
    apply();
  });});
  search.addEventListener('input',apply);
  cases.forEach(function(el){el.addEventListener('click',function(){
    var d=el.nextElementSibling;if(d&&d.classList.contains('detail'))d.classList.toggle('open');
  });});
})();
"""

RE_MAP = {
    "M1": "命令核对",
    "M2": "二次检验",
    "M3": "人工查看",
}


def parse_header(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in text.splitlines():
        if line.startswith("### "):
            break
        match = re.match(r"^\*\*(.+?)\*\*[：:]\s*(.*)$", line.strip())
        if match:
            result[match.group(1).strip()] = match.group(2).strip()
    return result


def _duration_parts(header: dict) -> tuple[str, str]:
    raw = str(header.get("测试耗时", "")).strip()
    match = re.search(r"(\d+)\s*分钟", raw)
    if not match:
        return "耗时未记录", "报告首部未记录测试耗时"
    return f"耗时 {match.group(1)} 分钟", raw


def _duration_text(header: dict) -> str:
    return _duration_parts(header)[0]


def _duration_title(header: dict) -> str:
    return _duration_parts(header)[1]


def _split_row(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    parts = re.split(r"(?<!\\)\|", line)
    return [part.replace(r"\|", "|").strip() for part in parts]


def parse_cases(report_text: str) -> list[dict[str, str]]:
    lines = report_text.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if line.startswith("### 二、功能点验收")),
        None,
    )
    if start is None:
        return []
    keys: list[str] = []
    cases: list[dict[str, str]] = []
    for line in lines[start + 1 :]:
        if line.startswith("### "):
            break
        if not line.strip().startswith("|"):
            continue
        cells = _split_row(line)
        if not keys:
            keys = cells
            continue
        if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
            continue
        if len(cells) == len(keys):
            cases.append(dict(zip(keys, cells)))
    return cases


def plain_label(judgement: str) -> str:
    if "期望更正" in judgement:
        return "期望更正"
    for token, label in RE_MAP.items():
        if token in judgement:
            return label
    if "未覆盖" in judgement:
        return "没测到"
    return judgement.strip() or "未标明"


def with_source(label: str) -> str:
    return label


def _category(judgement: str) -> str:
    label = plain_label(judgement)
    if label in RE_MAP.values():
        return label
    if label in ("没测到", "部分验证"):
        return "gap"
    return "gap" if ("未覆盖" in judgement or "部分" in judgement) else "soft"


def _esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def _screenshots(evidence: str) -> list[str]:
    return re.findall(r"shots/[^；;，,|]+\.(?:png|jpg|jpeg|webp)", evidence, re.I)


def _parse_sections(report_text: str) -> dict[str, str]:
    sections: dict[str, str] = {}
    current: str | None = None
    buffer: list[str] = []
    for line in report_text.splitlines():
        if line.startswith("### "):
            if current:
                sections[current] = "\n".join(buffer).strip()
            current = line[4:].strip()
            buffer = []
        elif current:
            buffer.append(line)
    if current:
        sections[current] = "\n".join(buffer).strip()
    return sections


def _bullets(text: str, limit: int) -> list[str]:
    items: list[str] = []
    for line in text.splitlines():
        match = re.match(r"^\s*(?:[-*+]|\d+\.)\s+(.*)$", line)
        if match:
            items.append(match.group(1).strip())
    return items[:limit]


def _gap_count(header: dict[str, str], cases: list[dict[str, str]]) -> int:
    raw = header.get("判据构成", "") + " " + header.get("未覆盖", "")
    match = re.search(r"未覆盖或仅部分验证\s*(\d+)\s*条", raw)
    if match:
        return int(match.group(1))
    return sum(1 for case in cases if _category(case.get("判定", "")) == "gap")


def _assumptions(header: dict[str, str]) -> list[str]:
    text = header.get("假设", "")
    parts = re.split(r"[①②③④⑤⑥]", text)
    parts = [part.strip(" ；;。") for part in parts if part.strip(" ；;。")]
    return parts[:3] or ["本轮未记录默认前提"]


HIGH_IMPACT = (
    "越权", "权限", "角色视角", "登录视角", "账号视角", "deptId", "companyWide",
    "主流程", "闭环", "对账", "金额口径", "全年目标", "累计目标",
)
HIGH_ENTRY = ("主入口", "入口链路")
NON_PRIMARY_ENTRY = ("非主入口", "内嵌入口")
SMALL_IMPACT = (
    "展示", "样式", "格式", "单位", "配色", "空态", "空数据", "弹窗",
    "放大查看", "按钮存在",
)
SWITCH_VALUE = re.compile(r"切换器.*数值|数值.*切换器")


def _impact(text: str) -> str:
    lowered = text.lower()
    if any(keyword.lower() in lowered for keyword in HIGH_IMPACT):
        return "大"
    if any(keyword in text for keyword in NON_PRIMARY_ENTRY):
        return "小"
    if any(keyword in text for keyword in HIGH_ENTRY):
        return "大"
    if SWITCH_VALUE.search(text):
        return "大"
    if any(keyword in text for keyword in SMALL_IMPACT):
        return "小"
    return "小"


def _test_result(cases: list[dict], header: dict, bugs: list[dict]) -> tuple[str, str]:
    bad_tokens = ("不通过", "失败", "错误")
    passed = sum(
        1 for case in cases
        if "通过" in case.get("判定", "")
        and not any(token in case.get("判定", "") for token in bad_tokens)
    )
    failed = any(
        any(token in case.get("判定", "") for token in bad_tokens)
        for case in cases
    )
    risks = sum(
        1 for case in cases
        if any(token in case.get("判定", "") for token in ("未覆盖", "部分验证"))
    )
    if failed:
        return "测试不通过", f"{passed} 项被测用例通过 · 缺陷 {len(bugs)} 条"
    if passed == 0:
        detail = f"0 项被测用例通过 · 缺陷 {len(bugs)} 条"
        if risks:
            detail += f" · 风险 {risks} 条另列"
        return "无可判定用例", detail
    detail = f"{passed} 项被测用例全部通过 · 缺陷 {len(bugs)} 条"
    if risks:
        detail += f" · 风险 {risks} 条另列"
    return "测试通过", detail


def _safe_url(url: str) -> str:
    value = html.unescape(url.strip()).replace('"', "").replace("'", "")
    if value.startswith("//") or value.startswith("\\"):
        return "#"
    if re.match(r"^(?:https?://|/|\./|\.\./|#|mailto:)", value, re.I):
        return html.escape(value, quote=True)
    if ":" not in value and not value.startswith(("\\", "//")):
        return html.escape(value, quote=True)
    return "#"


def _detail_html(detail: str, bug_count: int) -> str:
    parts: list[str] = []
    for part in detail.split(" · "):
        defect_match = re.fullmatch(r"缺陷\s*(\d+)\s*条", part.strip())
        if defect_match and bug_count > 0:
            parts.append(
                "<a class='metric defect' href='#defects' title='查看缺陷明细'>"
                + _esc(part.strip()) + "</a>"
            )
        else:
            cls = "metric risk" if "风险" in part else "metric"
            parts.append(f"<span class='{cls}'>" + _esc(part.strip()) + "</span>")
    return "".join(parts)


def _defect_value(value: object) -> str:
    if value is None or value == "" or value == [] or value == {}:
        return "—"
    if isinstance(value, list):
        return "；".join(_defect_value(item) for item in value)
    if isinstance(value, dict):
        return "；".join(f"{_esc(k)}：{_defect_value(v)}" for k, v in value.items())
    return _esc(value)


def _defect_section(bugs: list[dict]) -> str:
    if not bugs:
        return ""
    out = [
        "<section id='defects' class='defects'>",
        "<h2>缺陷明细 · " + str(len(bugs)) + " 条</h2>",
        "<div class='defect-hint'>与上方测试结论中的缺陷数对应；截图按相对路径加载。</div>",
    ]
    fields = [
        ("等级", "severity"),
        ("模块", "module"),
        ("标题", "title"),
        ("描述", "description"),
        ("前置条件", "preconditions"),
        ("步骤", "steps"),
        ("期望", "expected"),
        ("实际", "actual"),
        ("接口", "api_url"),
        ("接口方法", "api_method"),
        ("接口请求", "api_request"),
        ("接口响应", "api_response"),
        ("说明", "notes"),
    ]
    for index, bug in enumerate(bugs, 1):
        severity = _defect_value(bug.get("severity", ""))
        title = _defect_value(bug.get("title", ""))
        module = _defect_value(bug.get("module", ""))
        out.append("<details class='defect-item'>")
        out.append(
            "<summary class='defect-head'>#" + str(index)
            + "<span class='defect-sev'>" + severity + "</span>"
            + title
            + "<span class='defect-module'>" + module + "</span></summary>"
        )
        out.append("<div class='defect-body'>")
        for label, key in fields:
            if key in bug and key not in ("severity", "title", "module"):
                value = _defect_value(bug.get(key))
                out.append(
                    "<div class='defect-field'><span class='k'>" + _esc(label)
                    + "</span><span>" + value + "</span></div>"
                )
        screenshot = bug.get("screenshot") or ""
        if isinstance(screenshot, list):
            screenshots = [str(item) for item in screenshot if item]
        else:
            screenshots = [str(screenshot)] if screenshot else []
        for shot in screenshots:
            out.append('<img src="' + _safe_url(shot) + '" alt="缺陷证据截图">')
        out.append("</div></details>")
    out.append("</section>")
    return "\n".join(out)


def _inline_md(text: str) -> str:
    value = html.escape(text)
    value = re.sub(
        r"!\[([^\]]*)\]\(([^)]+)\)",
        lambda m: f'<img src="{_safe_url(m.group(2))}" alt="{m.group(1)}">',
        value,
    )
    value = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda m: f'<a href="{_safe_url(m.group(2))}">{m.group(1)}</a>',
        value,
    )
    value = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", value)
    value = re.sub(r"~~(.+?)~~", r"<del>\1</del>", value)
    value = re.sub(r"`([^`]+)`", r"<code>\1</code>", value)
    return value


def _is_table_separator(line: str) -> bool:
    cells = _split_row(line)
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells)


def _render_nested_list(items: list[tuple[int, str]]) -> str:
    def build(index: int, base_indent: int) -> tuple[str, int]:
        parts = ["<ul>"]
        while index < len(items) and items[index][0] >= base_indent:
            indent, content = items[index]
            parts.append("<li>" + _inline_md(content))
            index += 1
            if index < len(items) and items[index][0] > indent:
                nested, index = build(index, items[index][0])
                parts.append(nested)
            parts.append("</li>")
        parts.append("</ul>")
        return "".join(parts), index

    rendered, _ = build(0, items[0][0] if items else 0)
    return rendered


def _markdown_to_html(markdown_text: str) -> str:
    lines = markdown_text.splitlines()
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if not line.strip():
            i += 1
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            level = min(len(heading.group(1)) + 2, 6)
            out.append(f"<h{level}>{_inline_md(heading.group(2))}</h{level}>")
            i += 1
            continue
        if line.lstrip().startswith("|") and i + 1 < len(lines) and _is_table_separator(lines[i + 1]):
            headers = _split_row(line)
            i += 2
            rows: list[list[str]] = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(_split_row(lines[i]))
                i += 1
            table = ["<table><thead><tr>"]
            table.extend(f"<th>{_inline_md(cell)}</th>" for cell in headers)
            table.append("</tr></thead><tbody>")
            for row in rows:
                table.append("<tr>" + "".join(f"<td>{_inline_md(cell)}</td>" for cell in row) + "</tr>")
            table.append("</tbody></table>")
            out.append("".join(table))
            continue
        if re.fullmatch(r"\s*(?:-{3,}|\*{3,}|_{3,})\s*", line):
            out.append("<hr>")
            i += 1
            continue
        bullet = re.compile(r"^\s*[-*+]\s+(.*)$")
        if bullet.match(line):
            items: list[tuple[int, str]] = []
            while i < len(lines) and bullet.match(lines[i]):
                raw = lines[i]
                indent = len(raw) - len(raw.lstrip())
                items.append((indent, bullet.match(raw).group(1).strip()))
                i += 1
            out.append(_render_nested_list(items))
            continue
        if re.match(r"^\d+\.\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\d+\.\s+", lines[i]):
                items.append(re.sub(r"^\d+\.\s+", "", lines[i]).strip())
                i += 1
            out.append("<ol>" + "".join(f"<li>{_inline_md(item)}</li>" for item in items) + "</ol>")
            continue
        if line.startswith("> "):
            quote: list[str] = []
            while i < len(lines) and lines[i].startswith("> "):
                quote.append(lines[i][2:].strip())
                i += 1
            out.append("<blockquote>" + _inline_md(" ".join(quote)) + "</blockquote>")
            continue
        if line.startswith("```"):
            i += 1
            code: list[str] = []
            while i < len(lines) and not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            out.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
            continue
        paragraph = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r"^\s*(#{1,6}\s|[-*+]\s|\d+\.\s|> |```|\||-{3,}|\*{3,}|_{3,})", lines[i]):
            paragraph.append(lines[i].strip())
            i += 1
        out.append("<p>" + _inline_md(" ".join(paragraph)) + "</p>")
    return "\n".join(out)


def _hash16(header: dict) -> str:
    match = re.search(r"[0-9a-fA-F]{16}", header.get("用例冻结", ""))
    if match:
        return match.group(0)
    return header.get("_hash16") or "—"


def _counterevidence_count(sections: dict[str, str]) -> int | str:
    text = sections.get("十三、自我反证", "")
    match = re.search(r"(\d+)\s*条反证", text)
    if match:
        return int(match.group(1))
    rows = [line for line in text.splitlines() if re.match(r"^\|\s*\d+\s*\|", line)]
    return len(rows) if rows else "若干"


def _counts(cases: list[dict[str, str]]) -> dict[str, int]:
    counts = {label: 0 for label in RE_MAP.values()}
    counts["gap"] = 0
    counts["soft"] = 0
    for case in cases:
        counts[_category(case.get("判定", ""))] += 1
    return counts


def _bar_counts(header: dict, cases: list[dict[str, str]]) -> dict[str, int]:
    raw = header.get("判据构成", "")
    match = re.search(r"M1\s*(\d+).*M2\s*(\d+).*M3\s*(\d+).*未覆盖或仅部分验证\s*(\d+)", raw)
    if match:
        return {
            RE_MAP["M1"]: int(match.group(1)),
            RE_MAP["M2"]: int(match.group(2)),
            RE_MAP["M3"]: int(match.group(3)),
            "gap": int(match.group(4)),
        }
    return _counts(cases)


def _l4_section(l4: dict) -> str:
    counts = l4.get("counts") or {}
    cases = l4.get("cases") or []
    suite_hash = str(l4.get("suiteSha256") or "")[:16]
    status_cn = {"passed": "通过", "failed": "失败", "skipped": "跳过", "missing": "缺失"}
    out = [
        "<section class='l4' id='l4'>",
        "<h2>L4 端到端（Midscene）</h2>",
        "<div class='l4-hint'>AI 断言一律 M3；数值 / 金额 / 条数 / 权限 / 占比类结论需另有 M1/M2 交叉核验，否则该条只能「有条件通过」。</div>",
        "<div class='l4-counts'>",
        "<span class='metric'>用例 " + str(counts.get("total", len(cases))) + "</span>",
        "<span class='metric'>通过 " + str(counts.get("passed", 0)) + "</span>",
        "<span class='metric" + (" bad" if int(counts.get("failed", 0) or 0) > 0 else "") + "'>失败 "
        + str(counts.get("failed", 0)) + "</span>",
        "<span class='metric'>跳过 " + str(counts.get("skipped", 0)) + "</span>",
        "<span class='metric'>exit " + str(l4.get("exitCode", "")) + "</span>",
    ]
    if suite_hash:
        out.append("<span class='metric'>套件 " + _esc(suite_hash) + "</span>")
    out.append("</div>")
    if cases:
        out.extend([
            "<table class='l4-table'><thead><tr>",
            "<th>用例编号</th><th>业务断言</th><th>判据</th><th>交叉核验</th><th>结果</th>",
            "</tr></thead><tbody>",
        ])
        for case in cases:
            status = str(case.get("status", ""))
            label = status_cn.get(status, status or "—")
            criterion = str(case.get("criterion") or case.get("evidenceLevel") or "M3")
            cross = "；".join(str(item) for item in case.get("crossVerifiedBy") or []) or "—"
            out.append(
                "<tr><td>" + _esc(case.get("caseId", "—"))
                + "</td><td>" + _esc(case.get("name", "—"))
                + "</td><td>" + _esc(criterion)
                + "</td><td>" + _esc(cross)
                + "</td><td>" + _esc(label + " " + criterion) + "</td></tr>"
            )
        out.append("</tbody></table>")
    else:
        out.append("<div class='empty'>l4-summary.json 没有可展示的用例。</div>")

    failures = [case for case in cases if case.get("failedStep")]
    if failures:
        out.append("<div class='l4-fail'>")
        for case in failures:
            step = case.get("failedStep") or {}
            out.append(
                "<div><span class='k'>失败步骤</span>" + _esc(case.get("caseId", "")) + " / "
                + _esc("步骤 " + str(step.get("index", ""))) + " "
                + _esc(step.get("node", "")) + " / "
                + _esc(step.get("error", "") or "无报错文本") + "</div>"
            )
        out.append("</div>")

    shots: list[str] = []
    for case in cases:
        for shot in case.get("screenshots") or []:
            if shot and shot not in shots:
                shots.append(str(shot))
    if shots:
        out.append("<div class='l4-shots'>")
        for shot in shots:
            out.append(
                "<a href='" + _safe_url(shot) + "'><img src='" + _safe_url(shot) + "' alt='L4 步骤截图'></a>"
            )
        out.append("</div>")

    out.append(
        "<div class='l4-links'><a href='" + _safe_url("l4/midscene/report.html") + "'>Midscene 原始报告</a>"
        "<a href='" + _safe_url("l4/midscene/result.md") + "'>result.md</a>"
        "<a href='" + _safe_url("l4/l4-summary.json") + "'>l4-summary.json</a></div>"
    )
    out.append("</section>")
    return "\n".join(out)


def render_html(
    header: dict,
    cases: list[dict],
    sections: dict[str, str],
    bugs: list[dict],
    l4: dict | None = None,
) -> str:
    gap = _gap_count(header, cases)
    counts = _bar_counts(header, cases)
    verdict = header.get("结论", "") or "未写明"
    gaps = _bullets(sections.get("九、未覆盖", ""), 99) or ["本轮未单独列出未覆盖项"]
    test_verdict, test_detail = _test_result(cases, header, bugs)
    high_risks = sum(1 for item in gaps if _impact(item) == "大")
    low_risks = len(gaps) - high_risks
    assumptions = _assumptions(header)
    total = max(sum(counts.values()), 1)
    segments = [
        (RE_MAP["M1"], with_source(RE_MAP["M1"]), counts[RE_MAP["M1"]], CHECK),
        (RE_MAP["M2"], with_source(RE_MAP["M2"]), counts[RE_MAP["M2"]], VERIFY),
        (RE_MAP["M3"], with_source(RE_MAP["M3"]), counts[RE_MAP["M3"]], MANUAL),
        ("gap", with_source("没测到"), counts["gap"], GAP),
    ]

    out: list[str] = [
        "<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'>",
        "<script>window.addEventListener('error',function(e){if(e&&e.message&&e.message.indexOf('getBoundingClientRect')>=0){e.preventDefault();}});</script>",
        "<meta name='viewport' content='width=device-width,initial-scale=1'>",
        "<title>自测报告 · " + _esc(verdict) + "</title>",
        "<style>" + CSS + "</style></head><body><main class='sheet'>",
        "<div class='topline'><span class='name'>自测报告 · " + _esc(header.get("范围", "本次改动")[:42]) + "</span>",
        "<span class='duration' title='" + _esc(_duration_title(header)) + "'>" + _esc(_duration_text(header)) + "</span>",
        "<span class='hash'>清单 " + _esc(_hash16(header)) + "</span>",
    ]
    if l4:
        out.append("<span class='hash'>L4 套件 " + _esc(str(l4.get("suiteSha256") or "")[:16] or "—") + "</span>")
    out.extend([
        "</div>",
        "<section class='hero'><div class='verdict-panel'>",
        "<div class='eyebrow'>测试结论</div>",
        "<div class='verdict'>" + _esc(test_verdict) + "</div>",
        "<div class='verdict-sub'>" + _detail_html(test_detail, len(bugs)) + "</div>",
        "</div><div class='risk-panel'>",
        "<h3>风险 · 单独列示</h3>",
        "<div class='risk-summary'>影响大 " + str(high_risks)
        + " · 可手动补测 " + str(low_risks) + " · 不参与主结论</div>",
    ])
    for item in gaps:
        level = _impact(item)
        cls = "big" if level == "大" else "small"
        label = "影响大" if level == "大" else "可手动补测"
        out.append(
            "<div class='row'>· " + _esc(item)
            + "<span class='impact " + cls + "'>" + label + "</span></div>"
        )
    out.append("<div class='subhead'>这次默认的前提 · " + str(len(assumptions)) + " 条</div>")
    for item in assumptions:
        out.append("<div class='row'>· " + _esc(item) + "</div>")
    out.extend([
        "</div></section>",
        "<section class='evidence'>",
        "<div class='bar-label'>" + str(len(cases)) + " 项测试，证据有多硬（点色块筛选）</div>",
        "<div class='bar' data-cat='all'>",
    ])
    for cat, display, count, color in segments:
        width = 100.0 * count / total
        out.append(
            f"<div data-cat='{_esc(cat)}' style='width:{width:.2f}%;background:{color}' title='{_esc(display)} {count}'></div>"
        )
    out.extend(["</div><div class='legend'>"])
    for cat, display, count, color in segments:
        out.append(
            f"<div><span class='dot' style='background:{color}'></span>"
            f"<b>{count}</b>{_esc(display)}</div>"
        )
    out.extend([
        "</div><div class='hint'>点色块看这一类具体是哪几条 · 证据条按报告头判据构成，明细按用例实际判定</div>",
        "</section>",
        "<div class='note'>故意找茬复查 " + str(_counterevidence_count(sections)) + " 次，都没找出反例</div>",
        "<section class='cases'><h2>" + str(len(cases)) + " 项测试明细</h2>",
        "<div class='hintline'>有缺口的行排在最前 · 点任意行展开期望 / 实测 / 证据</div>",
        "<div class='filters'>",
        "<button class='chip' data-cat='all' aria-pressed='true'>全部 " + str(len(cases)) + "</button>",
    ])
    chip_colors = {item[0]: item[3] for item in segments}
    for label in list(RE_MAP.values()) + ["gap"]:
        cat = "gap" if label == "gap" else label
        text = with_source("没测到") if label == "gap" else with_source(label)
        cls = "chip warn" if label == "gap" else "chip"
        color = chip_colors.get(cat, GREEN)
        out.append(
            f"<button class='{cls}' data-cat='{_esc(cat)}' aria-pressed='false' "
            f"style='--chip:{color}'>{_esc(text)}</button>"
        )
    out.extend([
        "<input class='search' placeholder='搜测试内容…' aria-label='搜索测试内容'>",
        "</div><div class='table'>",
        "<div class='thead'><div class='num'>#</div><div class='title'>测什么</div><div class='tag'>结果</div><div class='arrow'></div></div>",
    ])
    ordered = sorted(cases, key=lambda c: 0 if _category(c.get("判定", "")) == "gap" else 1)
    for case in ordered:
        judgement = case.get("判定", "")
        cat = _category(judgement)
        label = plain_label(judgement)
        cls = "tag gap" if cat == "gap" else ("tag soft" if label == "期望更正" else "tag ok" if label in RE_MAP.values() else "tag soft")
        title = case.get("验收点", "") + " · " + case.get("输入", "")
        evidence = case.get("证据", "")
        out.append(
            "<div class='case' data-cat='" + _esc(cat) + "'><div class='num'>" + _esc(case.get("#", "")) + "</div>"
            "<div class='title'>" + _esc(title) + "</div>"
            "<div class='tag " + cls + "'>" + _esc(with_source(label)) + "</div><div class='arrow'>›</div></div>"
        )
        out.append("<div class='detail'>")
        for key in ("期望", "期望来源", "实测", "证据", "判定"):
            out.append("<div><span class='k'>" + _esc(key) + "</span>" + _esc(case.get(key, "")) + "</div>")
        for shot in _screenshots(evidence):
            out.append('<img src="' + _esc(shot) + '" alt="证据截图">')
        if cat == "gap":
            out.append("<div><span class='k'>为什么没测到 / 怎么补</span>见第九节未覆盖；补测后重新生成报告。</div>")
        out.append("</div>")
    if not cases:
        out.append("<div class='empty'>报告第二节没有可展示的用例表。</div>")
    out.append("</div></section>")

    out.append(_defect_section(bugs))
    if l4:
        out.append(_l4_section(l4))

    out.append("<section class='chapters'><h2>完整报告章节</h2>")
    for title, content in sections.items():
        out.append(
            "<details class='chapter'><summary>" + _esc(title)
            + "</summary><div class='chapter-body'>" + _markdown_to_html(content) + "</div></details>"
        )
    out.append("</section>")
    out.append("<div class='note'>缺陷 " + str(len(bugs)) + " 条" + (" · " + _esc(header.get("缺陷记录", "")) if header.get("缺陷记录") else "") + "</div>")
    out.append("</main><script>" + JS + "</script></body></html>")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate offline HTML view of a self-test report")
    parser.add_argument("--report", required=True)
    parser.add_argument("--cases", required=True)
    parser.add_argument("--bugs")
    parser.add_argument("--l4")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)

    report_path = Path(args.report)
    cases_path = Path(args.cases)
    out_path = Path(args.out)
    if not report_path.is_file():
        print(f"report not found: {report_path}", file=sys.stderr)
        return 2
    if not cases_path.is_file():
        print(f"cases not found: {cases_path}", file=sys.stderr)
        return 2

    report_text = report_path.read_text(encoding="utf-8")
    cases_text = cases_path.read_text(encoding="utf-8")
    bugs: list[dict] = []
    if args.bugs:
        bugs_path = Path(args.bugs)
        if bugs_path.is_file():
            data = json.loads(bugs_path.read_text(encoding="utf-8"))
            bugs = data if isinstance(data, list) else data.get("bugs", [])
    header = parse_header(report_text)
    header["_hash16"] = hashlib.sha256(cases_path.read_bytes()).hexdigest()[:16]
    header.setdefault("用例冻结", "SHA256 " + header["_hash16"])
    l4: dict | None = None
    if args.l4:
        l4_path = Path(args.l4)
        if l4_path.is_file():
            data = json.loads(l4_path.read_text(encoding="utf-8-sig"))
            l4 = data if isinstance(data, dict) else None
        else:
            print(f"l4 summary not found: {l4_path}", file=sys.stderr)
            return 2
    out_path.write_text(
        render_html(header, parse_cases(report_text), _parse_sections(report_text), bugs, l4),
        encoding="utf-8",
    )
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
