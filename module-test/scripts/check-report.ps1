param(
    [Parameter(Mandatory = $true)][string]$Report,
    [string]$Skill = ''
)

$ErrorActionPreference = 'Stop'

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
if (Test-Path -LiteralPath (Join-Path $reportDir 'cases.md')) {
    $casesConfirm = Get-Content -LiteralPath (Join-Path $reportDir 'cases.md') -Raw -Encoding UTF8
    if ($casesConfirm -notmatch '需求确认表' -or $casesConfirm -notmatch '用户已确认') {
        $fail += "cases.md 缺『需求确认表 / 用户已确认』（R-28）"
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

# ---------- 输出 ----------
if ($fail.Count -eq 0) {
    Write-Output ("PASS: 结构完整（14 节 + {0} 条规则 + 用例数 + 覆盖数 + 五层 + 复原 + cases.md 冻结哈希一致 + 缺陷记录产物 + {1} 张截图）" -f $ruleIds.Count, $shotRefs.Count)
    exit 0
}

Write-Output ("FAIL: 共 {0} 项" -f $fail.Count)
$fail | ForEach-Object { Write-Output "  - $_" }
exit 1
