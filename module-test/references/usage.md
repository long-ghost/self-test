# module-test 使用说明

## 1. 安装

Git 方式安装（支持自动更新检查）：

```powershell
# 在仓库克隆目录内执行；默认装到 ~/.codebuddy/skills/module-test/
powershell -NoProfile -File "<仓库>/module-test/scripts/install.ps1"
```

安装脚本会把仓库缓存到 `~/.codebuddy/skill-cache/module-test`，同步 `module-test/` 到技能目录，安装记录写入 `.install.json`。zip 解压安装的目录可用同一脚本接管。

2. 首次把 `agents/module-test-runner.md` 复制到 `~/.codebuddy/agents/`（`install.ps1` 默认会做，`-SkipAgent` 可跳过），并按本机环境配置模型与 MCP server。
3. 在目标项目根目录运行初始化（`-Root` 指向待测项目）：

```powershell
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/init-workspace.ps1" -Root "<project-root>"
```

4. 按提示填写：
   - `references/project-profile.md`：端口、启动命令、数据库、鉴权、浏览器、项目规则。
   - `references/test-accounts.csv`：真实测试账号；只保存在本机。
   - 按需配置 `agents/module-test-runner.md` 的模型与 MCP server。

5. 需要时手动检查与安装更新（AI 不会主动查）：

```powershell
# 0 已最新 / 2 有更新 / 1 出错，不改任何文件
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/check-update.ps1"
# 用户确认后升级；保留 4 个本地配置
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/update.ps1"
```

## 2. 触发

对 AI 说：

- 「测试一下 X 模块」
- 「开始自测」
- 「跑一轮自测」
- 「帮我验一下这个功能」

开测前先确认档位：L1 静态 / L2 接口 / L3 端到端。L2/L3 需要用户授权编译、起服务、开浏览器。

## 3. 七步流程

1. 定档 + 定范围 + 判模块类型。
1.5 用户口述需求，与项目文档对齐；冲突由用户裁决。
2. 拆五层验收点（功能 / 流程 / 数据 / 逻辑 / 规范）。
3. 设计用例并冻结 `cases.md`，记录 SHA256。
4. 执行静态 / 接口 / 无头 UI 测试，采集证据。
5. 链路三验 + 规范六类核对。
6. 数据复原、清理、反证 pass、缺陷记录、自检脚本、生成 HTML 报告。
7. 复盘写入 `EVOLUTION.md`。

## 4. 产物

```text
.codebuddy/selftest/<YYYYMMDD>-<功能名>/
├── cases.md        # 冻结用例，含期望来源
├── report.md       # 十四节机器校验底稿
├── report.html     # 管理者阅读视图
├── shots/          # 截图
└── bugs.json / bugs.xlsx / zentao_bugs.json   # 有缺陷时
```

生成 HTML：

```powershell
python scripts/report_html.py --report "<产物>/report.md" --cases "<产物>/cases.md" --out "<产物>/report.html"
```

有缺陷时追加 `--bugs "<产物>/bugs.json"`。生成 `bugs.xlsx` 前安装依赖：`python -m pip install -r requirements.txt`。

## 5. 安全规则

- 测试期间业务仓库只读；唯一可写是 `.codebuddy/selftest/<本轮>/`。
- 写库必须确认测试环境、`SELFTEST_` 前缀、改行先快照、主键 WHERE、`try/finally` 清理、结束验证复原。
- 账号 CSV 含明文密码，只保存在本机；不进报告、截图、日志、缺陷 Excel。
- 转发前运行 `scripts/export-sanitized.ps1`；对外分享用 `-OmitAccounts`。
- 真实 `project-profile.md`、`test-accounts.csv`、`code-owners.json` 都被 `.gitignore` 忽略。

## 6. 独立 agent

安装 `agents/module-test-runner.md` 到 `~/.codebuddy/agents/` 后，主会话优先派它执行；未安装则按降级规则执行并声明结论上限。

agent 模板不绑定模型和 MCP server，使用前按本机环境配置；建议选择不同厂/不同代的模型以降低同源偏差。
