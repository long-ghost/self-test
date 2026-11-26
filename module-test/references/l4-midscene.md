# L4：Midscene Test 端到端档位

> L4 = 真实浏览器 + 自然语言步骤 + AI 断言，用例以 YAML 沉淀到业务仓库。
> 官方文档：<https://midscenejs.com/zh/midscene-test/overview>（Beta，协议与字段可能演进）。

## 1. 什么时候用 L4

- 需要证明「用户可见的端到端行为」：跨页跳转、异步渲染、弹窗与表单联动、AI 生成或动态布局页面。
- L3 的 DOM 选择器维护成本太高，或页面语义化程度高、选择器不稳定。
- 希望把回归用例沉淀为长期资产，而不是每轮重写临时脚本。

不适用：

- 只验接口返回码 / 字段 / 越权 → L2 更便宜、更稳定。
- 需要把密码输入到页面完成登录 → v1 不支持（`aiAct` 输入会进入运行结果）。
- 数值、金额、条数、权限类结论不能只有 AI 断言。

## 2. 首次初始化

前置：Node `^20.19 || ^22.12 || >=24`、pnpm、Chromium、模型 Key。

```powershell
# 只检查，不改任何文件；0 就绪 / 2 缺前置 / 1 执行错误
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/l4-init.ps1" -CheckOnly

# 安装依赖 + Chromium + 生成 node-spec.md
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/l4-init.ps1" -Install

# 有 Key 后验证模型连通性
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/l4-init.ps1" -ModelVerify
```

- `.env` 只放在 runner 目录，写 `MIDSCENE_MODEL_API_KEY` / `MIDSCENE_MODEL_NAME` / `MIDSCENE_MODEL_BASE_URL` / `L4_COOKIES` 等。
- 写用例前先读 `node-spec.md`（由 `midscene-test nodes` 生成），它才是当前版本可用 Node 与参数的唯一依据。

## 3. YAML 编写规则

- **一个文件只放一条用例**；`cases/<模块>/<caseId>.yaml`，文件名 = `caseId` = suite 条目，`name` 必须与 suite 完全一致。
- 步骤线性执行，**步骤之间没有隐式状态**。每条自然语言指令写全目标，禁止「上一步」「刚才那个」。
  - 反例：`aiAct: 点击收藏星标` / `aiAssert: 上一步的图标已经点亮`
  - 正例：`aiAssert: 商品详情页的收藏星标处于点亮状态`
- 关键节点必须 `aiAssert`；操作成功不等于测试通过。异步加载用 `aiWaitFor`。
- 只使用官方 Web Node：`aiAct` / `aiAssert` / `aiWaitFor` / `wait` / `gotoUrl` / `setCookies` / `clearCookies` / `setViewportSize`。v1 不加载业务仓库自定义 Node。
- 超时与容错用步骤里的 `$` 字段（框架字段，不传给 Node）：

```yaml
steps:
  - aiAct:
      prompt: 点击申请退款并提交
      $:
        timeout: 30000
        continue-on-error: false
```

- `continue-on-error: true` 只让当前阶段继续，用例最终仍判 failed，不能拿它当通过。
- tags 用于选择：`-Tag smoke`。

## 4. 套件与沉淀流程

唯一清单：`E2E_ROOT/e2e/midscene/suite.json`（默认 `<repo>/E2E测试/`，schema 见 `assets/midscene-suite.schema.json`）。

```powershell
# 扫描 cases/ 生成或更新清单；无 -Authorize 只打印差异
python "$HOME/.codebuddy/skills/module-test/scripts/l4_suite.py" collect --repo-root . --module <模块名>

# 用户授权后写回
python "$HOME/.codebuddy/skills/module-test/scripts/l4_suite.py" collect --repo-root . --module <模块名> --authorize

# 输出十五节可粘贴的 Markdown 表
python "$HOME/.codebuddy/skills/module-test/scripts/l4_suite.py" export --suite "E2E测试/e2e/midscene/suite.json"
```

- `criterion` 默认 `M3`；数值 / 金额 / 条数 / 权限 / 占比类断言必须在 `crossVerifiedBy` 写明 M1/M2 来源（SQL、接口）。没有交叉核验 ⇒ 该条结论上限「有条件通过」。
- `lastStatus` / `lastVerified` 由 `l4-run.ps1 -UpdateSuite` 回写，不手改。

## 5. 执行与产物

```powershell
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/l4-run.ps1" `
  -Round "<E2E_ROOT>/<YYYYMMDD-HHmmss>-<功能名>" -Authorize `
  [-Case L4-ORD-001 | -Tag smoke] [-Secrets "MIDSCENE_MODEL_API_KEY=..."] [-DryRun] [-UpdateSuite]
```

- `-DryRun`：只打印选择、暂存树与命令，不写文件、不调用模型。
- `-Case` / `-Tag` 二选一（都不传则跑 suite 全部）；`-Secrets` 可传 `KEY=VALUE`、`.env` 路径或 JSON 文件。
- 运行前会校验模型 Key 是否存在，以及用例里的 `cookiesEnv` 变量和 `storageStatePath` 文件是否存在，缺失直接退出 2，不会跑到一半才报错。
- 每轮在 `~/.codebuddy/skill-data/module-test/l4-runner/runs/<runId>/` 独立执行：暂存 `cases/` + `fixtures/`，生成配置与 `staged-manifest.json`，结果落 `results/`，HTML 报告落 `artifacts/`。
- 本轮产物（一次测试全部集中在此，`<Round>` = `E2E_ROOT/<时间戳>-<功能名>`，产物根默认 `<项目根>/E2E测试/`、可在 `project-profile.md` 配 `E2E_ROOT=` 到仓库外）：

```text
<Round>/
├── cases.md / report.md / report.html   # 冻结件 / 机器底稿 / 管理者视图
├── l4/l4-summary.json                   # 归一化结果（用例、状态、截图、脱敏）
├── l4/midscene/result.md
├── l4/midscene/summary.json
├── l4/midscene/Midscene报告.html        # Midscene 报告（文件名与 <title> 已中文化）
├── e2e/midscene/suite.json + cases/**   # 本轮套件快照（自包含，便于仓库外归档与横向对比）
└── shots/l4/<caseId>-stepN.png
```

- 退出码：0 全通过 / 1 有失败 / 2 缺前置 / 3 未授权 / 4 暂存或套件非法（含 git 越界、结果缺用例）。

## 6. 证据映射

| L4 结论 | 判据 | 要求 |
|---|---|---|
| 可见交互 / 文案 / 布局 | M3 | `aiAssert` + 报告截图 |
| 状态、权限、可见性 | M3 | 另配 L2 接口或 SQL 交叉核验，否则「有条件通过」 |
| 数值 / 金额 / 条数 / 占比 | M3 不可单独成立 | 必须 M1/M2（接口 / SQL 反算），写进 `crossVerifiedBy` |

- AI 断言一律按 M3 计，不许写 M1。
- 页面显示的数字必须回接口或 SQL 取同一值复算，不能只看截图。

## 7. 失败分类与重跑

先定性，再决定是否重跑：

| 现象 | 定性 | 动作 |
|---|---|---|
| 同一断言换时间/重跑稳定失败 | 真缺陷 | 记 P0~P3，进缺陷记录 |
| 报告显示模型定位失败但页面无误 | AI 抖动 | 固定证据，`-RerunFlaky` 重跑 |
| 报告显示元素不存在 / 接口 4xx/5xx | 环境或前置数据问题 | 补前置，不重跑掩盖 |
| YAML 收集报错、变量未定义 | 用例缺陷 | 改用例，不算产品缺陷 |

- 默认 `retry: 0`，**不静默重试**。
- `-RerunFlaky` 会把上一轮 `l4/` 归档为 `l4-rerun-<时间>`，两轮结果都保留；只报第二轮通过 = 隐瞒抖动。
- 模型抖动导致同一用例两轮结论不同，报告里必须写「不稳定」，不能只留通过的一轮。

## 8. 安全红线

- YAML 禁止 `password` / `token` / `cookie` 明文。登录态只能用 `setCookies: { cookiesEnv: L4_COOKIES }`、`profile` 或 `storageStatePath`。
- 需要把密码打进 `aiAct` 的流程 v1 不支持：改用预置 Cookie / storageState，或判「未覆盖」并给四要素。
- 模型 Key、Cookie 只从 `-Secrets` / runner `.env` / 进程环境注入子进程，**只注入、不落盘、不回显**。
- `console.log`、`l4-summary.json`、HTML、报告中的 Secret 值一律替换为 `***`。
- 产物目录不复制 `.env`、Cookie 文件、storageState。
- 写入边界：用户当轮授权后只可写 `e2e/midscene/{cases,fixtures}/**`、`suite.json`、`README.md`；业务源码与配置一律不动。
- `l4-run` 结束用 `git status --porcelain` 校验，越界退出 4，本轮作废。

## 9. 降级到 L3 的条件

遇到以下任一情况，明确降级 L3 并在报告首部声明，不许硬跑 L4 后把失败算成产品问题：

- 模型 Key 不可用、额度耗尽或模型服务不可达。
- 目标环境打不开、需要人工验证码 / 短信 / 扫码登录。
- 必须输入密码或动态验证码才能进入业务页面。
- 页面完全无稳定语义（纯 Canvas 且无文本），AI 断言无法给出可复核依据。

降级后 L4 相关章节可不出现；结论强度按 L3 的规则收窄，并在「未覆盖」写清降级原因与补测计划。

## 10. 全局 runner 目录

```text
~/.codebuddy/skill-data/module-test/l4-runner/
├── package.json / pnpm-lock.yaml / node_modules/
├── .env                  # 本机密钥，绝不入仓、绝不复制到产物
├── .env.example
├── templates/midscene.config.ts
├── node-spec.md          # midscene-test nodes 生成，写用例前读
└── runs/<runId>/         # 每轮独立，含暂存、配置、结果、报告、console.log
```

- 不往业务仓库安装 `node_modules`，runner 由 `l4-init.ps1` 维护。
- `runs/` 可整目录删除，不影响业务仓库；需要复盘时保留对应 runId。
