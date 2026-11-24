[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$Ref = 'main',
    [string]$CacheDir,
    [string]$SkillDir,
    [string]$AgentDir,
    [switch]$SkipAgent,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-common.ps1')

try {
    Initialize-ConsoleEncoding
    Assert-GitAvailable

    if (-not $RepoUrl) { $RepoUrl = $script:DefaultRepoUrl }
    if (-not $CacheDir) { $CacheDir = Join-Path (Join-Path $HOME '.codebuddy') 'skill-cache/module-test' }
    if (-not $SkillDir) { $SkillDir = Join-Path (Join-Path $HOME '.codebuddy') 'skills/module-test' }
    if (-not $AgentDir) { $AgentDir = Join-Path (Join-Path $HOME '.codebuddy') 'agents' }

    $manifestPath = Join-Path $SkillDir '.install.json'
    if ((Test-Path -LiteralPath $manifestPath) -and -not $Force) {
        throw ('已安装（{0}）。升级请运行 update.ps1；确实要重装再加 -Force。' -f $SkillDir)
    }

    $cacheGit = Join-Path $CacheDir '.git'
    if (Test-Path -LiteralPath $cacheGit) {
        $origin = ((Invoke-Git @('remote', 'get-url', 'origin') $CacheDir).Output -join '').Trim()
        if ($origin -ne $RepoUrl -and -not $Force) {
            throw ('缓存目录的远程地址是 {0}，与 -RepoUrl {1} 不一致；确认后加 -Force。' -f $origin, $RepoUrl)
        }
        Invoke-Git @('fetch', '--prune', 'origin') $CacheDir | Out-Null
        Invoke-Git @('checkout', $Ref) $CacheDir | Out-Null
        Invoke-Git @('merge', '--ff-only', ('origin/{0}' -f $Ref)) $CacheDir | Out-Null
    } else {
        if (Test-Path -LiteralPath $CacheDir) {
            throw ('缓存目录已存在但不是 Git 仓库：{0}；移走或换 -CacheDir。' -f $CacheDir)
        }
        $parent = Split-Path -Parent $CacheDir
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-Output ('克隆 {0} → {1}' -f $RepoUrl, $CacheDir)
        Invoke-Git @('clone', '--quiet', '--branch', $Ref, $RepoUrl, $CacheDir) $parent | Out-Null
    }

    $source = Join-Path $CacheDir 'module-test'
    if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) {
        throw ('仓库中缺少 module-test/SKILL.md：{0}' -f $source)
    }

    Write-Output ('同步 {0} → {1}' -f $source, $SkillDir)
    Sync-SkillTree -SourceDir $source -TargetDir $SkillDir -Preserve $script:PreservedConfigs

    $agentState = 'skipped'
    if (-not $SkipAgent) {
        $agentState = Install-AgentFile -SourcePath (Join-Path $source 'agents/module-test-runner.md') -AgentDir $AgentDir
    }

    $commit = ((Invoke-Git @('rev-parse', 'HEAD') $CacheDir).Output -join '').Trim()
    $repo = ((Invoke-Git @('remote', 'get-url', 'origin') $CacheDir).Output -join '').Trim()
    $version = Get-SkillVersion (Join-Path $SkillDir 'SKILL.md')
    Write-InstallManifest -SkillDir $SkillDir -Version $version -Commit $commit -Ref $Ref -Repo $repo

    Write-Output ''
    Write-Output ('安装完成：module-test v{0}（{1}）' -f $version, (Get-ShortCommit $commit))
    Write-Output ('技能目录：{0}' -f $SkillDir)
    $agentPath = Join-Path $AgentDir 'module-test-runner.md'
    switch ($agentState) {
        'copied' { Write-Output ('独立 agent 已安装：{0}' -f $agentPath) }
        'unchanged' { Write-Output ('独立 agent 已存在且一致：{0}' -f $agentPath) }
        'pending' { Write-Warning ('agent 已存在且内容不同，新版本写到 {0}.new；确认后再替换（现有文件可能改过 model 配置）。' -f $agentPath) }
        'missing-source' { Write-Warning '仓库中未找到 agents/module-test-runner.md，跳过 agent 安装。' }
        default { Write-Output '已跳过独立 agent 安装（-SkipAgent）。' }
    }
    Write-Output ''
    Write-Output '下一步：在待测项目根目录初始化本地配置：'
    Write-Output ('  powershell -NoProfile -File "{0}" -Root "<project-root>"' -f (Join-Path $SkillDir 'scripts/init-workspace.ps1'))
    exit 0
} catch {
    Write-Output ('FAIL: ' + $_.Exception.Message)
    exit 1
}
