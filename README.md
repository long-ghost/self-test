# module-test

`module-test` 是一个可独立维护与发布的模块级自测技能：从需求确认、用例冻结，到接口/页面验证、证据报告、缺陷记录和 HTML 视图。

## 仓库结构

```text
.
├── module-test/          # 可安装、可打包的 skill 包
├── scripts/              # 仓库构建与脱敏校验
├── tests/                # 合成数据 smoke test
└── .github/workflows/    # CI
```

`module-test/` 是指南、脚本、模板与通用示例；真实项目配置、账号和责任人映射由使用者本地生成，不进入 Git。

## 安装

1. 下载 `dist/module-test.zip`，解压得到 `module-test/`。
2. 放到 `~/.codebuddy/skills/module-test/`。
3. 可选：把 `module-test/agents/module-test-runner.md` 复制到 `~/.codebuddy/agents/`，并按本机环境配置模型/数据库 MCP。
4. 在目标项目根目录运行（`-Root` 指向待测项目）：

```powershell
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/init-workspace.ps1" -Root "<project-root>"
```

5. 按 `references/setup-status.md` 补齐：
   - `references/project-profile.md`
   - `references/test-accounts.csv`
   - 按需填写 `references/code-owners.json`
6. 对 AI 说「测试一下 <模块名>」。

> 生成缺陷 Excel 需要 `openpyxl`：`python -m pip install -r module-test/requirements.txt`。

## 首次初始化会做什么

- 探测项目根、工程文件、环境配置、规则文件。
- 能自动填的项目配置写成 `AUTO-DETECTED` 草稿，未知项写 `TODO`。
- 从示例复制账号/责任人模板，真实账号密码写 `REPLACE_ME`，不自动编造。
- 生成 `references/setup-status.md`，列出缺失项以及缺失时能跑哪个档位。

## 本地文件与安全

以下文件只保存在本机，已被 `.gitignore` 忽略：

```text
module-test/references/project-profile.md
module-test/references/test-accounts.csv
module-test/references/code-owners.json
module-test/references/setup-status.md
```

账号 CSV 含明文密码，不进报告、截图、日志、缺陷 Excel；转发前运行 `module-test/scripts/export-sanitized.ps1`，对外分享用 `-OmitAccounts`。

## 开发与发布

```powershell
# 脱敏扫描（全仓）
powershell -NoProfile -File scripts/sanitize_check.ps1

# smoke test
python tests/smoke_test.py

# frontmatter 校验
python tests/validate_skill.py

# 打包（需要本机 skill-creator）
powershell -NoProfile -File scripts/build_release.ps1 `
  -PackageScript "<skill-creator>/scripts/package_skill.py"
```

产物为 `dist/module-test.zip`，zip 顶层为 `module-test/`。发布流程见 `CONTRIBUTING.md`。

## 版本

从 `v1.0.0` 开始独立版本线，变更记录见 `CHANGELOG.md`。
