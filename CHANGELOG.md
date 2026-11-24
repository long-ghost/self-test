# Changelog

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
