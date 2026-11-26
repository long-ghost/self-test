param(
    [Parameter(Mandatory = $true)][string]$Report,
    [string]$Skill = '',
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'e2e-root.ps1')

if (-not (Test-Path -LiteralPath $Report)) {
    Write-Output "FAIL: 报告不存在 - $Report"
    exit 1
}

$reportPath = (Resolve-Path -LiteralPath $Report).Path
$reportDir = Split-Path -Parent $reportPath
$text = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
$lines = $text -split "`r?`n"
$fail = @()

# ---------- 规则编号：优先从 SKILL.md 动态读取 ----------
if ([string]::IsNullOrWhiteSpace($Skill)) {
    $Skill = Join-Path (Split-Path -Parent $PSScriptRoot) 'SKILL.md'
}
$ruleIds = @()
if (Test-Path -LiteralPath $Skill) {
    $skillText = Get-Content -LiteralPath $Skill -Raw -Encoding UTF8
    $ruleIds = [regex]::Matches($skillText, 'R-\d{2}') | ForEach-Object { $_.Value } | Select-Object -Unique | Sort-Object
}
if ($ruleIds.Count -eq 0) {
    $ruleIds = 1..15 | ForEach-Object { 'R-{0:D2}' -f $_ }
}

# ---------- 1. 十四个章节 ----------
$sections = @('一、', '二、', '三、', '四、', '五、', '六、', '七、', '八、', '九、', '十、', '十一、', '十二、', '十三、', '十四、')
foreach ($s in $sections) {
    if ($text -notmatch "###\s*$s") { $fail += "缺章节：### $s" }
}

# ---------- 1b. 缺陷记录产物（R-23） ----------
$bugCount = 0
if ($text -match '缺陷记录[^\r\n]*?(\d+)\s*条') { $bugCount = [int]$Matches[1] }
if ($bugCount -gt 0) {
    foreach ($f in @('bugs.xlsx', 'zentao_bugs.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $reportDir $f))) {
            $fail += "缺陷记录为 $bugCount 条，但缺 $f（R-23）"
        }
    }
    if ($text -notmatch 'BUG-\d{8}-\d{3}') {
        $fail += "缺陷记录非 0 条，但第十四节没有缺陷编号（R-23）"
    }
}

# ---------- 1c. 需求确认（R-28） ----------
if ($text -notmatch '需求确认') {
    $fail += "首部缺『需求确认』（R-28）：必须先让用户口述需求并裁决冲突"
}
elseif ($text -notmatch '用户已确认（\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}）') {
    $fail += "『需求确认』缺用户确认时间（R-28）"
}
if ($text -notmatch '口述来源') {
    $fail += "首部缺『口述来源』（R-28）：须写用户手写 N 条 / 文档补充 M 条 / 裁决 K 条"
}
elseif ($text -match '口述来源[^\r\n]*?用户手写\s*0\s*条') {
    $fail += "『口述来源』显示用户手写 0 条（R-28）：必须先请用户用自己的话手写业务逻辑，不许文档勾选或 AI 代写代替"
}
if (Test-Path -LiteralPath (Join-Path $reportDir 'cases.md')) {
    $casesConfirm = Get-Content -LiteralPath (Join-Path $reportDir 'cases.md') -Raw -Encoding UTF8
    if ($casesConfirm -notmatch '需求确认表' -or $casesConfirm -notmatch '用户已确认') {
        $fail += "cases.md 缺『需求确认表 / 用户已确认』（R-28）"
    }
    if ($casesConfirm -notmatch '用户手写原话') {
        $fail += "cases.md 需求确认表缺『用户手写原话』列（R-28）：须留用户原话，不能用文档勾选代替"
    }
}

# ---------- 1d. 整轮测试耗时 ----------
$durationLine = $lines | Where-Object { $_ -match '^\*\*测试耗时\*\*[：:]' } | Select-Object -First 1
if (-not $durationLine) {
    $fail += '首部缺『测试耗时』：需写起止时间与总分钟'
}
else {
    $durationMatch = [regex]::Match(
        $durationLine,
        '^\*\*测试耗时\*\*[：:]\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s*→\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})（共\s*(\d+)\s*分钟）'
    )
    if (-not $durationMatch.Success) {
        $fail += '『测试耗时』格式错误：应为 YYYY-MM-DD HH:mm → YYYY-MM-DD HH:mm（共 N 分钟）'
    }
    else {
        $format = 'yyyy-MM-dd HH:mm'
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $styles = [System.Globalization.DateTimeStyles]::None
        $startTime = [datetime]::MinValue
        $endTime = [datetime]::MinValue
        $validDates = [datetime]::TryParseExact($durationMatch.Groups[1].Value, $format, $culture, $styles, [ref]$startTime) -and
            [datetime]::TryParseExact($durationMatch.Groups[2].Value, $format, $culture, $styles, [ref]$endTime)
        if (-not $validDates) {
            $fail += '『测试耗时』起止时间不是有效日期时间'
        }
        else {
            $declaredMinutes = [int]$durationMatch.Groups[3].Value
            if ($endTime -lt $startTime) {
                $fail += '『测试耗时』结束时间早于开始时间'
            }
            else {
                $actualMinutes = [math]::Round(($endTime - $startTime).TotalMinutes, [MidpointRounding]::AwayFromZero)
                if ([math]::Abs($actualMinutes - $declaredMinutes) -gt 1) {
                    $fail += "『测试耗时』分钟数不符：声明 $declaredMinutes，实际约 $actualMinutes"
                }
            }
        }
    }
}

# ---------- 2. 规则命中清单 ----------
foreach ($id in $ruleIds) {
    $line = $lines | Where-Object { $_ -match "^\|\s*$id\s*\|" } | Select-Object -First 1
    if (-not $line) { $fail += "规则命中清单缺行：$id"; continue }

    $cols = $line -split '\|'
    $hit = if ($cols.Count -gt 3) { $cols[3].Trim() } else { '' }
    $why = if ($cols.Count -gt 4) { $cols[4].Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($hit)) {
        $fail += "$id 未填『命中/不适用』"
    }
    elseif ($hit -notmatch '命中|不适用') {
        $fail += "$id 取值非法（只允许 命中 / 不适用）：$hit"
    }
    elseif ($hit -match '不适用' -and [string]::IsNullOrWhiteSpace($why)) {
        $fail += "$id 标了不适用但没写依据"
    }
}

# ---------- 2b. R-26/R-27 未覆盖四要素 ----------
$section9Start = ($lines | Select-String -Pattern '^###\s*九、' | Select-Object -First 1).LineNumber
if ($section9Start) {
    $section9Lines = @()
    for ($i = $section9Start - 1; $i -lt $lines.Count; $i++) {
        if ($i -gt ($section9Start - 1) -and $lines[$i] -match '^###\s') { break }
        $section9Lines += $lines[$i]
    }
    $uncovered = @($section9Lines | Where-Object { $_ -match '^\s*-\s+' -and $_ -notmatch '^\s*-\s*<未测项>' })
    foreach ($entry in $uncovered) {
        foreach ($mark in @('[尝试]', '[证据]', '[原因]', '[补测]')) {
            if (-not $entry.Contains($mark)) {
                $fail += "未覆盖条目缺 $mark（R-27）：$($entry.Trim())"
            }
        }
        if ($entry -match '账号可用但|相邻分支|接口层已验证|未逐一|仅确认.{0,12}存在|DOM\s*未定位') {
            if ($entry -notmatch '\[证据\]' -or $entry -match '\[证据\]\s*(?:\[|$)') {
                $fail += "未覆盖条目命中高危借口但未给客观证据（R-26）：$($entry.Trim())"
            }
            if ($entry -match '\[原因\]\s*.*(?:没逐一|未逐一|没定位|未定位)' -or $entry -match '\[原因\]\s*(?:\[|$)') {
                $fail += "未覆盖条目的原因仍是借口而非客观限制（R-26）：$($entry.Trim())"
            }
        }
    }
}

# ---------- 3. 用例数与覆盖数 ----------
if ($text -notmatch '用例\s*[0-9]+\s*条') { $fail += "第二节标题缺『用例 N 条』" }
if ($text -notmatch '覆盖验收点\s*[0-9]+\s*/\s*[0-9]+') { $fail += "第二节标题缺『覆盖验收点 M/M』" }

# ---------- 3b. R-16 期望值前置 ----------
if ($text -notmatch '期望来源') { $fail += "缺『期望来源』列（R-16）：用例表须标期望来源（需求原文 / SQL 反算 / 规范条款 / 已知基准）" }

# ---------- 3c. R-18 用例冻结 + R-17 依据白名单 ----------
$casesPath = Join-Path $reportDir 'cases.md'
if (-not (Test-Path -LiteralPath $casesPath)) {
    $fail += "缺 cases.md（R-18 用例冻结件）：只有 report.md 不算完成"
}
else {
    $actualHash = (Get-FileHash -LiteralPath $casesPath -Algorithm SHA256).Hash.Substring(0, 16).ToLower()

    if ($text -notmatch 'SHA256\s*[:：]?\s*([0-9a-fA-F]{16})') {
        $fail += "报告首部缺『用例冻结 SHA256』（R-18）"
    }
    else {
        $declared = $Matches[1].ToLower()
        if ($declared -ne $actualHash) {
            $fail += "cases.md 与报告声明哈希不一致（冻结后被改过）：声明 $declared / 实际 $actualHash"
        }
    }

    $casesText = Get-Content -LiteralPath $casesPath -Raw -Encoding UTF8
    $casesLines = $casesText -split "`r?`n"

    if ($casesText -notmatch '期望来源') { $fail += "cases.md 缺『期望来源』列（R-16）" }

    $enumOk = '需求原文|SQL\s*反算|规范条款|已知基准|用户口述'
    for ($i = 0; $i -lt $casesLines.Count; $i++) {
        if ($casesLines[$i] -match '^\|' -and $casesLines[$i] -match '期望来源') {
            $hdr = $casesLines[$i] -split '\|'
            $ci = -1
            for ($j = 0; $j -lt $hdr.Count; $j++) { if ($hdr[$j].Trim() -eq '期望来源') { $ci = $j } }
            if ($ci -lt 0) { continue }
            $k = $i + 1
            while ($k -lt $casesLines.Count -and $casesLines[$k] -match '^\|') {
                $cells = $casesLines[$k] -split '\|'
                if ($cells.Count -gt $ci) {
                    $cell = $cells[$ci].Trim()
                    if ($cell -notmatch '^[-:\s]*$' -and $cell -notmatch $enumOk) {
                        $fail += ("cases.md 期望来源不在白名单（第 {0} 行）：{1}（R-17）" -f ($k + 1), $cell)
                    }
                }
                $k++
            }
            break
        }
    }

    $srcHits = @($casesLines | Select-String -Pattern '\.(tsx|jsx|java|vue|xml|ts|js)\b' -AllMatches)
    if ($srcHits.Count -gt 0) {
        $fail += ("cases.md 出现源码文件引用 {0} 处（依据不得落在源码上，R-17），首处：{1}" -f $srcHits.Count, $srcHits[0].Line.Trim())
    }
}

# ---------- 4. 五层关键词 ----------
foreach ($layer in @('功能', '流程', '数据', '逻辑', '规范')) {
    if ($text -notmatch $layer) { $fail += "缺验收层关键词：$layer" }
}

# ---------- 5. 数据复原留痕 ----------
if ($text -notmatch '复原') { $fail += "缺『数据影响与复原』内容" }

# ---------- 5b. 复盘留痕 ----------
if ($text -notmatch '复盘') { $fail += "第十一节缺复盘记录（漏网/空转/阻塞/新知识）" }

# ---------- 5c. R-19 / R-20 首部声明 ----------
if ($text -notmatch '执行会话') { $fail += "首部缺『执行会话』声明（R-19）：新会话 / 同会话" }
if ($text -notmatch '判据构成') { $fail += "首部缺『判据构成』（R-20）：M1/M2/M3 各几条、M3 占比" }

# ---------- 6. 空单元格 ----------
$emptyCells = ($lines | Where-Object { $_ -match '^\|' -and $_ -match '\|\s*\|' }).Count
if ($emptyCells -gt 3) { $fail += "存在 $emptyCells 行含空单元格，逐行确认是否漏填证据" }

# ---------- 7. 截图引用必须真实存在 ----------
$shotRefs = [regex]::Matches($text, 'shots/[^\s\)\|\]"''，。]+\.(?:png|jpg|jpeg|gif|webp)') |
    ForEach-Object { $_.Value } | Select-Object -Unique
foreach ($ref in $shotRefs) {
    $p = Join-Path $reportDir ($ref -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { $fail += "截图不存在：$ref" }
}

# ---------- 8. L4 档位（仅首部出现「L4 套件冻结」时校验） ----------
# 只认行首字段，避免报告模板里的说明性引用被误判为 L4
$isL4 = $text -match '(?m)^\*\*L4 套件冻结\*\*'
$l4CaseCount = 0
if ($isL4) {
    if ($text -notmatch '###\s*十五、') { $fail += '缺章节：### 十五、（L4）' }

    foreach ($rel in @('l4\l4-summary.json', 'l4\midscene\result.md', 'l4\midscene\summary.json', 'l4\midscene\Midscene报告.html')) {
        if (-not (Test-Path -LiteralPath (Join-Path $reportDir $rel))) {
            $fail += ('L4 缺产物：' + ($rel -replace '\\', '/'))
        }
    }

    $l4Summary = $null
    $summaryPath = Join-Path $reportDir 'l4\l4-summary.json'
    if (Test-Path -LiteralPath $summaryPath) {
        try { $l4Summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $fail += 'l4/l4-summary.json 无法解析' }
    }

    # 优先用本轮目录内的 suite 快照（产物根可在仓库外），再回退到仓库源
    $suitePath = ''
    $roundSnapshot = Join-Path $reportDir (Join-Path 'e2e\midscene' 'suite.json')
    if (Test-Path -LiteralPath $roundSnapshot) {
        $suitePath = $roundSnapshot
    } else {
        # 套件源已整合进产物根 E2E_ROOT/e2e/midscene/suite.json
        $repoCandidate = $RepoRoot
        if ([string]::IsNullOrWhiteSpace($repoCandidate)) { $repoCandidate = $reportDir }
        $rootForSuite = Get-E2ERoot -RepoRoot $repoCandidate -SkillRoot $skillRoot
        $probe = Join-Path $rootForSuite (Join-Path 'e2e\midscene' 'suite.json')
        if (Test-Path -LiteralPath $probe) { $suitePath = $probe }
    }

    $suiteIds = @()
    if (-not $suitePath) {
        $fail += 'L4 找不到套件：本轮目录快照与 E2E_ROOT/e2e/midscene/suite.json 均无（可用 -RepoRoot 指定仓库根）'
    } else {
        try {
            $suiteData = Get-Content -LiteralPath $suitePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $suiteIds = @($suiteData.cases | ForEach-Object { [string]$_.caseId })
        } catch {
            $fail += 'L4 suite.json 无法解析'
        }
        $suiteHash = (Get-FileHash -LiteralPath $suitePath -Algorithm SHA256).Hash.Substring(0, 16).ToLower()
        if ($text -notmatch '\*\*L4 套件冻结\*\*[^\r\n]*?SHA256\s*[:：]?\s*([0-9a-fA-F]{16})') {
            $fail += '首部缺「L4 套件冻结 SHA256」'
        } else {
            $declaredSuiteHash = $Matches[1].ToLower()
            if ($declaredSuiteHash -ne $suiteHash) {
                $fail += "L4 套件哈希不一致：声明 $declaredSuiteHash / 实际 $suiteHash"
            }
        }
    }

    $l4ExecLine = $lines | Where-Object { $_ -match '^\*\*L4 执行\*\*' } | Select-Object -First 1
    if (-not $l4ExecLine) {
        $fail += '首部缺「L4 执行」'
    } else {
        $execMatch = [regex]::Match(
            $l4ExecLine,
            '^\*\*L4 执行\*\*[：:]\s*用例\s*(\d+)\s*/\s*通过\s*(\d+)\s*/\s*失败\s*(\d+)\s*/\s*跳过\s*(\d+)\s*（exit\s*([0-9]+)'
        )
        if (-not $execMatch.Success) {
            $fail += '「L4 执行」格式错误：应为 用例 N / 通过 x / 失败 y / 跳过 z（exit 0|1；模型 …，密钥已隐藏）'
        } else {
            $declared = @(
                [int]$execMatch.Groups[1].Value,
                [int]$execMatch.Groups[2].Value,
                [int]$execMatch.Groups[3].Value,
                [int]$execMatch.Groups[4].Value
            )
            $declaredExit = [int]$execMatch.Groups[5].Value
            if ($l4Summary) {
                $actual = @(
                    [int]$l4Summary.counts.total,
                    [int]$l4Summary.counts.passed,
                    [int]$l4Summary.counts.failed,
                    [int]$l4Summary.counts.skipped
                )
                $labels = @('用例', '通过', '失败', '跳过')
                for ($i = 0; $i -lt 4; $i++) {
                    if ($declared[$i] -ne $actual[$i]) {
                        $fail += ("L4 执行与 l4-summary.json 不一致：$($labels[$i]) 声明 $($declared[$i]) / 实际 $($actual[$i])")
                    }
                }
                if ([int]$l4Summary.exitCode -eq 0 -and $actual[2] -gt 0) {
                    $fail += 'L4 exitCode 为 0 但存在失败用例'
                }
                if (-not ($declaredExit -eq [int]$l4Summary.exitCode)) {
                    $fail += "L4 执行 exitCode 与 l4-summary.json 不一致：声明 $declaredExit / 实际 $($l4Summary.exitCode)"
                }
            }
        }
    }

    $s15Start = ($lines | Select-String -Pattern '^###\s*十五、' | Select-Object -First 1).LineNumber
    if ($s15Start) {
        $s15Rows = @()
        for ($i = $s15Start; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^###\s') { break }
            if ($lines[$i] -match '^\|') { $s15Rows += $lines[$i] }
        }
        foreach ($row in $s15Rows) {
            $cells = $row -split '\|'
            if ($cells.Count -lt 8) { continue }
            $caseId = $cells[1].Trim().Trim('`')
            $assertion = $cells[2].Trim()
            $criterion = $cells[3].Trim()
            $cross = $cells[4].Trim()
            $evidence = $cells[6].Trim()
            if ([string]::IsNullOrWhiteSpace($caseId) -or $caseId -match '^-+$') { continue }
            if ($caseId -eq '用例编号') { continue }
            $l4CaseCount++
            if ($suiteIds.Count -gt 0 -and ($suiteIds -notcontains $caseId)) {
                $fail += "十五节用例编号不在 suite.json 中：$caseId"
            }
            if ($criterion -notmatch '^(M1|M2|M3)$') {
                $fail += "十五节判据必须是 M1/M2/M3：$caseId → $criterion"
            }
            if ($criterion -eq 'M3' -and $assertion -match '数值|金额|条数|权限|占比') {
                if ([string]::IsNullOrWhiteSpace($cross) -or $cross -match '^[—\-/]+$') {
                    $fail += "十五节 M3 断言含数值/金额/条数/权限/占比，但缺 M1/M2 交叉核验：$caseId"
                }
            }
            foreach ($match in [regex]::Matches($evidence, '(?:l4|shots)/[^\s`\)\|，。]+')) {
                $ref = $match.Value
                $path = Join-Path $reportDir ($ref -replace '/', '\')
                if (-not (Test-Path -LiteralPath $path)) {
                    $fail += "十五节引用的证据不存在：$ref"
                }
            }
        }
        if ($l4CaseCount -eq 0) { $fail += '十五节没有可校验的用例行' }
    }
}

# ---------- 8b. L4 回归缓存统计：仅当 l4/cache-stats.json 存在时校验，普通 L4 不受影响 ----------
$cacheStatsPath = Join-Path $reportDir (Join-Path 'l4' 'cache-stats.json')
if (Test-Path -LiteralPath $cacheStatsPath) {
    $cs = $null
    try {
        $cs = Get-Content -LiteralPath $cacheStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $fail += 'l4/cache-stats.json 无法解析'
    }
    if ($null -ne $cs) {
        foreach ($fld in @('cacheId', 'strategy', 'hit')) {
            if ($null -eq $cs.PSObject.Properties[$fld]) {
                $fail += "l4/cache-stats.json 缺字段：$fld"
            }
        }
        if ($null -ne $cs.PSObject.Properties['strategy'] -and
            [string]$cs.strategy -notin @('read-only', 'write-only')) {
            $fail += "l4/cache-stats.json strategy 非法（只允许 read-only / write-only）：$($cs.strategy)"
        }
        if ($null -ne $cs.PSObject.Properties['hit']) {
            $hitVal = $cs.hit
            $hitOk = ([string]$hitVal -eq '未采集') -or ([string]$hitVal -match '^\d+$')
            if (-not $hitOk) {
                $fail += "l4/cache-stats.json hit 非法（只允许『未采集』或整数）：$hitVal"
            }
        }
    }
}

# ---------- 输出 ----------
if ($fail.Count -eq 0) {
    $extra = ''
    if ($isL4) { $extra = " + L4 $l4CaseCount 条" }
    Write-Output ("PASS: 结构完整（14 节 + {0} 条规则 + 用例数 + 覆盖数 + 五层 + 复原 + cases.md 冻结哈希一致 + 缺陷记录产物 + {1} 张截图{2}）" -f $ruleIds.Count, $shotRefs.Count, $extra)
    exit 0
}

Write-Output ("FAIL: 共 {0} 项" -f $fail.Count)
$fail | ForEach-Object { Write-Output "  - $_" }
exit 1
