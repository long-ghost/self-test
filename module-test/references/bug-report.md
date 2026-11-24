# 缺陷记录与禅道对接

> 适用：模块测试（功能 + 接口）发现 P0~P3 缺陷后，自动生成可导入禅道的 Excel，并预留 API / MCP 写入能力。
> 原则：**报告里的缺陷摘要不能替代缺陷单**；每一条 P0~P3 都必须有独立记录。

## 一、产物与位置

每轮测试目录：`.codebuddy/selftest/<YYYYMMDD>-<功能名>/`

| 文件 | 作用 | 是否必须 |
|---|---|---|
| `bugs.json` | 缺陷源数据，脚本输入；便于重跑与追溯 | 有缺陷时必须 |
| `bugs.xlsx` | 人读 + 禅道导入用的 Excel | 有缺陷时必须 |
| `zentao_bugs.json` | 禅道 API / MCP 的 JSON payload | 有缺陷时必须 |
| `shots/` | 截图证据 | 按需 |

没有缺陷时在报告首部写 `缺陷记录：0 条`，不生成上述三个文件。

## 二、bugs.json 格式

```json
{
  "round": "20261121-个人计划实绩",
  "env": "uat",
  "tester": "AI",
  "bugs": [
    {
      "title": "个人计划实绩-新增批注清空后记录仍存在",
      "severity": "P1",
      "type": "功能",
      "module": "个人计划实绩",
      "product": "<project>",
      "zentao_module": "",
      "description": "清空批注并保存，接口返回成功，但刷新后批注仍在。",
      "preconditions": "已登录；存在一条带批注的实绩记录",
      "steps": [
        "进入个人计划实绩页面",
        "打开指定记录的批注框，清空内容",
        "点击保存，等待接口返回",
        "刷新页面重新打开该记录"
      ],
      "expected": "批注被清空，刷新后不再显示",
      "actual": "接口返回 200，刷新后原批注仍显示",
      "api_url": "POST /api/plan/annotation/save",
      "api_method": "POST",
      "api_request": "{\"id\":123,\"content\":\"\"}",
      "api_response": "{\"code\":0,\"msg\":\"success\"}",
      "screenshot": "shots/bug-01-annotation.png",
      "files": [
        "backend/<project>-app/src/main/java/.../AnnotationService.java",
        "frontend/app/src/views/.../Annotation.vue"
      ],
      "owner": "",
      "test_case_id": "C-07",
      "discovered_at": "2026-11-21 10:20:00",
      "notes": ""
    }
  ]
}
```

### 必填字段

| 字段 | 说明 |
|---|---|
| `title` | 缺陷标题：模块 + 现象，能一眼看懂 |
| `severity` | `P0` / `P1` / `P2` / `P3` |
| `type` | `功能` / `接口` / `数据` / `规范` |
| `module` | 所属业务模块 |
| `steps` | 复现步骤，数组；必须能照着复现 |
| `expected` | 期望结果 |
| `actual` | 实际结果 |
| 证据 | `screenshot` 或 `api_url` 至少一项 |

### 选填但建议齐全

`description`、`preconditions`、`api_request`、`api_response`、`files`、`file_lines`、`owner`、`zentao_product`、`zentao_module`、`test_case_id`、`env`、`browser`、`version`、`notes`。

`file_lines` 用于行级责任人：`{"backend/.../PlanService.java": 128}`；有它时优先 `git blame`，没有就按文件查 `git log`。

## 三、责任人解析

顺序固定，不许臆造：

1. `bugs.json` 里显式写了 `owner` → 直接用，`owner_source=用例指定`。
2. 查 `references/code-owners.json` 的 `owners` 映射：
   - key 支持模块名、路径前缀、glob；
   - 命中 → `owner_source=映射表`。
3. 用 `files` 里的文件跑 `git log -1 --format=%an -- <file>`；有行号时优先 `git blame -L <line>,<line> -- <file>` → `owner_source=git blame`。
4. 仍查不到 → `owner=待确认`，`owner_source=未找到`，报告里单列数量。

映射表示例：

```json
{
  "owners": {
    "个人计划实绩": "张三",
    "backend/<project>-app/src/main/java/.../Plan*": "李四"
  }
}
```

> 用户后续提供的作者/模块对应关系直接合并进 `owners`，不要覆盖已有键。

## 四、Excel 结构

`bugs.xlsx` 固定两个 sheet：

### Sheet 1「缺陷明细」

列：缺陷编号、所属产品、所属模块、缺陷标题、严重等级、优先级、缺陷类型、复现步骤、预期结果、实际结果、接口地址、请求方法、请求参数、响应摘要、截图/证据、责任人、责任人来源、测试环境、用例编号、发现时间、禅道状态、备注。

- 严重等级按 P0~P3 着色；表头冻结、自动筛选、自动换行。
- 截图列存相对路径，并加超链接（文件存在时）。
- 不写密码、token、cookie、完整手机号。

### Sheet 2「禅道导入」

按禅道缺陷导入模板的常用列输出：所属产品、所属模块、所属项目、所属执行、缺陷标题、严重程度、优先级、缺陷类型、操作系统、浏览器、重现步骤、结果、期望、关键词、指派给、抄送、截止日期、预计工时、实际工时、邮件通知。

> 不同禅道版本的导入模板列名可能不同；导入前用目标实例的模板核对一次。字段对不上时，以 `zentao_bugs.json` 走 API/MCP 为准。

### Sheet 3「说明」

写明：生成时间、轮次、环境、缺陷数、待确认责任人数、禅道版本差异提示、不得外传的敏感字段。

## 五、禅道字段映射

| 本地字段 | 禅道字段 | 规则 |
|---|---|---|
| `title` | `title` | 原样 |
| `severity` | `severity` | P0→1 致命、P1→2 严重、P2→3 一般、P3→4 轻微 |
| `severity` | `pri` | P0→1、P1→2、P2→3、P3→4 |
| `type` | `type` | 功能/接口→`codeerror`；数据→`others`；规范→`standard` |
| `module` / `zentao_module` | `module` | 优先 `zentao_module`，否则 `module` |
| `steps` | `steps` | 拼成 HTML 段落，附前置条件、期望、实际、接口、截图 |
| `owner` | `assignedTo` | 待确认时留空，不要写“待确认”进禅道 |
| `env` | `os` / 备注 | 环境写进 steps 或备注 |
| `product` | `product` | 产品 ID 或名称，按实例配置 |

## 六、API / MCP 预留

脚本生成 `zentao_bugs.json`，结构：

```json
{
  "endpoint": "{base}/api.php/v1/products/{product}/bugs",
  "headers": {"Token": "<from env>"},
  "bugs": [{"title": "...", "severity": 2, "pri": 2, "type": "codeerror", "steps": "<p>...</p>", "assignedTo": "张三"}]
}
```

环境变量（只在真正写入时读取，不写进 Excel / 报告 / 日志）：

| 变量 | 说明 |
|---|---|
| `ZENTAO_BASE_URL` | 如 `http://zentao.example.com` |
| `ZENTAO_TOKEN` | API token；也可用 `ZENTAO_ACCOUNT` + `ZENTAO_PASSWORD` 换 session |
| `ZENTAO_TOKEN_HEADER` | 默认 `Token` |
| `ZENTAO_BUG_ENDPOINT` | 默认 `{base}/api.php/v1/products/{product}/bugs` |
| `ZENTAO_PRODUCT_ID` | 默认产品 ID |
| `ZENTAO_DEFAULT_OWNER` | 责任人待确认时的兜底指派，可不填 |

命令：

```powershell
# 只生成 Excel + payload（当前阶段）
python <技能目录>\scripts\bug_report.py `
  --input .codebuddy/selftest\<轮次>\bugs.json `
  --out   .codebuddy/selftest\<轮次>\bugs.xlsx `
  --payload-out .codebuddy/selftest\<轮次>\zentao_bugs.json

# 未来有禅道环境：真写入
$env:ZENTAO_BASE_URL = "http://..."
$env:ZENTAO_TOKEN = "..."
python <技能目录>\scripts\bug_report.py --input ... --zentao

# 只打印将发送的 payload，不发请求
python <技能目录>\scripts\bug_report.py --input ... --zentao-dry-run
```

MCP 接入方式：把 `zentao_bugs.json` 作为 MCP 工具的 `bugs` 参数，或让 MCP 直接读取该文件；不要在 skill 里硬编码 MCP 工具名。

## 七、安全与边界

- 仓库只读：Excel/JSON 只写本轮 `.codebuddy/selftest/` 目录。
- 不把密码、token、cookie、Authorization 头写进任何产物。
- 请求参数里的手机号、身份证、客户名称按需脱敏。
- 无禅道环境时，Excel 是唯一交付；不要假装已写入禅道。
- P0/P1 必须同时有复现步骤和证据（截图或接口请求/响应）；缺一不可。
