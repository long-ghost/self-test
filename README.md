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

## 安装（把仓库地址交给 AI 即可）

本机需要 Git 与 PowerShell（Windows PowerShell 5.1 或 PowerShell 7）。让 AI 执行：

```powershell
$tmp = Join-Path $env:TEMP ('module-test-install-' + [guid]::NewGuid())
git clone --depth 1 https://github.com/long-ghost/self-test.git $tmp
powershell -NoProfile -File "$tmp/module-test/scripts/install.ps1"
Remove-Item -Recurse -Force $tmp
```

安装脚本会：把仓库 clone/更新到缓存目录 `~/.codebuddy/skill-cache/module-test` → 同步 `module-test/` 到 `~/.codebuddy/skills/module-test/` → 首次安装时复制独立 agent 到 `~/.codebuddy/agents/` → 写安装记录 `.install.json`。

可选参数：`-RepoUrl`、`-Ref`、`-CacheDir`、`-SkillDir`、`-AgentDir`、`-SkipAgent`、`-Force`（重装）。

> 离线包方式：`dist/module-test.zip` 解压后把 `module-test/` 放到 `~/.codebuddy/skills/module-test/`；之后想启用自动更新，用上面的 `install.ps1` 接管一次（补齐安装记录）。

安装后在目标项目根目录初始化本地配置：

```powershell
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/init-workspace.ps1" -Root "<project-root>"
```

按 `references/setup-status.md` 补齐 `project-profile.md`、`test-accounts.csv`，按需填 `code-owners.json`，然后对 AI 说「测试一下 <模块名>」。

> 生成缺陷 Excel 需要 `openpyxl`：`python -m pip install -r "$HOME/.codebuddy/skills/module-test/requirements.txt"`。

## 更新

```powershell
# 只看有没有更新：0 已最新 / 2 有更新 / 1 出错，不改任何文件
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/check-update.ps1"

# 升级：保留 4 个本地配置，其余以仓库为准
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/update.ps1"
```

检查更新是手动动作：想升级时先跑 `check-update.ps1` 看新旧版本、提交区间和 CHANGELOG 对应段落，确认后再跑 `update.ps1`。AI 侧约定写在 `SKILL.md`「安装与更新」：只有用户明确要求才检查，升级只在两轮自测之间做。

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

技能目录由安装/更新脚本托管：同步时以上 4 个文件原样保留，其他本地新增文件会被删除。安装记录在 `.install.json`（版本、提交、远程地址），删掉它等于放弃自动更新。

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
