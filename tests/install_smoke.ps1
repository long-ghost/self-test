[CmdletBinding()]
param(
    [string]$SourceRepo = ''
)

# 端到端验证：安装 → 检查更新 → 升级。只在临时目录里操作，不碰本机技能目录和源仓库。
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$env:GIT_PAGER = 'cat'
$repo = $SourceRepo
if (-not $repo) { $repo = Split-Path -Parent $PSScriptRoot }

$hostExe = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('mt-install-smoke-' + [guid]::NewGuid().ToString('N'))
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

function Invoke-ChildScript {
    param([string]$ScriptPath, [string[]]$ScriptArgs = @())
    $out = @(& $hostExe -NoProfile -File $ScriptPath @ScriptArgs 2>&1 | ForEach-Object { $_.ToString() })
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out -join "`n") }
}

try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $src = Join-Path $work 'src'
    & git clone --quiet $repo $src
    if ($LASTEXITCODE -ne 0) { throw ('git clone 失败：' + $repo) }

    $skillDir = Join-Path $work 'skill'
    $agentDir = Join-Path $work 'agents'
    $cacheDir = Join-Path $work 'cache'
    $installScript = Join-Path $src 'module-test/scripts/install.ps1'
    $checkScript = Join-Path $src 'module-test/scripts/check-update.ps1'
    $updateScript = Join-Path $src 'module-test/scripts/update.ps1'
    $commonArgs = @('-RepoUrl', $src, '-CacheDir', $cacheDir, '-SkillDir', $skillDir, '-AgentDir', $agentDir)

    $result = Invoke-ChildScript $installScript $commonArgs
    Assert-True ($result.Code -eq 0) ('install.ps1 退出码 0：' + $result.Output)
    Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'SKILL.md')) '安装后存在 SKILL.md'
    $manifest = $null
    if (Test-Path -LiteralPath (Join-Path $skillDir '.install.json')) {
        $manifest = Get-Content -LiteralPath (Join-Path $skillDir '.install.json') -Raw | ConvertFrom-Json
    }
    Assert-True ($null -ne $manifest -and $manifest.commit.Length -ge 7) '写入安装记录与提交号'
    Assert-True (Test-Path -LiteralPath (Join-Path $agentDir 'module-test-runner.md')) '安装独立 agent'
    Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'scripts/l4-run.ps1')) '安装后存在 L4 执行脚本'
    Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'references/l4-midscene.md')) '安装后存在 L4 参考文档'
    Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'assets/midscene-suite.schema.json')) '安装后存在 L4 套件 schema'

    $installedVersion = $manifest.version
    $localConfig = Join-Path $skillDir 'references/test-accounts.csv'
    Set-Content -LiteralPath $localConfig -Value 'LOCAL-CONFIG-KEEP' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $skillDir 'stale.txt') -Value 'stale' -Encoding UTF8
    $agentTarget = Join-Path $agentDir 'module-test-runner.md'
    Add-Content -LiteralPath $agentTarget -Value '# local-customization' -Encoding UTF8

    $check1 = Invoke-ChildScript $checkScript @('-CacheDir', $cacheDir, '-SkillDir', $skillDir)
    Assert-True ($check1.Code -eq 0) ('安装后检查更新返回 0：' + $check1.Output)

    $skillMd = Join-Path $src 'module-test/SKILL.md'
    $text = Get-Content -LiteralPath $skillMd -Raw -Encoding UTF8
    $text = [regex]::Replace($text, '(?m)^version:\s*.*$', 'version: "9.9.9"')
    Set-Content -LiteralPath $skillMd -Value $text -Encoding UTF8 -NoNewline
    $changelog = Join-Path $src 'CHANGELOG.md'
    $cl = Get-Content -LiteralPath $changelog -Raw -Encoding UTF8
    $cl = [regex]::Replace($cl, '(?m)^# Changelog\s*$', "# Changelog`n`n## v9.9.9 — smoke`n`n- 模拟升级")
    Set-Content -LiteralPath $changelog -Value $cl -Encoding UTF8 -NoNewline
    Add-Content -LiteralPath (Join-Path $src 'module-test/agents/module-test-runner.md') -Value '<!-- smoke-updated -->' -Encoding UTF8
    & git -C $src -c user.name=smoke -c user.email=smoke@example.invalid add -A
    & git -C $src -c user.name=smoke -c user.email=smoke@example.invalid commit -m 'test: 模拟 v9.9.9 升级' --quiet
    if ($LASTEXITCODE -ne 0) { throw '模拟升级提交失败' }

    $check2 = Invoke-ChildScript $checkScript @('-CacheDir', $cacheDir, '-SkillDir', $skillDir)
    Assert-True ($check2.Code -eq 2) ('有新版本时检查更新返回 2：' + $check2.Output)
    Assert-True ($check2.Output -match '9\.9\.9') '检查更新输出远端版本号'
    Assert-True (Test-Path -LiteralPath $localConfig) '检查更新不改动本地配置'

    $upd = Invoke-ChildScript $updateScript @('-CacheDir', $cacheDir, '-SkillDir', $skillDir, '-AgentDir', $agentDir)
    Assert-True ($upd.Code -eq 0) ('update.ps1 退出码 0：' + $upd.Output)
    $newText = Get-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Raw -Encoding UTF8
    Assert-True ($newText -match 'version:\s*"9\.9\.9"') ('升级后版本从 {0} 变为 9.9.9' -f $installedVersion)
    Assert-True ((Get-Content -LiteralPath $localConfig -Raw) -match 'LOCAL-CONFIG-KEEP') '升级保留本地账号表'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $skillDir 'stale.txt'))) '升级删除本地多余文件'
    $agentNow = Get-Content -LiteralPath $agentTarget -Raw
    Assert-True ($agentNow -match 'local-customization') '升级不覆盖用户改过的 agent'
    Assert-True (Test-Path -LiteralPath ($agentTarget + '.new')) 'agent 差异写入 .new'

    $check3 = Invoke-ChildScript $checkScript @('-CacheDir', $cacheDir, '-SkillDir', $skillDir)
    Assert-True ($check3.Code -eq 0) ('升级后检查更新返回 0：' + $check3.Output)
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
Write-Output 'PASS: 安装/更新冒烟测试通过'
exit 0
