[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Round,
    [string]$RepoRoot = (Get-Location).Path,
    [string]$Suite = '',
    [string]$FullSuite = '',
    [string]$Case = '',
    [string]$Tag = '',
    [string[]]$Secrets = @(),
    [switch]$Authorize,
    [switch]$DryRun,
    [switch]$UpdateSuite,
    [switch]$RerunFlaky,
    [string]$CacheStrategy = '',
    [switch]$RebuildCache
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'e2e-root.ps1')
$runnerDir = $env:L4_RUNNER_DIR
if ([string]::IsNullOrWhiteSpace($runnerDir)) {
    $runnerDir = Join-Path $env:USERPROFILE '.codebuddy\skill-data\module-test\l4-runner'
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments, [string]$WorkDir = '')
    $prev = Get-Location
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        $out = @(& $File @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    } finally {
        Set-Location $prev
        $ErrorActionPreference = $prevEap
    }
    [pscustomobject]@{ Code = $code; Output = $out }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Redact-Text {
    param([string]$Text, [System.Collections.IDictionary]$Map)
    foreach ($key in $Map.Keys) {
        $value = [string]$Map[$key]
        if ($value.Length -ge 4) {
            $Text = $Text.Replace($value, '***')
        }
    }
    return $Text
}

# ---------- 1. 前置检查 ----------
$repo = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path).TrimEnd('\', '/')
$roundPath = $Round
if (-not [System.IO.Path]::IsPathRooted($roundPath)) {
    $roundPath = Join-Path $repo $roundPath
}
$roundFull = [System.IO.Path]::GetFullPath($roundPath).TrimEnd('\', '/')
$e2eRoot = Get-E2ERoot -RepoRoot $repo -SkillRoot $skillRoot
if (-not (Test-PathUnderRoot -Path $roundFull -Root $e2eRoot)) {
    Write-Output "FAIL -Round 必须位于产物根 E2E_ROOT 下（$e2eRoot）：$roundFull"
    exit 2
}

$suiteRoot = Join-Path $e2eRoot 'e2e\midscene'
if ([string]::IsNullOrWhiteSpace($Suite)) {
    $suitePath = Join-Path $suiteRoot 'suite.json'
} else {
    $suitePath = $Suite
    if (-not [System.IO.Path]::IsPathRooted($suitePath)) {
        $suitePath = Join-Path $repo $suitePath
    }
}
if (-not (Test-Path -LiteralPath $suitePath)) {
    Write-Output "FAIL 套件不存在：$suitePath"
    exit 2
}
# cache id 必须基于全量套件，不能基于回归传入的 selected 子集：
# 回归成员增减（升 stable / 哨兵 fixed）会改变 selected 子集，据此算 id 会让旧缓存整体失效。
# 默认沿用 -Suite（普通 L4 场景 -Suite 即全量套件）；回归由 l4-regression.ps1 显式传 -FullSuite。
$fullSuitePath = $suitePath
if (-not [string]::IsNullOrWhiteSpace($FullSuite)) {
    $fullSuitePath = $FullSuite
    if (-not [System.IO.Path]::IsPathRooted($fullSuitePath)) {
        $fullSuitePath = Join-Path $repo $fullSuitePath
    }
    $fullSuitePath = [System.IO.Path]::GetFullPath($fullSuitePath)
}
$runnerModules = Join-Path $runnerDir 'node_modules\@midscene\test'
if (-not (Test-Path -LiteralPath $runnerModules)) {
    Write-Output "FAIL 全局 runner 未就绪：$runnerDir（先运行 l4-init.ps1 -CheckOnly）"
    exit 2
}
$pnpmCommand = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpmCommand) {
    Write-Output 'FAIL 未找到 pnpm（l4-init.ps1 -CheckOnly 查看前置）'
    exit 2
}
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Output 'FAIL 未找到 python（l4_summary.py 需要）'
    exit 2
}
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    Write-Output "FAIL 不是 Git 仓库：$repo"
    exit 2
}

# ---------- 1b. L4 缓存策略 ----------
# -RebuildCache 等价 write-only；不传任何策略时本段整体跳过，行为与原先完全一致。
if ($RebuildCache) { $CacheStrategy = 'write-only' }
if (-not [string]::IsNullOrWhiteSpace($CacheStrategy)) {
    if ($CacheStrategy -notin @('read-only', 'write-only')) {
        Write-Output "FAIL 非法 -CacheStrategy：$CacheStrategy（仅允许 read-only / write-only）"
        exit 2
    }
    if (-not (Test-Path -LiteralPath $fullSuitePath)) {
        Write-Output "FAIL 全量套件不存在：$fullSuitePath"
        exit 2
    }
    $suiteScript = Join-Path $PSScriptRoot 'l4_suite.py'
    $cacheArgs = @($suiteScript, 'cache-id', '--repo-root', $repo, '--suite', $fullSuitePath)
    $cacheRun = Invoke-Native $py.Source $cacheArgs $repo
    $cacheId = ''
    if ($cacheRun.Code -eq 0) {
        $cacheLines = @($cacheRun.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($cacheLines.Count -gt 0) { $cacheId = ([string]$cacheLines[0]).Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($cacheId)) {
        Write-Output 'FAIL 无法计算 cache id（l4_suite.py cache-id 失败）'
        exit 2
    }
    $cacheDir = Join-Path (Join-Path $e2eRoot 'e2e\midscene') 'cache'
    [System.Environment]::SetEnvironmentVariable('L4_CACHE_ID', $cacheId, 'Process')
    [System.Environment]::SetEnvironmentVariable('L4_CACHE_STRATEGY', $CacheStrategy, 'Process')
    [System.Environment]::SetEnvironmentVariable('L4_CACHE_DIR', $cacheDir, 'Process')
}

# 记录执行前的 git 状态，收尾只对本轮新增改动做越界校验，避免误伤历史未提交改动
$gitBaseline = @((Invoke-Native 'git' @('-C', $repo, 'status', '--porcelain', '-uall')).Output | Where-Object { $_ })

$suiteData = Get-Content -LiteralPath $suitePath -Raw -Encoding UTF8 | ConvertFrom-Json
$project = 'web'
if ($suiteData.project) { $project = [string]$suiteData.project }
$suiteCases = @($suiteData.cases)

$selected = @()
foreach ($item in $suiteCases) {
    if ($Case) {
        $hitCase = ($item.caseId -eq $Case) -or (($item.file -replace '\\', '/') -eq ($Case -replace '\\', '/'))
        if (-not $hitCase) { continue }
    }
    if ($Tag) {
        if (-not (@($item.tags) -contains $Tag)) { continue }
    }
    $selected += $item
}
if ($selected.Count -eq 0) {
    Write-Output 'FAIL 套件选择结果为空（检查 -Case / -Tag）'
    exit 4
}

$staged = @()
$manifestFiles = @()
foreach ($item in $selected) {
    $caseId = [string]$item.caseId
    if ($caseId -notmatch '^L4-[A-Z0-9]+-\d{3}$') {
        Write-Output "FAIL 用例编号非法：$caseId"
        exit 4
    }
    $rel = ([string]$item.file) -replace '\\', '/'
    $source = Join-Path $suiteRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Output "FAIL 用例文件不存在：$rel"
        exit 4
    }
    $yamlText = Get-Content -LiteralPath $source -Raw -Encoding UTF8
    $names = [regex]::Matches($yamlText, '(?m)^[ \t]{2,6}-\s+name\s*:\s*(.+)$')
    if ($names.Count -ne 1) {
        Write-Output "FAIL $rel 含 $($names.Count) 条用例；契约要求一个文件只放一条"
        exit 4
    }
    $yamlName = $names[0].Groups[1].Value.Trim().Trim('"').Trim("'")
    if ($yamlName -ne [string]$item.name) {
        Write-Output "FAIL $rel 的用例名「$yamlName」与 suite 的「$($item.name)」不一致"
        exit 4
    }
    $hash = Get-Sha256 $source
    $staged += [pscustomobject]@{ Item = $item; Rel = $rel; Source = $source; Sha256 = $hash }
    $manifestFiles += [ordered]@{
        caseId = $caseId
        source = 'e2e/midscene/' + $rel
        staged = $rel
        sha256 = $hash
    }
}

$fixturesRoot = Join-Path $suiteRoot 'fixtures'
$fixtureFiles = @()
if (Test-Path -LiteralPath $fixturesRoot) {
    $fixtureFiles = @(Get-ChildItem -LiteralPath $fixturesRoot -Recurse -File)
    foreach ($file in $fixtureFiles) {
        $rel = $file.FullName.Substring($fixturesRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $manifestFiles += [ordered]@{
            caseId = ''
            source = 'e2e/midscene/fixtures/' + $rel
            staged = 'fixtures/' + $rel
            sha256 = Get-Sha256 $file.FullName
        }
    }
}

$suiteHash = Get-Sha256 $suitePath
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path (Join-Path $runnerDir 'runs') $runId
if (Test-Path -LiteralPath $runDir) {
    $runId = $runId + '-2'
    $runDir = Join-Path (Join-Path $runnerDir 'runs') $runId
}

$cliArgs = @(
    'exec', 'midscene-test',
    '--config', 'midscene.config.ts',
    '--project', $project,
    '--reporter', 'verbose',
    '--result-dir', './results'
)

if ($DryRun) {
    Write-Output "套件：$suitePath"
    Write-Output ("套件 SHA256：" + $suiteHash.Substring(0, 16))
    Write-Output "选择：$($selected.Count) 条（Case=$Case / Tag=$Tag）"
    foreach ($entry in $staged) {
        Write-Output ("  暂存 " + $entry.Rel + " → " + (Join-Path $runDir $entry.Rel))
    }
    if ($fixtureFiles.Count -gt 0) {
        Write-Output ("  暂存 fixtures {0} 个文件" -f $fixtureFiles.Count)
    }
    Write-Output "运行目录：$runDir"
    Write-Output ("命令：pnpm " + ($cliArgs -join ' '))
    if (-not [string]::IsNullOrWhiteSpace($CacheStrategy)) {
        Write-Output "Cache ID：$cacheId"
        Write-Output "Cache 策略：$CacheStrategy"
        Write-Output "Cache 目录：$cacheDir"
        Write-Output "Cache 套件（全量）：$fullSuitePath"
    }
    Write-Output 'DryRun：未写入任何文件'
    exit 0
}

if (-not $Authorize) {
    Write-Output 'FAIL 未授权：需要 -Authorize 才会暂存用例、调用模型并写产物目录'
    exit 3
}

# ---------- 2. 重跑归档 ----------
$l4Dir = Join-Path $roundFull 'l4'
if ($RerunFlaky -and (Test-Path -LiteralPath $l4Dir)) {
    $archive = Join-Path $roundFull ('l4-rerun-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $l4Dir -Destination $archive -Recurse -Force
    Write-Output "已归档上一轮 L4 证据：$archive"
}

# ---------- 3. 暂存 ----------
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runDir 'results') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runDir 'artifacts') -Force | Out-Null
foreach ($entry in $staged) {
    $dest = Join-Path $runDir ($entry.Rel -replace '/', '\')
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $entry.Source -Destination $dest -Force
}
foreach ($file in $fixtureFiles) {
    $rel = $file.FullName.Substring($fixturesRoot.Length).TrimStart('\', '/')
    $dest = Join-Path (Join-Path $runDir 'fixtures') $rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
}

$configTemplate = Join-Path (Join-Path $runnerDir 'templates') 'midscene.config.ts'
if (-not (Test-Path -LiteralPath $configTemplate)) {
    Write-Output "FAIL runner 缺少配置模板：$configTemplate（运行 l4-init.ps1 -Install）"
    exit 2
}
Copy-Item -LiteralPath $configTemplate -Destination (Join-Path $runDir 'midscene.config.ts') -Force

$manifest = [ordered]@{
    runId = $runId
    createdAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    repoRoot = $repo
    suite = $suitePath
    suiteSha256 = $suiteHash
    selection = [ordered]@{ case = $Case; tag = $Tag; selected = $selected.Count }
    files = $manifestFiles
}
$manifestPath = Join-Path $runDir 'staged-manifest.json'
Write-Utf8 $manifestPath ($manifest | ConvertTo-Json -Depth 8)

$suiteSelected = [ordered]@{
    schemaVersion = 1
    project = $project
    module = [string]$suiteData.module
    cases = @($selected)
}
$suiteSelectedPath = Join-Path $runDir 'suite-selected.json'
Write-Utf8 $suiteSelectedPath ($suiteSelected | ConvertTo-Json -Depth 8)

# ---------- 4. 注入 Secret 并执行 ----------
$secretMap = [ordered]@{}
$dotEnvPath = Join-Path $runnerDir '.env'
if (Test-Path -LiteralPath $dotEnvPath) {
    foreach ($line in (Get-Content -LiteralPath $dotEnvPath -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $secretMap[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }
}
foreach ($secret in $Secrets) {
    if ([string]::IsNullOrWhiteSpace($secret)) { continue }
    if (Test-Path -LiteralPath $secret) {
        $content = Get-Content -LiteralPath $secret -Raw -Encoding UTF8
        if ($content.TrimStart().StartsWith('{')) {
            $obj = $content | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $secretMap[$prop.Name] = [string]$prop.Value }
        } else {
            foreach ($line in ($content -split "`r?`n")) {
                if ($line -match '^\s*#') { continue }
                if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                    $secretMap[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
                }
            }
        }
    } elseif ($secret -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        $secretMap[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    } else {
        Write-Output "WARN 无法解析 -Secrets 项（应为 KEY=VALUE 或文件路径）：$secret"
    }
}
foreach ($key in $secretMap.Keys) {
    [System.Environment]::SetEnvironmentVariable($key, [string]$secretMap[$key], 'Process')
}
$env:MIDSCENE_RUN_DIR = './artifacts'

# 模型 Key 是硬前置；只查存在性，连通性用 l4-init.ps1 -ModelVerify
$modelKey = [System.Environment]::GetEnvironmentVariable('MIDSCENE_MODEL_API_KEY', 'Process')
if ([string]::IsNullOrWhiteSpace($modelKey)) {
    Write-Output 'FAIL 未配置 MIDSCENE_MODEL_API_KEY（-Secrets / runner .env / 进程环境）'
    exit 2
}

# 运行前校验 Cookie / storageState 引用，缺失即停，避免跑到一半才报错
foreach ($entry in $staged) {
    $yamlText = Get-Content -LiteralPath $entry.Source -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($yamlText, 'cookiesEnv\s*:\s*([A-Za-z_][A-Za-z0-9_]*)')) {
        $cookieVar = $m.Groups[1].Value
        $cookieValue = [System.Environment]::GetEnvironmentVariable($cookieVar, 'Process')
        if ([string]::IsNullOrWhiteSpace($cookieValue)) {
            Write-Output "FAIL 用例引用了 Cookie 变量 $cookieVar，但 -Secrets / runner .env / 进程环境都没有提供"
            exit 2
        }
    }
    foreach ($m in [regex]::Matches($yamlText, 'storageStatePath\s*:\s*([^\s"'']+)')) {
        $stateRel = $m.Groups[1].Value.Trim()
        $statePath = $stateRel
        if (-not [System.IO.Path]::IsPathRooted($statePath)) {
            $statePath = Join-Path $runDir ($stateRel -replace '/', '\')
        }
        if (-not (Test-Path -LiteralPath $statePath)) {
            Write-Output "FAIL 用例引用的 storageStatePath 不存在：$stateRel"
            exit 2
        }
    }
}

Write-Output "运行：pnpm $($cliArgs -join ' ')"
Write-Output "目录：$runDir"
$runResult = Invoke-Native $pnpmCommand.Source $cliArgs $runDir
$consoleLog = Join-Path $runDir 'console.log'
$consoleText = Redact-Text (($runResult.Output -join "`n") + "`n") $secretMap
Write-Utf8 $consoleLog $consoleText
$runResult.Output | ForEach-Object { Write-Output (Redact-Text $_ $secretMap) }
$cliCode = $runResult.Code

# ---------- 5. 复制结果到本轮 ----------
$roundL4 = Join-Path $roundFull 'l4'
$roundMidscene = Join-Path $roundL4 'midscene'
New-Item -ItemType Directory -Path $roundMidscene -Force | Out-Null
$resultsRoot = Join-Path $runDir 'results'
$resultMd = Get-ChildItem -LiteralPath $resultsRoot -Recurse -File -Filter 'result.md' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$summaryJson = Get-ChildItem -LiteralPath $resultsRoot -Recurse -File -Filter 'summary.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($resultMd) { Copy-Item -LiteralPath $resultMd.FullName -Destination (Join-Path $roundMidscene 'result.md') -Force }
if ($summaryJson) { Copy-Item -LiteralPath $summaryJson.FullName -Destination (Join-Path $roundMidscene 'summary.json') -Force }

# 套件快照：用例 YAML 副本 + suite.json 一并进本轮目录，让每次测试自包含（套件源 E2E_ROOT/e2e/midscene 保留不变）
$roundCases = Join-Path $roundFull (Join-Path 'e2e\midscene' 'cases')
New-Item -ItemType Directory -Path $roundCases -Force | Out-Null
Copy-Item -LiteralPath $suitePath -Destination (Join-Path $roundFull (Join-Path 'e2e\midscene' 'suite.json')) -Force
foreach ($entry in $staged) {
    $destCase = Join-Path $roundCases ($entry.Rel -replace '/', '\')
    $destCaseDir = Split-Path -Parent $destCase
    if (-not (Test-Path -LiteralPath $destCaseDir)) { New-Item -ItemType Directory -Path $destCaseDir -Force | Out-Null }
    Copy-Item -LiteralPath $entry.Source -Destination $destCase -Force
}

# Midscene 官方报告：文件名中文化 + 替换硬编码 <title>
$reportHtml = Get-ChildItem -LiteralPath (Join-Path $runDir 'artifacts') -Recurse -File -Filter '*.html' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$midsceneReportPath = Join-Path $roundMidscene 'Midscene报告.html'
if ($reportHtml) {
    $htmlText = [System.IO.File]::ReadAllText($reportHtml.FullName)
    $htmlTitle = 'Midscene 端到端测试报告 · ' + [string]$suiteData.module
    $htmlText = [regex]::Replace($htmlText, '(?is)<title>.*?</title>', '<title>' + $htmlTitle + '</title>', 1)
    Write-Utf8 $midsceneReportPath $htmlText
}

# ---------- 6. 截图归档 ----------
$shotDir = Join-Path (Join-Path $roundFull 'shots') 'l4'
$shotsMap = [ordered]@{}
$allImages = @()
foreach ($base in @($resultsRoot, (Join-Path $runDir 'artifacts'))) {
    if (Test-Path -LiteralPath $base) {
        $allImages += @(Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|webp|gif)$' })
    }
}
$allImages = @($allImages | Sort-Object FullName -Unique)
if ($allImages.Count -gt 0) {
    New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
    foreach ($entry in $staged) {
        $caseId = [string]$entry.Item.caseId
        $matched = @($allImages | Where-Object { $_.FullName.ToLower().Contains($caseId.ToLower()) })
        if ($matched.Count -eq 0 -and $staged.Count -eq 1) { $matched = $allImages }
        $list = @()
        $index = 0
        foreach ($image in $matched) {
            $index++
            $ext = $image.Extension.ToLower()
            $name = "$caseId-step$index$ext"
            Copy-Item -LiteralPath $image.FullName -Destination (Join-Path $shotDir $name) -Force
            $list += "shots/l4/$name"
        }
        $shotsMap[$caseId] = $list
    }
}
$shotsMapPath = Join-Path $runDir 'shots-map.json'
Write-Utf8 $shotsMapPath ($shotsMap | ConvertTo-Json -Depth 5)

# ---------- 7. 归一化 ----------
$summaryScript = Join-Path $PSScriptRoot 'l4_summary.py'
$outSummary = Join-Path $roundL4 'l4-summary.json'
$secretNames = @($secretMap.Keys) -join ','

# cache-stats：仅在指定策略时生成；不传策略时零变化，不产出此文件。
if (-not [string]::IsNullOrWhiteSpace($CacheStrategy)) {
    $replanCount = [regex]::Matches(
        $consoleText,
        'will replan and disable the stale cache',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    ).Count
    $cacheFile = Join-Path $cacheDir ($cacheId + '.cache.yaml')
    $cacheNote = 'hit 未采集：cache found 为 debug 日志，不进入 console.log，且无结构化命中字段；cacheReplanCases 为全局 replan 计数，无法精确归因到单个 case，故各 case 的 cacheReplan 记 false。'
    $cacheStats = [ordered]@{
        cacheId = $cacheId
        strategy = $CacheStrategy
        cacheFile = $cacheFile
        cacheReplanCases = $replanCount
        hit = '未采集'
        note = $cacheNote
    }
    $cacheStatsPath = Join-Path $roundL4 'cache-stats.json'
    Write-Utf8 $cacheStatsPath ($cacheStats | ConvertTo-Json -Depth 6)
    Write-Output ("cache-stats：" + $cacheStatsPath)
}

$summaryArgs = @(
    $summaryScript,
    '--results', $resultsRoot,
    '--suite', $suiteSelectedPath,
    '--staged', $manifestPath,
    '--console', $consoleLog,
    '--out', $outSummary,
    '--shots-map', $shotsMapPath,
    '--exit-code', [string]$cliCode,
    '--secrets-env', $secretNames
)
if (-not [string]::IsNullOrWhiteSpace($CacheStrategy)) {
    $summaryArgs += @('--cache-strategy', $CacheStrategy, '--cache-replan-count', [string]$replanCount)
}
$summaryRun = Invoke-Native $py.Source $summaryArgs $repo
$summaryRun.Output | ForEach-Object { Write-Output (Redact-Text $_ $secretMap) }
if ($summaryRun.Code -ne 0) {
    Write-Output 'FAIL l4_summary.py 执行失败'
    exit 1
}

$summaryData = Get-Content -LiteralPath $outSummary -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $summaryData.cases -or @($summaryData.cases).Count -eq 0) {
    Write-Output 'FAIL 未能从结果中解析出用例（summary.json 结构可能变化）；请人工核对 result.md，不得直接判通过'
    if ($cliCode -ne 0) { exit 1 }
    exit 4
}
$unmapped = @($summaryData.cases | Where-Object { $_.unmapped })
if ($unmapped.Count -gt 0) {
    foreach ($item in $unmapped) {
        Write-Output ("UNMAPPED " + $item.caseId + " " + $item.name + "：结果中缺失")
    }
}

# ---------- 8. 回写套件 ----------
if ($UpdateSuite) {
    $suiteScript = Join-Path $PSScriptRoot 'l4_suite.py'
    foreach ($item in $summaryData.cases) {
        if (-not $item.caseId) { continue }
        if ($item.status -notin @('passed', 'failed', 'skipped')) { continue }
        $promoteArgs = @($suiteScript, 'promote', '--suite', $suitePath, '--case-id', [string]$item.caseId, '--status', [string]$item.status, '--authorize')
        $promote = Invoke-Native $py.Source $promoteArgs $repo
        if ($promote.Code -ne 0) { Write-Output ("WARN 回写套件失败：" + $item.caseId) }
    }
}

# ---------- 9. 越界检查 ----------
# 套件源与产物都在 E2E_ROOT 下：产物根在仓库内时，其相对路径即白名单（覆盖套件源与本轮）；
# 在仓库外时 git status 本就看不到，无需加入。
$allowed = @()
if (Test-PathUnderRoot -Path $e2eRoot -Root $repo) {
    $e2eRel = $e2eRoot.Substring($repo.Length).TrimStart('\', '/') -replace '\\', '/'
    $allowed += $e2eRel + '/'
}
$gitStatus = Invoke-Native 'git' @('-C', $repo, 'status', '--porcelain', '-uall')
$newChanges = @($gitStatus.Output | Where-Object { $_ -and ($gitBaseline -notcontains $_) })
$violations = @()
foreach ($line in $newChanges) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $path = ''
    if ($line.Length -gt 3) { $path = $line.Substring(3).Trim() }
    if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1].Trim() }
    $path = $path.Trim('"') -replace '\\', '/'
    $ok = $false
    foreach ($prefix in $allowed) {
        if ($path -eq $prefix.TrimEnd('/')) { $ok = $true }
        if ($path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true }
    }
    if (-not $ok) { $violations += $path }
}
if ($violations.Count -gt 0) {
    Write-Output 'FAIL git 越界写入（本轮作废）：'
    $violations | ForEach-Object { Write-Output "  - $_" }
    Write-Output ('  允许：' + ($allowed -join '、'))
    exit 4
}

$counts = $summaryData.counts
Write-Output ("L4：用例 {0} / 通过 {1} / 失败 {2} / 跳过 {3}（exit {4}）" -f $counts.total, $counts.passed, $counts.failed, $counts.skipped, $cliCode)
Write-Output ("套件冻结：SHA256 " + $suiteHash.Substring(0, 16))
Write-Output ("产物：" + $outSummary)

if ($unmapped.Count -gt 0) { exit 4 }
if ($cliCode -ne 0 -or [int]$counts.failed -gt 0) { exit 1 }
exit 0
