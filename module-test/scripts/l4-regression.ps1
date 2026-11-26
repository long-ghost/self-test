# l4-regression.ps1 — 一条命令完成「选回归用例 → 注入缓存策略 → 调 l4-run → 清理临时文件」。
# 复用 e2e-root.ps1 的产物根解析；select 结果只写系统临时目录 $env:TEMP，finally 清理，不写业务仓库。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Round,
    [string]$Suite = '',
    [string]$Module = '',
    [ValidateSet('stable', 'bug', 'all')][string]$Kind = 'all',
    [ValidateSet('read-only', 'write-only')][string]$CacheStrategy = 'read-only',
    [switch]$RebuildCache,
    [string]$Case = '',
    [string]$Tag = '',
    [string[]]$Secrets = @(),
    [switch]$Authorize,
    [switch]$DryRun,
    [switch]$UpdateSuite,
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'e2e-root.ps1')

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $File @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    [pscustomobject]@{ Code = $code; Output = $out }
}

# ---------- 1. 产物根与 Round 校验（-Round 必须在 E2E_ROOT 下，否则 exit 2） ----------
$repo = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path).TrimEnd('\', '/')
$roundPath = $Round
if (-not [System.IO.Path]::IsPathRooted($roundPath)) { $roundPath = Join-Path $repo $roundPath }
$roundFull = [System.IO.Path]::GetFullPath($roundPath).TrimEnd('\', '/')
$e2eRoot = Get-E2ERoot -RepoRoot $repo -SkillRoot $skillRoot
if (-not (Test-PathUnderRoot -Path $roundFull -Root $e2eRoot)) {
    Write-Output "FAIL -Round 必须位于产物根 E2E_ROOT 下（$e2eRoot）：$roundFull"
    exit 2
}

# ---------- 2. 套件与前置工具 ----------
$suiteRoot = Join-Path $e2eRoot 'e2e\midscene'
if ([string]::IsNullOrWhiteSpace($Suite)) {
    $suitePath = Join-Path $suiteRoot 'suite.json'
} else {
    $suitePath = $Suite
    if (-not [System.IO.Path]::IsPathRooted($suitePath)) { $suitePath = Join-Path $repo $suitePath }
    $suitePath = [System.IO.Path]::GetFullPath($suitePath)
}
if (-not (Test-Path -LiteralPath $suitePath)) {
    Write-Output "FAIL 套件不存在：$suitePath"
    exit 2
}
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Write-Output 'FAIL 未找到 python（l4_suite.py select 需要）'; exit 2 }
$psExe = Get-Command powershell -ErrorAction SilentlyContinue
if (-not $psExe) { Write-Output 'FAIL 未找到 powershell（l4-run.ps1 需要）'; exit 2 }
$suiteScript = Join-Path $PSScriptRoot 'l4_suite.py'
$l4Run = Join-Path $PSScriptRoot 'l4-run.ps1'
if (-not (Test-Path -LiteralPath $suiteScript)) { Write-Output "FAIL 缺少 $suiteScript"; exit 2 }
if (-not (Test-Path -LiteralPath $l4Run)) { Write-Output "FAIL 缺少 $l4Run"; exit 2 }

# kind 映射：all == regression（stable + confirmed-bug），按 brief 逐字处理。
$selectKind = @{ stable = 'stable'; bug = 'bug'; all = 'regression' }[$Kind]

# ---------- 3. 选回归用例 → 调 l4-run；临时文件只在系统临时目录，finally 清理 ----------
$tempDir = $env:TEMP
if ([string]::IsNullOrWhiteSpace($tempDir)) { $tempDir = [System.IO.Path]::GetTempPath() }
$tmpSuite = Join-Path $tempDir ("l4-regression-" + [guid]::NewGuid().ToString('N') + "-suite-selected.json")
$exitCode = 0
try {
    $selectArgs = @($suiteScript, 'select', '--suite', $suitePath, '--kind', $selectKind, '--out', $tmpSuite)
    $select = Invoke-Native $py.Source $selectArgs
    $select.Output | ForEach-Object { Write-Output $_ }
    if ($select.Code -ne 0) {
        Write-Output "FAIL l4_suite.py select 失败（exit $($select.Code)）"
        $exitCode = 2
    } else {
        $selectedData = Get-Content -LiteralPath $tmpSuite -Raw -Encoding UTF8 | ConvertFrom-Json
        $selectedCount = @($selectedData.cases).Count
        if ($selectedCount -eq 0) {
            Write-Output 'FAIL 还没有 stable 用例，先跑 L4 自测并 promote（回归集为空：0 条）'
            $exitCode = 2
        } else {
            $moduleNote = if ([string]::IsNullOrWhiteSpace($Module)) { '' } else { "；模块=$Module" }
            Write-Output "回归选择：$selectedCount 条（Kind=$Kind → $selectKind$moduleNote）"
            # -Suite 传 selected 子集（决定跑哪几条）；-FullSuite 传全量套件（决定 cache id），
            # 两者分离，避免回归成员增减导致 cache id 漂移、旧缓存整体失效。
            $childArgs = @('-NoProfile', '-File', $l4Run,
                '-Round', $Round,
                '-Suite', $tmpSuite,
                '-FullSuite', $suitePath,
                '-CacheStrategy', $CacheStrategy)
            if ($RebuildCache) { $childArgs += '-RebuildCache' }
            if (-not [string]::IsNullOrWhiteSpace($Case)) { $childArgs += @('-Case', $Case) }
            if (-not [string]::IsNullOrWhiteSpace($Tag)) { $childArgs += @('-Tag', $Tag) }
            foreach ($secret in $Secrets) {
                if (-not [string]::IsNullOrWhiteSpace($secret)) { $childArgs += @('-Secrets', $secret) }
            }
            if ($Authorize -and -not $DryRun) { $childArgs += '-Authorize' }
            if ($DryRun) { $childArgs += '-DryRun' }
            if ($UpdateSuite) { $childArgs += '-UpdateSuite' }
            $childArgs += @('-RepoRoot', $repo)

            $run = Invoke-Native $psExe.Source $childArgs
            $run.Output | ForEach-Object { Write-Output $_ }
            $exitCode = $run.Code
        }
    }
} catch {
    Write-Output "FAIL 回归选择/执行异常：$($_.Exception.Message)"
    $exitCode = 2
} finally {
    if (Test-Path -LiteralPath $tmpSuite) {
        Remove-Item -LiteralPath $tmpSuite -Force -ErrorAction SilentlyContinue
    }
}
exit $exitCode
