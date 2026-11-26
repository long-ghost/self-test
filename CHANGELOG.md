# Changelog

## v1.3.0 — 2026-11-24

- 新增 L4 档位：Midscene Test AI 驱动端到端测试（YAML 用例 + 自然语言步骤 + AI 断言），用例沉淀到业务仓库 `e2e/midscene/`。
- 新增 `scripts/l4-init.ps1`：检查 Node/pnpm/Chromium/模型 Key，`-Install` 安装依赖与 `node-spec.md`，`-ModelVerify` 验证模型连通性。
- 新增 `scripts/l4-run.ps1`：套件选择、每轮暂存到全局 runner、执行、归档结果/截图、`git status` 越界校验；运行前校验 `cookiesEnv` / `storageStatePath`，缺失退出 2；退出码 0/1/2/3/4。
- 新增 `scripts/l4_suite.py`（collect/upsert/export）与 `scripts/l4_summary.py`（多形状归一化、脱敏、unmapped 检测）。
- 新增资产 `midscene-cases-template.yaml` / `midscene-config-template.ts` / `midscene-suite.schema.json` 与 `references/l4-midscene.md`。
- 报告模板增加 L4 首部两行与「十五、L4 端到端（Midscene）」；`check-report.ps1` 增加 L4 分支（suite 哈希、计数一致性、判据与交叉核验、证据存在性）。
- `report_html.py` 支持 `--l4`，新增 L4 区块与套件哈希，非 L4 输出不变。
- 独立 agent、SKILL、usage、README 同步 L4；新增 `tests/check_report_smoke.ps1` 与 L4 fixtures。

## v1.2.2 — 2026-11-24

- 修复协议相对外链与 UNC 路径被当作本地图片加载的问题。
- 风险指标新增独立样式，区别于普通指标与可点击缺陷指标。
- 缺陷明细每条改为默认收起的折叠块，摘要显示序号、等级、标题与模块。
- 证据条四类改为高区分度颜色，并在图例与筛选 chip 加同色强调。

## v1.2.1 — 2026-11-24

- 测试结论下的说明行改为醒目的指标块，缺陷数在有缺陷时可点击。
- HTML 报告新增内联缺陷明细区，点击缺陷数跳转到 `#defects`。
- 证据条图例改为四列单行展示，不再把「没测到」等标签挤到下一行。

## v1.2.0 — 2026-11-24

- 报告首部新增 `测试耗时`，按整轮口径记录开测确认范围到报告定稿的起止时间与总分钟。
- HTML 报告顶栏显示「耗时 N 分钟」，旧报告缺字段时显示「耗时未记录」。
- `check-report.ps1` 校验耗时格式、时间顺序与分钟数一致性。
- 独立测试 agent 必须记录真实起止时间，交付摘要增加耗时项。

## v1.1.0 — 2026-11-24

- 新增 Git 自助安装：`scripts/install.ps1` 把仓库缓存 clone 到 `~/.codebuddy/skill-cache/module-test`，同步技能目录并写安装记录 `.install.json`；zip 解压安装可被接管。
- 新增更新检测：`scripts/check-update.ps1` 比对本地与远端版本/提交，打印变更提交与 CHANGELOG 段落，退出码 0 最新 / 2 有更新 / 1 出错。
- 新增升级脚本：`scripts/update.ps1` 快进合并缓存并同步，保留 4 个本地配置文件，不覆盖用户改过的独立 agent（差异写 `.new`）。
- `SKILL.md` 增加「安装与更新」约定：仅在用户明确要求时手动检查更新、有更新先告知用户、自测中途不升级；版本升至 `1.1.0`。
- README / usage 安装步骤改为 Git 安装；新增安装冒烟测试。

## v1.0.0 — 2026-11-24

- 初始公开版 `module-test`。
- 保留七步自测流程、28 条规则、需求确认、CSV 账号、HTML 报告、缺陷记录。
- 项目适配层、账号表、责任人映射改为示例模板；真实文件由初始化脚本本地生成。
- 新增通用独立测试 agent 模板 `module-test/agents/module-test-runner.md`。
- 新增全仓脱敏检查与合成数据 smoke test。
