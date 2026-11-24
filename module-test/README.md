# module-test

模块级自测技能：定档、需求确认、用例冻结、接口/页面验证、证据报告、缺陷记录与 HTML 视图。

## 快速开始

```powershell
# 1. 把本目录放到 ~/.codebuddy/skills/module-test/
# 2. 在目标项目根目录初始化本地配置
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/init-workspace.ps1" -Root "<project-root>"

# 3. 填写（本机文件，不提交）
#    references/project-profile.md
#    references/test-accounts.csv

# 4. 对 AI 说：测试一下 <模块名>
```

完整说明见 `references/usage.md`；账号填写见 `references/accounts-setup.md`。生成缺陷 Excel 前安装依赖：`python -m pip install -r requirements.txt`。

## 关键约束

- L2/L3 缺少项目适配层或账号表会停下并提示补齐。
- 需求冲突必须由用户裁决，确认后才冻结用例。
- 能力内可测项不得写进「未覆盖」；未覆盖必须留四要素证据。
- 测试期间业务仓库只读；写库必须复原。
- 账号密码不进入报告、截图、日志或缺陷文件。
