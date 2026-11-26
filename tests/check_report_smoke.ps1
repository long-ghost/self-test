[CmdletBinding()]
param()

# 验证 check-report.ps1 的 L4 分支：L4 PASS / 缺十五节 FAIL / L2 不误报。
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $PSScriptRoot 'fixtures\l4'
$checkScript = Join-Path $root 'module-test\scripts\check-report.ps1'
$hostExe = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('mt-check-report-' + [guid]::NewGuid().ToString('N'))
$failures = @()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Output ('PASS ' + $Message)
    } else {
        Write-Output ('FAIL ' + $Message)
        $script:failures += $Message
    }
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Check {
    param([string]$ReportPath)
    $out = @(& $hostExe -NoProfile -File $checkScript -Report $ReportPath -RepoRoot $repoRoot 2>&1 | ForEach-Object { $_.ToString() })
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
}

try {
    $repoRoot = Join-Path $work 'repo'
    $round = Join-Path $repoRoot '.codebuddy\selftest\20261124-l4'
    $suitePath = Join-Path $repoRoot 'e2e\midscene\suite.json'
    New-Item -ItemType Directory -Path $round -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $suitePath) -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $fixture 'suite.json') -Destination $suitePath -Force
    Copy-Item -LiteralPath (Join-Path $fixture 'cases.md') -Destination (Join-Path $round 'cases.md') -Force
    Copy-Item -LiteralPath (Join-Path $fixture 'report.md') -Destination (Join-Path $round 'report.md') -Force
    Copy-Item -LiteralPath (Join-Path $fixture 'l4') -Destination (Join-Path $round 'l4') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $fixture 'l4-summary.json') -Destination (Join-Path $round 'l4\l4-summary.json') -Force

    $l4Dir = Join-Path $round 'l4\midscene'
    Write-Utf8 (Join-Path $l4Dir 'report.html') '<!DOCTYPE html><html><body>fixture</body></html>'

    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
    $shotDir = Join-Path $round 'shots'
    New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $shotDir 'demo.png'), $png)

    $casesHash = (Get-FileHash -LiteralPath (Join-Path $round 'cases.md') -Algorithm SHA256).Hash.Substring(0, 16).ToLower()
    $suiteHash = (Get-FileHash -LiteralPath $suitePath -Algorithm SHA256).Hash.Substring(0, 16).ToLower()

    $template = Get-Content -LiteralPath (Join-Path $round 'report.md') -Raw -Encoding UTF8
    $l4Report = $template.Replace('__CASES_SHA__', $casesHash).Replace('__SUITE_SHA__', $suiteHash).Replace('__START__', '2026-11-24 12:00').Replace('__END__', '2026-11-24 12:07').Replace('__DURATION__', '7')
    Write-Utf8 (Join-Path $round 'report.md') $l4Report

    $pass = Invoke-Check (Join-Path $round 'report.md')
    Assert-True ($pass.Code -eq 0) ('L4 报告应 PASS：' + $pass.Output)
    Assert-True ($pass.Output -match 'L4 1 条') 'PASS 文案包含 L4 用例数'

    $no15 = $l4Report
    $idx = $no15.IndexOf('### 十五、')
    if ($idx -gt 0) { $no15 = $no15.Substring(0, $idx) }
    Write-Utf8 (Join-Path $round 'report-no15.md') $no15
    $fail15 = Invoke-Check (Join-Path $round 'report-no15.md')
    Assert-True ($fail15.Code -eq 1) ('缺十五节应 FAIL：' + $fail15.Output)
    Assert-True ($fail15.Output -match '缺章节：### 十五、') 'FAIL 文案命中缺十五节'

    $l2 = $l4Report.Replace('（L4）', '（L2）')
    $l2 = [regex]::Replace($l2, '(?m)^\*\*L4 套件冻结\*\*.*\r?\n', '')
    $l2 = [regex]::Replace($l2, '(?m)^\*\*L4 执行\*\*.*\r?\n', '')
    $idx = $l2.IndexOf('### 十五、')
    if ($idx -gt 0) { $l2 = $l2.Substring(0, $idx) }
    Write-Utf8 (Join-Path $round 'report-l2.md') $l2
    $l2Result = Invoke-Check (Join-Path $round 'report-l2.md')
    Assert-True ($l2Result.Code -eq 0) ('L2 报告应 PASS：' + $l2Result.Output)
    Assert-True (-not ($l2Result.Output -match '缺章节：### 十五、')) 'L2 报告不误报缺十五节'

    # 模板里的 L4 说明块（带缩进）不应被识别为 L4 首部字段
    $templatePath = Join-Path $root 'module-test\assets\report-template.md'
    $templateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
    Assert-True (-not ($templateText -match '(?m)^\*\*L4 套件冻结\*\*')) '报告模板不含可检测的 L4 首部行'

    $tplReport = $l4Report -replace '(?m)^\*\*L4 套件冻结\*\*', '>   **L4 套件冻结**' -replace '(?m)^\*\*L4 执行\*\*', '>   **L4 执行**'
    Write-Utf8 (Join-Path $round 'report-tpl.md') $tplReport
    $tplResult = Invoke-Check (Join-Path $round 'report-tpl.md')
    Assert-True ($tplResult.Code -eq 0) ('模板说明块不应触发 L4 校验：' + $tplResult.Output)
    Assert-True (-not ($tplResult.Output -match 'L4 1 条')) '模板说明块不被计为 L4 用例'
} catch {
    Write-Output ('FAIL ' + $_.Exception.Message)
    $failures += $_.Exception.Message
} finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Output ('FAILED: {0} 项' -f $failures.Count)
    exit 1
}
Write-Output 'PASS: check-report L4 冒烟测试通过'
exit 0
