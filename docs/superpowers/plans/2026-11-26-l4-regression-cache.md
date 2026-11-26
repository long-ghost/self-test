# L4 回归套件与缓存加速 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 module-test 技能能把 L4 已通过的用例沉淀为可日常巡检的回归套件，并用 Midscene TaskCache 加速重复执行。

**Architecture:** 在 suite.json 增加用例生命周期字段，用 `l4_suite.py promote/select/explain` 管理准入；新增 `l4-regression.ps1` 作为薄封装，复用 l4-run 的执行核心，向 Midscene Agent 注入 cache 参数（read-only 回归 / write-only 重建），结果归一化带缓存统计与疑点标记。所有改动同时落到技能安装目录 `~/.codebuddy/skills/module-test` 和源仓库 `<repo>/module-test`。

**Tech Stack:** Python 3.11（json/pathlib/argparse）、PowerShell 5.1（必须 UTF-8 BOM）、Midscene Test 1.18.2（TaskCache via Agent `cache` 选项）。

**Spec:** `docs/superpowers/specs/2026-11-26-l4-regression-cache-design.md`

## Global Constraints

- Midscene 版本 1.18.2；cache 配置只接受 `{ id, strategy: 'read-only'|'read-write'|'write-only', cacheDir }`，落盘 `<cacheDir>/<id>.cache.yaml`。
- cache id = `l4-<moduleSlug>-<sha8(按 caseId 排序的 caseId+file+用例YAML内容)>`，**不得**用 suite.json 全文哈希；用例 YAML 不变则 id 不变。
- `moduleSlug` 取用例编号前缀小写，如 `L4-DDASH-001` → `ddash`。
- cacheDir = `E2E_ROOT/e2e/midscene/cache`（跟随大目录），回归默认 `read-only`，首跑/重建 `write-only`。
- 所有新增/修改的 `.ps1` 必须是 UTF-8 BOM；`e2e-root.ps1` 已是正确范例。
- 仓库只读范围：业务源码不动；只写技能的 `scripts/`、`assets/`、`references/`、文档，以及 `E2E测试/` 产物。
- `promote` 取代 `upsert` 管理 `lastStatus`/`lastVerified` 与生命周期；`upsert` 保留兼容但打印 deprecated 提示。
- `collect` 合并白名单必须包含全部 lifecycle 字段，防止 collect 清空状态。
- 用户对失败兜底的裁决：aiAct 缓存失败靠 Midscene 内置 stale-replan；aiAssert 失败不触发 replan，标 `cacheSuspect=true` 提示复核，不自动记产品缺陷。
- 稳定准入：连续 3 次 pass 才 `stable`，中间失败清零；`confirmed-bug` 不自动转正，需显式 `promote --status fixed`。

## Review Focus

1. **cache id 漂移**：回写 `lastStatus` 后 id 必须不变；改 YAML 后 id 必须变。→ Task 2 测试。
2. **collect 抹掉生命周期**：`collect` 后 `maturity`/`consecutivePasses`/`confirmedBug` 必须保留。→ Task 2 测试。
3. **confirmed-bug 被洗白**：passed 不得自动把 `confirmed-bug` 转 stable。→ Task 2 测试。
4. **read-only 被写穿**：read-only 跑完 cache 文件 mtime 不变。→ Task 5 验收。
5. **断言失败被误判为产品 bug**：read-only 命中缓存的 aiAssert 失败必须标 `cacheSuspect=true`。→ Task 4 测试 + Task 5 验收。

---

### Task 1: suite schema 与生命周期字段定义

**Files:**
- Modify: `<repo>/module-test\assets\midscene-suite.schema.json`
- Modify: `<repo>/module-test\assets\cases-template.md`（如含字段说明）

**Interfaces:**
- Consumes: 现有 schema 的 `caseId/file/name/tags/criterion/crossVerifiedBy/lastStatus/lastVerified/firstSeen`。
- Produces: 每个 case 可选字段 `maturity`（enum draft/candidate/stable/confirmed-bug/retired）、`consecutivePasses`（int≥0）、`lastFailure`（object at/reason/cacheReplan）、`confirmedBug`（object at/bugId/note）；`regressionEligible` 为派生不落盘。

Steps:
- [ ] **Step 1: 在 schema 的 `cases.items.properties` 增加 4 个字段**，全部非 required，`maturity` 按 enum 约束，`consecutivePasses` 最小值 0，`lastFailure` 与 `confirmedBug` 按上述子字段定义；不新增 required 项以保持老 suite 兼容。
- [ ] **Step 2: 校验** `python -c "import json;json.load(open('.../midscene-suite.schema.json',encoding='utf-8'))"` 通过，且与现有 `E2E测试/e2e/midscene/suite.json` 的 5 条用例做只读兼容检查（不修改 suite）。
- [ ] **Step 3: Commit** `git add module-test/assets/midscene-suite.schema.json && git commit -m "feat(l4): add suite lifecycle fields schema"`。

### Task 2: l4_suite.py 生命周期命令与缓存 id

**Files:**
- Modify: `<repo>/module-test\scripts\l4_suite.py`
- Test: `<repo>/tests\test_l4_suite_lifecycle.py`（新建，用 unittest，不依赖 pytest）

**Interfaces:**
- Consumes: `load_suite(path)->dict`、`write_suite(path,suite)`、`_case_files(root)->list[Path]`、`_e2e_root(repo)->Path`、`_entry_defaults(...)`（Task 1 后）。
- Produces:
  - `stable_cache_id(repo: Path, suite: dict) -> str`：按 caseId 排序，拼 `caseId|file|<YAML bytes sha256>`，返回 `l4-<slug>-<sha8>`；slug 取首个 caseId 的模块码小写（DDASH→ddash）。
  - `cmd_promote(args)`：处理 `--status passed|failed|skipped|fixed`、`--case-id`、`--bug-id`、`--note`、`--authorize`；内部完成原 upsert 的 lastStatus/lastVerified 回写 + 生命周期计数；upsert 子命令打印 deprecated 提示后转调 promote。
  - `cmd_select(args)`：`--kind regression|stable|bug|all`，输出 `{"schemaVersion":1,"project":...,"module":...,"cases":[...]}` 到 `--out`（无 out 则 stdout）。
  - `cmd_cache_id(args)`：子命令 `cache-id --repo-root <repo> [--suite <path>]`，stdout 只打印 `stable_cache_id()` 的结果（供 PowerShell 捕获）。
  - `cmd_explain(args)`：打印生命周期与历史摘要。
  - `cmd_collect`：合并白名单新增 `maturity/consecutivePasses/lastFailure/confirmedBug`；`_entry_defaults` 新增 `maturity="draft"`、`consecutivePasses=0`。

Steps:
- [ ] **Step 1: 写失败测试** `tests/test_l4_suite_lifecycle.py`，断言：① 同一 suite 改 `lastStatus` 后 `stable_cache_id()` 不变；② 改用例 YAML 字节后 id 变；③ `collect` 合并保留 `maturity=stable` 与 `consecutivePasses=2`；④ `confirmed-bug` 用例收到 passed 后仍是 `confirmed-bug`；⑤ 连续 3 次 passed 后 maturity=stable；⑥ failed 后 consecutivePasses=0；⑦ `select --kind regression` 只含 stable+confirmed-bug。
- [ ] **Step 2: 运行测试确认 FAIL**：`python -m unittest tests.test_l4_suite_lifecycle -v`。
- [ ] **Step 3: 实现 Task 2 Interfaces 中的函数与 argparse 子命令**，并在 `upsert` 分支打印 `upsert is deprecated; use promote`。
- [ ] **Step 4: 运行测试确认 PASS**：同上命令。
- [ ] **Step 5: Commit**。

### Task 3: runner 配置模板注入 cache

**Files:**
- Modify: `<repo>/module-test\assets\midscene-config-template.ts`
- Modify（安装目录同步）: `~/.codebuddy/skills/module-test\assets\midscene-config-template.ts` 与 `~/.codebuddy/skill-data/module-test/l4-runner\templates\midscene.config.ts`

**Interfaces:**
- Consumes: 环境变量 `L4_CACHE_ID` / `L4_CACHE_STRATEGY` / `L4_CACHE_DIR`（Task 4 注入）。
- Produces: 无 `L4_CACHE_ID` 时行为与现状完全一致；有 id 时向 `new PlaywrightAgent(page, {...})` 传 `cache: { id, strategy, cacheDir }`。

Steps:
- [ ] **Step 1: 在 `getAgent` 里按设计文档 5.3 的代码片段加入条件 cache 参数**，strategy 用类型断言限定三种值；不传未定义字段。
- [ ] **Step 2: 把两个副本同步为该内容**（源仓库 → 安装目录 → runner templates），用 Get-FileHash 确认三处字节一致，runner 的 `.ts` 保留原编码。
- [ ] **Step 3: 运行时验证** `cd ~/.codebuddy/skill-data/module-test/l4-runner; pnpm exec midscene-test nodes --config ./templates/midscene.config.ts --project web` 输出 33 个节点、exit 0。
- [ ] **Step 4: Commit** 源仓库文件。

### Task 4: l4-run.ps1 缓存参数与 cacheStats

**Files:**
- Modify: `<repo>/module-test\scripts\l4-run.ps1`
- Modify: `~/.codebuddy/skills/module-test\scripts\l4-run.ps1`（同步）
- Modify: `l4_summary.py`（若归一化需新增字段）

**Interfaces:**
- Consumes: Task 2 的 `stable_cache_id()`（通过 python 子进程调用）、Task 3 的三个环境变量。
- Produces:
  - `l4-run.ps1` 新参数 `-CacheStrategy <read-only|write-only>`（默认空=不注入缓存）、`-RebuildCache`（等价 write-only）、`-UpdateSuite` 时回写调用 `promote` 而非 `upsert`。
  - 产物 `l4/cache-stats.json`：`{cacheId, strategy, cacheFile, cacheReplanCases, note}`，`hit` 若无结构化来源则写 `"未采集"`。
  - `l4-summary.json` 每个 case 新增可选 `cacheSuspect`/`cacheReplan` 布尔标记（aiAssert 失败且当轮 read-only 时 `cacheSuspect=true`）。

Steps:
- [ ] **Step 1: 在 l4-run.ps1 参数块加 `-CacheStrategy` / `-RebuildCache`**，在调用 midscene 前通过 `python l4_suite.py cache-id --repo-root <repo> [--suite <path>]` 计算 cache id（该子命令输出纯 id 字符串到 stdout，由 Task 2 实现）；失败则退出 2 并报错；把 id/strategy/cacheDir 设为进程环境变量。
- [ ] **Step 2: 修改结果复制/归一化段**：复制或生成 `l4/cache-stats.json`；从 console.log 统计 `will replan and disable the stale cache` 次数写 `cacheReplanCases`；不编造 hit 数字。
- [ ] **Step 3: 把 `-UpdateSuite` 的 upsert 调用换成 promote 调用**，参数映射：`--case-id/--status <passed|failed|skipped> --authorize`。
- [ ] **Step 4: 在 l4_summary.py 的 case 归一化中读取 console.log 的 replan 与策略**，为 aiAssert 失败 + read-only 命中的 case 写 `cacheSuspect=true`。
- [ ] **Step 5: 验证** `-DryRun` 不注入缓存也能跑；带 `-CacheStrategy read-only -DryRun` 打印 cache id 与策略、exit 0；PowerShell ParseFile 零错误。
- [ ] **Step 6: Commit**。

### Task 5: l4-regression.ps1 回归命令

**Files:**
- Create: `<repo>/module-test\scripts\l4-regression.ps1`
- Create（同步）: `~/.codebuddy/skills/module-test\scripts\l4-regression.ps1`

**Interfaces:**
- Consumes: `l4_suite.py select --kind ... --out <temp>`、`l4-run.ps1 -CacheStrategy/-RebuildCache/-UpdateSuite`（Task 4）。
- Produces: 一条命令完成"选回归用例 → 建缓存/读缓存 → 执行 → 回写生命周期"。

Steps:
- [ ] **Step 1: 写脚本骨架**：参数 `-Round`（必填，E2E_ROOT 下）、`-Suite`、`-Module`、`-Kind stable|bug|all`（默认 all）、`-CacheStrategy read-only|write-only`（默认 read-only）、`-RebuildCache`、`-Case/-Tag`、`-Secrets`、`-DryRun`、`-UpdateSuite`。
- [ ] **Step 2: 调 `l4_suite.py select` 到系统临时目录**（不写业务仓库）；空集打印"还没有 stable 用例，先跑 L4 自测并 promote"并 exit 2；`-DryRun` 到此为止、清理临时文件、exit 0。
- [ ] **Step 3: 把临时 select 结果作为 l4-run 的 -Suite 参数调用**，透传 `-CacheStrategy/-RebuildCache/-Case/-Tag/-Secrets/-UpdateSuite/-Round`；finally 清理临时文件。
- [ ] **Step 4: 验证**：当前 5 条用例都 draft，`-DryRun` 应 exit 2 并提示；手工把 suite 里一条标 stable 后（临时副本，验证后还原），`-DryRun` exit 0 并打印选中 1 条。
- [ ] **Step 5: 同步安装目录副本并 Commit**。

### Task 6: 文档、报告模板与自检

**Files:**
- Modify: `references/l4-midscene.md`、`SKILL.md`、`assets/report-template.md`、`scripts/check-report.ps1`（源仓库 + 安装目录同步）

**Interfaces:**
- Consumes: Task 4 的 `l4/cache-stats.json` 与报告首部字段。
- Produces: 新增"回归与缓存"章节、`L4 回归` 首部行、check-report 对回归产物的可选校验。

Steps:
- [ ] **Step 1: l4-midscene.md 加"回归与缓存"章节**：命令、准入、cache id 口径、read-only/write-only、失败复核（aiAct replan vs aiAssert cacheSuspect）。
- [ ] **Step 2: SKILL.md 资源索引加 `l4-regression.ps1`，L4 档位说明加回归入口一句。**
- [ ] **Step 3: report-template.md 十五节加缓存统计行；check-report.ps1 仅当 `l4/cache-stats.json` 存在时校验其字段，普通 L4 不强制。**
- [ ] **Step 4: 同步安装目录、语法检查（PowerShell ParseFile + Python py_compile）、Commit。**

### Task 7: 端到端验收与同步

**Files:** 无新增代码；改动 `E2E测试/e2e/midscene/suite.json`（经合法命令回写）。

Steps:
- [ ] **Step 1: 不依赖服务的验证**：`l4-regression.ps1 -DryRun` 空集 exit 2、有 stable 时 exit 0；所有脚本语法检查；`collect` 后 lifecycle 字段不丢；cache id 稳定性单测 PASS。
- [ ] **Step 2: 需要真实服务与模型 Key 的验收（用户需确认执行时机）**：write-only 首跑生成 `cache/<cacheId>.cache.yaml`；紧接着 read-only 回归确认用例全部执行且 cache 文件 mtime 不变、`cache-stats.json` 有策略与 replan 计数；aiAct 缓存失效能触发 stale-replan、aiAssert 失败标 cacheSuspect。
- [ ] **Step 3: 若 Step 2 环境不具备，记录为"未覆盖 + 四要素"，不把 Step 1 的通过冒充端到端通过；结论上限相应收窄。**
- [ ] **Step 4: 复核 Review Focus 五条全部有证据；`git status` 只含预期文件；清理临时文件与 pycache。**
- [ ] **Step 5: 确认源仓库与安装目录所有改动文件哈希一致；本次不 commit/push 到 GitHub（用户未授权）。**
