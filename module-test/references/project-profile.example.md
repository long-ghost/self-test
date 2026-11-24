# 项目适配层（示例）

> 复制本文件为 `references/project-profile.md` 后填写。真实文件只保存在本机，不提交。
> 本文件只保留占位符，不包含任何真实项目地址、账号或凭据。

## 项目标识

- 项目名：`<project>`
- 模块名：`<module>`
- 仓库根：`<repo-root>`
- 环境：`<test-env>`（禁止在生产环境造数）

## 端口与地址

| 服务 | 地址 | 配置位置 |
|---|---|---|
| 后端 | `<backend-host>:<backend-port>` | `<backend-config>` |
| 前端 | `<frontend-host>:<frontend-port>` | `<frontend-config>` |
| 数据库 | `<db-host>:<db-port>` / `<db-name>` | `<db-config>` |

## 启动与编译

```powershell
# 启动命令：按项目实际填写
<start-command>

# 仅编译：按项目实际填写
<build-command>
```

- 后端就绪标志：`<ready-log-line>`
- 前端构建前的环境变量：`<node-options>`

## 接口鉴权

- token 存储位置：`<token-storage-key>`
- token 请求头：`<token-header>`
- 示例请求：

```powershell
curl.exe -H "<token-header>: $token" "<api-base>/<path>"
```

## 测试账号

- 真实账号表：`references/test-accounts.csv`（本地文件，不提交）
- 账号选择与填写规范：`references/accounts-setup.md`
- 账号复核 SQL：

```sql
-- 按项目实际表名替换
SELECT id, name, account, mobile, status
FROM <user-table>
WHERE is_deleted = 0;
```

## 写库（可自助，必须复原）

- 读取：优先用数据库 MCP / CLI。
- 写入：Python + pymysql 或项目提供的测试数据脚本。
- 先确认：`SELECT @@hostname, DATABASE();` 必须是测试环境。
- 禁止 DDL 与系统表；新增行使用 `SELFTEST_` 前缀；改行先快照；`DELETE/UPDATE` 必须带主键；`try/finally` 清理；结束验证复原。

## 浏览器

```powershell
# 按项目实际浏览器与驱动填写
<browser-command>
```

- 无头优先；操作后等待渲染稳定再截图；收尾关闭浏览器与端口。

## 规范文件位置

| 内容 | 路径 |
|---|---|
| 项目规则 | `<project-rules>/` 或 `AGENTS.md` |
| UI 规范 | `<project-rules>/ui/` |
| 用户规则 | `<user-rules>/` |

## 产物目录

`.codebuddy/selftest/<YYYYMMDD>-<功能名>/`，只留 `cases.md`、`report.md`、`report.html`、`shots/`，有缺陷时加 `bugs.json`、`bugs.xlsx`、`zentao_bugs.json`。
