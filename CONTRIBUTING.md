# 贡献与迭代规范

## 目录职责

- `module-test/SKILL.md`：技能入口、流程骨架、硬规则。修改前先读 `references/`。
- `module-test/references/`：按需加载的规则与模板说明。
- `module-test/scripts/`：可执行脚本；不得写死具体项目路径或凭据。
- `module-test/assets/`：报告、用例、缺陷模板。
- `module-test/agents/`：可选独立 agent 模板。
- `scripts/`：仓库级构建与脱敏检查，不进入 skill zip。
- `tests/`：合成数据测试，不包含真实项目数据。

## 修改流程

1. 从 `main` 开分支。
2. 修改 `module-test/` 下相关文件。
3. 同步更新：
   - `CHANGELOG.md`
   - `module-test/EVOLUTION.md`（只追加有证据的改进）
   - 相关 `references/usage.md`
4. 运行：

```powershell
powershell -NoProfile -File scripts/sanitize_check.ps1
python tests/smoke_test.py
```

5. 需要发版时运行 `scripts/build_release.ps1`，检查 `dist/module-test.zip`。
6. 提交 PR，说明改动、验证命令和用户可见行为。

## 版本规范

- 使用语义化版本：`MAJOR.MINOR.PATCH`。
- `MAJOR`：破坏流程或规则兼容性。
- `MINOR`：新增规则、脚本能力或模板字段。
- `PATCH`：文案、示例、bug fix。
- `SKILL.md` frontmatter 的 `version`、`CHANGELOG.md` 必须同步。

## 脱敏红线

禁止提交：

- 真实项目名、内部模块名、内部 IP/端口、数据库名、库表名、鉴权头。
- 真实姓名、手机号、密码、token、cookie、提交 hash、绝对路径。
- 当前项目的 `EVOLUTION.md` 历史、`designs/`、`plans/`、`shots/`、`report.md`、`cases.md`。
- 任何真实账号 CSV 或责任人映射。

只能提交示例/占位值：`<project>`、`<module>`、`<host>`、`REPLACE_ME`。

## 发布

1. 更新版本号与 `CHANGELOG.md`。
2. 跑 sanitize + smoke test。
3. `scripts/build_release.ps1` 生成 zip。
4. 检查 zip 列表不含真实配置文件。
5. 打 tag，例如 `v1.0.0`，附上 `dist/module-test.zip`。
