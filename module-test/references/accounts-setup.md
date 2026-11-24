# 测试账号配置规范

## 文件位置

- 模板：`references/test-accounts.example.csv`
- 本地真实文件：`references/test-accounts.csv`
- 真实文件不提交 Git，已在 `.gitignore` 中忽略。

首次使用运行：

```powershell
powershell -NoProfile -File "$HOME/.codebuddy/skills/module-test/scripts/init-workspace.ps1" -Root "<project-root>"
```

初始化会从模板复制出真实文件，姓名、电话、密码写 `REPLACE_ME`。**脚本不会自动生成真实账号或密码。**

## CSV 格式

```csv
姓名,部门,联系电话,密码,适用场景
示例用户,示例部门,REPLACE_ME,REPLACE_ME,全公司数据范围
```

- `联系电话`：登录账号。
- `密码`：只在本机保存，不写进报告、截图、日志、命令行历史。
- `适用场景`：多个场景用分号分隔，例如 `全公司数据范围;只读查询`。
- 一人多部门用中文顿号连接，例如 `部门A、部门B`。

## 填写规范

1. 用 Excel 打开 `test-accounts.example.csv`，另存为 `test-accounts.csv`，编码选 **CSV UTF-8**。
2. 不要改表头；不要留空手机号或密码。
3. 账号状态、部门归属可用项目用户表/部门关系表复核；以数据库为准。
4. 账号表只保存在本机技能目录，不复制到项目仓库、报告目录、聊天记录。
5. 转发或打包前运行：

```powershell
powershell -NoProfile -File scripts/export-sanitized.ps1 -Dest <导出目录>
```

默认会把手机号中间四位和密码打码；对外分享建议加 `-OmitAccounts`，不导出账号表。

## 缺失时的影响

- L1：不需要登录账号，可以执行静态/契约核对。
- L2 / L3：没有真实账号无法登录、无法验越权与页面闭环；首次运行门禁会直接停下，并打印缺失项。
- 账号表存在但没有对应场景的账号：先补建账号或换用有权限的账号，不要用相邻视角推断。
