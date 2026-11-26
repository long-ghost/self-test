# L4 回归套件与缓存加速升级 — 设计文档

日期：2026-11-26
状态：待用户审批（brainstorming HARD-GATE：审批前不写实现代码）

## 1. 意图与为什么

当前 L4 每轮自测从零设计用例、跑完即归档，历史用例躺在 `E2E测试/<时间戳>-*` 的报告里，下次回归要么重读报告手动重建，要么直接重跑一次全量自测。使用者的诉求：

1. 已经跑通、验证稳定的 L4 用例沉淀为长期资产，用于日常巡检 / 回归；
2. 确实发现系统 bug 的失败用例也保留，作为回归哨兵（bug 修复后应能自动转正）；
3. 对沉淀用例做准入、维护、执行管理，而不是一堆 YAML 互相堆着；
4. 利用 Midscene 的 `TaskCache` 让重复执行的用例少调 AI、省时间省 token；
5. 缓存命中执行失败时，不能把"缓存过期"误判为产品 bug，要有重规划兜底。

目标用户：module-test 技能的使用者（本机为派斯项目），在每次发版、日常巡检时一键跑已稳定的 L4 回归套件。

## 2. 目标 / 非目标 / 反目标

**目标**
- 一条命令跑回归套件（stable + confirmed-bug 哨兵），输出与现有 L4 报告同结构的结果。
- suite.json 有明确的用例生命周期字段，能追溯"谁准入的、稳定几次、上次结果、是否确认为 bug"。
- 缓存跨轮复用，日常回归稳定命中，新用例/改版用例可用 write-only 重建。
- 回归运行只读缓存；缓存导致的失败由 Midscene 内置 stale-replan 兜底，并在结果里留痕。

**非目标**
- 不实现 CI 调度 / 计划任务（使用者以后需要另开需求）。
- 不改 L1/L2/L3 的流程与报告结构。
- 不把报告结论的判据规则改掉（AI 断言仍 M3，数值仍需 M1/M2 交叉核验）。
- 不跳过用例执行：缓存只加速定位/规划，所有用例照常跑、断言照常判。

**反目标（做了就算失败）**
- 缓存污染：不同用例 / 不同环境 / 不同视口共用同一 cache id，导致命中错误定位。
- 假阳性：缓存过期导致定位失败被记成产品 bug。
- 假阴性：确认是 bug 的用例被"连续 pass"自动洗白成 stable。
- 回归套件悄悄改写基线缓存，让下一次结果不可复现。

## 3. 约束与依赖

- Midscene Test 版本：1.18.2（本机 runner 已安装并验证）。
- 缓存配置来自 `@midscene/core` 的 Agent 参数：`cache: { id, strategy: 'read-only'|'read-write'|'write-only', cacheDir }`；落盘 `<cacheDir>/<id>.cache.yaml`。
- Midscene 已内置：缓存的 aiAct 执行失败时打印 `cached aiAct plan failed, will replan and disable the stale cache` 并自动重新 AI 规划；read-only 模式不把重规划结果写回缓存文件。（源码：`agent.mjs` ~L490-520、`cache-config.mjs`、`task-cache.mjs`）
- 现有 runner 配置模板 `assets/midscene-config-template.ts` 里 `new PlaywrightAgent(context.page, {...})` 是注入 cache 参数的唯一位置；由 `L4_CACHE_ID` / `L4_CACHE_STRATEGY` / `L4_CACHE_DIR` 三个环境变量驱动，避免为每个模块改配置模板。
- 产物根沿用 `E2E_ROOT`（默认 `< repo >/E2E测试/`）；套件源在 `E2E_ROOT/e2e/midscene/`。
- 回归命令与脚本写在技能目录（安装目录 + 源仓库 `module-test-public` 同步），不写业务源码。
- 用户裁决（2026-11-26）：
  - 回归入口：技能内新增专用命令 `l4-regression.ps1`；
  - 缓存策略：回归默认 `read-only`，首跑/重建用 `write-only`；
  - 缓存目录：跟随 E2E测试 大目录 `E2E测试/e2e/midscene/cache/`；
  - 准入：连续 3 次 pass 才 `stable`，中间失败即清零；
  - 真 bug 失败用例标 `confirmed-bug` 作为回归哨兵，不参与 stable 自动转正。

## 4. 方案取舍（Approaches）

| 方案 | 做法 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| A. 新增回归命令 + suite 生命周期字段 | 新 `l4-regression.ps1`，suite 加 `maturity`/`consecutivePasses`/`confirmedBug` 等字段；缓存按 cache id 常驻 | 准入规则可机器执行，回归与探索分离，缓存有明确策略 | 改动最多（新脚本 + schema + 配置模板） | **选它**（用户裁决） |
| B. 只扩展 suite 字段，复用 `l4-run -Tag regression` | 不加新命令，靠 tag 过滤 | 改动小 | 准入/缓存策略靠人遵守，回归和探索混用同一命令，易污染缓存 | 弃 |
| C. 外置到业务项目/CI | 技能只产出 YAML，调度交外部 | 技能改动小 | 本机无 CI 需求，日常使用不便，缓存生命周期无人管 | 弃 |

选 A 的理由：使用者要的是"能日常巡检/回归的长期资产"，这要求准入与缓存策略是脚本强制的、不是约定俗成的；新增一个专用命令的代价可接受。

## 5. 详细设计

### 5.1 suite.json 生命周期字段（改 `assets/midscene-suite.schema.json` + `l4_suite.py`）

每个 case 新增字段（全部可选，老 suite 不破坏）：

| 字段 | 类型 | 语义 |
|---|---|---|
| `maturity` | enum: `draft` / `candidate` / `stable` / `confirmed-bug` / `retired` | 生命周期状态；默认 `draft` |
| `consecutivePasses` | int | 连续 pass 次数；失败即清零；`>=3` 时由脚本自动升 `stable`（`confirmed-bug` 除外） |
| `lastFailure` | { at, reason, cacheReplan? } | 最近一次失败；`cacheReplan=true` 表示 Midscene 日志里出现过 stale-replan |
| `confirmedBug` | { at, bugId, note } | 人工确认是真 bug 时填写；填了即 `maturity=confirmed-bug` |
| `regressionEligible` | bool（派生，不落盘） | `maturity in {stable, confirmed-bug}` |

`l4_suite.py` 新增子命令：
- `promote --case-id <id> --status passed|failed|skipped|fixed [--bug-id ...] [--note ...] [--authorize]`
  - **promote 取代 upsert**：它内部先做原本 upsert 的 `lastStatus`/`lastVerified` 回写，再做生命周期计数；`upsert` 子命令保留兼容但标 deprecated（打印提示），新脚本一律调 promote。
  - passed：`consecutivePasses+1`，到 3 自动 `stable`；
  - failed/skipped：`consecutivePasses=0`；failed 若带 `--bug-id` 则 `maturity=confirmed-bug` 并写 `confirmedBug`；
  - `confirmed-bug` 不受 passed 自动转正，必须显式 `promote --status fixed [--authorize]` 才回 `candidate`。
- `select --kind regression|stable|bug --out <suite-selected.json>`：按 maturity 过滤，输出与现有 `suite-selected.json` 同结构，供回归脚本直接喂给 runner。
- `explain --case-id <id>`：打印该用例的生命周期与最近 5 次历史摘要（历史从 `E2E测试/*/l4/l4-summary.json` 聚合，只读）。
- **collect 兼容**：`l4_suite.py` 的合并白名单（约 L218）必须加入全部新生命周期字段，否则 `collect` 会把 `maturity`/`consecutivePasses`/`confirmedBug` 等状态清空。

### 5.2 回归命令 `scripts/l4-regression.ps1`

参数（沿用 l4-run 风格）：

```
-Round <产物目录>          # 必填，必须在 E2E_ROOT 下（复用 e2e-root.ps1）
[-Suite <path>]            # 默认 E2E_ROOT/e2e/midscene/suite.json
[-Module <name>]           # 默认取 suite.module
[-Kind stable|bug|all]     # 默认 all = stable + confirmed-bug
[-CacheStrategy read-only|write-only]   # 默认 read-only
[-RebuildCache]            # 等价 -CacheStrategy write-only，日志提示"重建后下轮回 read-only"
[-Case <id> | -Tag <tag>]  # 在回归集合内再过滤
[-MaxFail N]               # 失败 N 条后中止（默认 0 = 不中止，跑完再报）
[-Secrets ...] [-DryRun] [-UpdateSuite]
```

流程（修改 l4-run.ps1 增加参数，regression 脚本是薄封装，二者共用执行核心）：
1. 解析 E2E_ROOT / suite / 本轮目录（复用 `Get-E2ERoot` / `Test-PathUnderRoot`）。
2. 调 `l4_suite.py select --kind ...` 得到只含回归用例的 `suite-selected.json`；空集直接退出 2 并提示"还没有 stable 用例，先跑 L4 自测并 promote"。
3. 计算 cache id：**`l4-<moduleSlug>-<sha8(稳定内容)>`**（用户裁决 2026-11-26）——
   - 稳定内容 = 本轮每个用例的 `caseId + file + 该 YAML 文件内容的 sha256`，按 caseId 排序后拼接；
   - **绝不能用 suite.json 全文哈希**：`lastStatus`/`consecutivePasses` 每次回写都会变，全文哈希会让 cache id 每轮漂移、缓存永远不命中；
   - `moduleSlug` = 模块名小写、非字母数字转 `-`（如 `D实绩首页驾驶舱` → `d----` 太短无意义，改用可读 slug：模块名映射到用例目录名，如 `001-D实绩首页驾驶舱` → `001-d` + 用例前缀小写，实现时取 `L4-DDASH` → `ddash`）；
   - 用例 YAML 改动才换 id；执行状态回写不影响；`cacheDir = E2E_ROOT/e2e/midscene/cache`。
4. 把 `L4_CACHE_ID` / `L4_CACHE_STRATEGY` / `L4_CACHE_DIR` 注入子进程环境；`read-only` 下 Midscene 只命中不改文件，`write-only` 下只写不读。
5. 执行 Midscene（与 l4-run 同一套暂存/结果/截图/越界检查逻辑）。
6. 结果归一化时增加 `cacheStats`：`cacheHitCases` / `cacheReplanCases` / `cacheMissCases`。采集口径（reviewer 修正）：`cache found` 是 debug 日志、不进 console.log，不能靠它计数；改为用 Midscene 官方报告 / `summary.json` 里是否有缓存命中的结构化字段（实现前先确认字段，若无则把 cacheStats 标为"未采集"而非编造数字）；`will replan and disable the stale cache` 是 console warn、可从 console.log 计数 `cacheReplanCases`。
7. 每条用例结果按 `promote` 规则回写 suite（只有 `-UpdateSuite` 时写；默认只输出建议）。
8. 产物落在 `<Round>/`，结构与现有 L4 一致，增加 `l4/cache-stats.json`。

**失败判定（回应用户补充，reviewer 修正）**：
- 缓存命中的 **aiAct** 执行失败 → Midscene 内置 stale-replan：自动重新 AI 规划并重跑该 aiAct，且 read-only 下不写回缓存。技能不额外重复执行整条用例，避免双重计数。
- stale-replan 只针对 **aiAct**；`aiAssert` 断言失败不会触发重规划（agent.mjs L507 仅 aiAct 路径）。所以"缓存导致断言误判"的兜底不是自动 replan，而是：读模式命中缓存的用例若断言失败，结果标 `cacheSuspect=true`，报告提示"用 -RebuildCache 复核后再定性"，**不自动记产品缺陷**。
- 若 console.log 出现 stale-replan 标记 → 该条标 `cacheReplan=true`，结论按最终断言结果处理；报告提示复核。
- 复核后仍稳定失败且无缓存疑点 → 正常按 bug 流程记缺陷，不自动标 `confirmed-bug`（那是人工裁决）。

### 5.3 缓存注入到 runner 配置模板

`assets/midscene-config-template.ts` 的 `new PlaywrightAgent(context.page, {...})` 改为：

```ts
new PlaywrightAgent(context.page, {
  testRunner: { getEnv: () => process.env, getBaseUrl: () => process.env.L4_BASE_URL || 'http://localhost:3000' },
  ...(process.env.L4_CACHE_ID ? {
    cache: {
      id: process.env.L4_CACHE_ID,
      strategy: (process.env.L4_CACHE_STRATEGY as 'read-only'|'read-write'|'write-only') || 'read-only',
      cacheDir: process.env.L4_CACHE_DIR,
    },
  } : {}),
})
```

没有 `L4_CACHE_ID` 时不传 cache 参数，行为与现在完全一致（普通 L4 自测不受影响）。同步改本机 runner 的 `templates/midscene.config.ts`（安装目录），实测 `midscene-test nodes` 仍注册 33 节点。

### 5.4 文档与报告

- `references/l4-midscene.md` 新增"回归与缓存"章节：命令、准入规则、cache id 计算、失败复核流程、read-only/write-only 语义。
- `SKILL.md` 资源索引加 `l4-regression.ps1`；L4 档位说明加一句"回归入口"。
- `assets/report-template.md` 十五节增加缓存统计行（用例 N / 缓存命中 x / 重规划 y）。
- `check-report.ps1` 只在回归产物存在 `l4/cache-stats.json` 时校验其字段，不强制普通 L4。
- 报告首部新增 `**L4 回归**：套件 N 条 / 缓存命中 M / 重规划 K`（非回归不出现）。

### 5.5 现有 5 条用例的迁移

- 当前 suite 的 5 条用例全部 `lastStatus` 空、`maturity` 缺省（视为 `draft`），不自动进回归套件。
- 处理方式：跑一次 `l4-regression.ps1 -Round ... -Kind all -CacheStrategy write-only -UpdateSuite` 作为"首跑建缓存 + 建立基线"；之后连续 3 次 pass 才逐条升 stable。
- 使用者可手动 `promote --case-id L4-DDASH-004 --status fixed --bug-id ...` 把确认的 bug 用例标为哨兵。

## 6. 留给实现者的工作（用户审批后）

1. 改 `assets/midscene-suite.schema.json`：加 5.1 的字段枚举与约束。
2. 改 `scripts/l4_suite.py`：实现 `promote` / `select` / `explain`，`_entry_defaults` 加 `maturity=draft`、`consecutivePasses=0`。
3. 改 `scripts/l4-run.ps1`：抽出/复用执行核心给 regression，加 `-CacheStrategy` / `-RebuildCache` / cache 环境变量注入 / cacheStats 归一化。
4. 新增 `scripts/l4-regression.ps1`：薄封装 + 空集保护 + 结果回写建议。
5. 改 `assets/midscene-config-template.ts` 与本机 runner 模板，实测 nodes 生成通过。
6. 改文档与报告模板，自检脚本加可选回归校验。
7. 在本机用现有 5 条用例跑一轮 `write-only` 首跑 + 一轮 `read-only` 回归，验证缓存文件生成与命中计数；确认无业务仓库越界。
8. 同步改动到 `module-test-public` 源仓库和技能安装目录（用户上一轮要求）。

## 7. 验收标准（reviewer 修正后）

- `l4-regression.ps1 -DryRun` 在无 stable 用例时明确报错退出 2；select 的临时产物写系统临时目录，不写业务仓库。
- write-only 跑完后 `E2E测试/e2e/midscene/cache/<cacheId>.cache.yaml` 存在且非空；**紧接一轮 read-only**（不是两轮 write-only）跑完后该文件 mtime 不变、用例全部通过——验证缓存真的被复用。
- cache id 稳定性：跑完一轮（suite 的 `lastStatus`/`consecutivePasses` 被回写）后，重新计算的 cache id 与跑前一致；手工改一条用例 YAML 后 cache id 才变。
- 缓存命中验证以**报告/结果里可复核的信号**为准：若 Midscene 1.18.2 的 `summary.json` 有缓存命中字段则读它；没有则 `cacheStats.hit` 写"未采集"并说明，**不许拿 debug 日志编数字**。
- stale-replan 验证：用一条含 `aiAct` 的用例，在缓存生成后故意改动页面布局让定位失效（不是改断言文案），read-only 下 console.log 应出现 `will replan and disable the stale cache`，用例最终按断言结果判定，缓存文件未被改写。
- 断言失败的缓存疑点验证：read-only 命中缓存的用例若 `aiAssert` 失败，报告标 `cacheSuspect=true` 并提示 `-RebuildCache` 复核，不自动记产品缺陷。
- 连续 3 次 pass 后 `l4_suite.py explain` 显示 `maturity=stable`；中间插一次 failed 后 `consecutivePasses=0`。
- `confirmed-bug` 用例不会被 passed 自动转正；需要显式 `promote --status fixed`。
- `collect` 跑完后 lifecycle 字段（maturity/consecutivePasses/confirmedBug）不丢失。
- 所有脚本语法检查通过；`check-report.ps1` 对回归产物 PASS（含 cache-stats），对普通 L4 产物行为不变。
