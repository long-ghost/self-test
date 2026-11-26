# module-test

模块级自测技能：定档、需求确认、用例冻结、接口/页面验证、证据报告、缺陷记录与 HTML 视图。

## 快速开始

```powershell
# 1. 安装（Git 方式，支持后续更新；zip 解压的也用 install.ps1 接管一次）
powershell -NoProfile -File "<仓库>/module-test/scripts/install.ps1"

# 2. 在目标项目根目录初始化本地配置
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/init-workspace.ps1" -Root "<project-root>"

# 3. 填写（本机文件，不提交）
#    references/project-profile.md
#    references/test-accounts.csv

# 4. 用户要求时手动检查更新（0 最新 / 2 有更新 / 1 出错），确认后跑 update.ps1
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/check-update.ps1"

# 5. 对 AI 说：测试一下 <模块名>
```

完整说明见 `references/usage.md`；账号填写见 `references/accounts-setup.md`。生成缺陷 Excel 前安装依赖：`python -m pip install -r requirements.txt`。

## 关键约束

- L2/L3 缺少项目适配层或账号表会停下并提示补齐。
- L4 另需 Node ≥20.19 + pnpm + 全局 runner + 模型 Key + `E2E_ROOT/e2e/midscene/suite.json`（默认 `<repo>/E2E测试/`），缺一即停；AI 断言按 M3，数值/权限需 M1/M2 交叉核验。
- 需求冲突必须由用户裁决，确认后才冻结用例。
- 能力内可测项不得写进「未覆盖」；未覆盖必须留四要素证据。
- 测试期间业务仓库只读；写库必须复原。
- 账号密码不进入报告、截图、日志或缺陷文件。
