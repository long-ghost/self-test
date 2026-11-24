[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$Ref,
    [string]$CacheDir,
    [string]$SkillDir,
    [string]$AgentDir,
    [switch]$SkipAgent
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-common.ps1')

try {
    Initialize-ConsoleEncoding
    Assert-GitAvailable

    if (-not $SkillDir) { $SkillDir = Join-Path (Join-Path $HOME '.codebuddy') 'skills/module-test' }
    if (-not $AgentDir) { $AgentDir = Join-Path (Join-Path $HOME '.codebuddy') 'agents' }
    if (-not $Ref) { $Ref = $script:DefaultRef }

    $manifest = Read-InstallManifest $SkillDir
    if (-not $manifest) {
        throw ('未找到安装记录（{0}）。请先运行 install.ps1；zip 解压安装的也用它接管一次。' -f (Join-Path $SkillDir '.install.json'))
    }
    if (-not $RepoUrl) { $RepoUrl = $manifest.repo }
    if (-not $RepoUrl) { $RepoUrl = $script:DefaultRepoUrl }
    if (-not $CacheDir) { $CacheDir = Join-Path (Join-Path $HOME '.codebuddy') 'skill-cache/module-test' }

    if (-not (Test-Path -LiteralPath (Join-Path $CacheDir '.git'))) {
        throw ('缓存仓库不存在：{0}。请重新运行 install.ps1。' -f $CacheDir)
    }
    $origin = ((Invoke-Git @('remote', 'get-url', 'origin') $CacheDir).Output -join '').Trim()
    if ($origin -ne $RepoUrl) {
        throw ('缓存仓库远程地址是 {0}，与安装记录 {1} 不一致；请重新 install.ps1 -Force。' -f $origin, $RepoUrl)
    }

    Write-Output ('检查更新：{0}（{1}）' -f $RepoUrl, $Ref)
    Invoke-Git @('fetch', '--prune', 'origin') $CacheDir | Out-Null

    $newRef = 'origin/{0}' -f $Ref
    $newCommit = ((Invoke-Git @('rev-parse', $newRef) $CacheDir).Output -join '').Trim()
    $oldCommit = $manifest.commit
    $installedVersion = Get-SkillVersion (Join-Path $SkillDir 'SKILL.md')
    if (-not $installedVersion) { $installedVersion = $manifest.version }

    $remoteSkillMd = (Invoke-Git @('show', ('{0}:module-test/SKILL.md' -f $newRef)) $CacheDir).Output -join "`n"
    $remoteVersion = Get-VersionFromText $remoteSkillMd

    if ($newCommit -eq $oldCommit) {
        Write-Output ('已是最新：v{0}（{1}）' -f $installedVersion, (Get-ShortCommit $oldCommit))
        exit 0
    }

    $hasRange = $true
    $probe = Invoke-Git @('cat-file', '-e', ('{0}^{{commit}}' -f $oldCommit)) $CacheDir -AllowFailure
    if ($probe.Code -ne 0) { $hasRange = $false }

    Write-Output ('本地版本：v{0}（{1}）' -f $installedVersion, (Get-ShortCommit $oldCommit))
    Write-Output ('远端版本：v{0}（{1}）' -f $remoteVersion, (Get-ShortCommit $newCommit))
    if ($hasRange -and $installedVersion -eq $remoteVersion) {
        Write-Output '注意：版本号未变但提交有差异，可能是文档或脚本修正。'
    }
    if ($hasRange) {
        $log = (Invoke-Git @('log', '--oneline', '--no-decorate', ('{0}..{1}' -f $oldCommit, $newCommit)) $CacheDir).Output
        Write-Output ('变更提交（{0} 个）：' -f $log.Count)
        $log | Select-Object -First 20 | ForEach-Object { Write-Output ('  ' + $_) }
        $stat = (Invoke-Git @('diff', '--stat', ('{0}..{1}' -f $oldCommit, $newCommit)) $CacheDir).Output
        Write-Output '变更文件：'
        $stat | Select-Object -First 20 | ForEach-Object { Write-Output ('  ' + $_) }
    }

    $remoteChangelog = (Invoke-Git @('show', ('{0}:CHANGELOG.md' -f $newRef)) $CacheDir -AllowFailure)
    if ($remoteChangelog.Code -eq 0) {
        $section = Get-ChangelogSection ($remoteChangelog.Output -join "`n") $remoteVersion
        if ($section) {
            Write-Output ''
            Write-Output '变更记录：'
            $section -split "`n" | ForEach-Object { Write-Output ('  ' + $_) }
        }
    }

    Write-Output ''
    Invoke-Git @('checkout', $Ref) $CacheDir | Out-Null
    Invoke-Git @('merge', '--ff-only', $newRef) $CacheDir | Out-Null

    $source = Join-Path $CacheDir 'module-test'
    if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) {
        throw ('仓库中缺少 module-test/SKILL.md：{0}' -f $source)
    }
    Sync-SkillTree -SourceDir $source -TargetDir $SkillDir -Preserve $script:PreservedConfigs

    $agentState = 'skipped'
    if (-not $SkipAgent) {
        $agentState = Install-AgentFile -SourcePath (Join-Path $source 'agents/module-test-runner.md') -AgentDir $AgentDir -OnlyIfExists
    }

    $version = Get-SkillVersion (Join-Path $SkillDir 'SKILL.md')
    Write-InstallManifest -SkillDir $SkillDir -Version $version -Commit $newCommit -Ref $Ref -Repo $RepoUrl -InstalledAt $manifest.installedAt

    Write-Output ('更新完成：v{0} → v{1}（{2}）' -f $installedVersion, $version, (Get-ShortCommit $newCommit))
    Write-Output ('技能目录：{0}' -f $SkillDir)
    $kept = @($script:PreservedConfigs | Where-Object { Test-Path -LiteralPath (Join-Path $SkillDir $_) })
    if ($kept.Count -gt 0) {
        Write-Output ('已保留本地配置：{0}' -f ($kept -join '、'))
    }
    $agentPath = Join-Path $AgentDir 'module-test-runner.md'
    switch ($agentState) {
        'copied' { Write-Output ('独立 agent 已同步：{0}' -f $agentPath) }
        'pending' { Write-Warning ('agent 内容有更新，已写到 {0}.new；确认后替换。' -f $agentPath) }
        'unchanged' { Write-Output '独立 agent 无变化。' }
        'absent' { Write-Output '未安装独立 agent，保持现状。' }
    }
    exit 0
} catch {
    Write-Output ('FAIL: ' + $_.Exception.Message)
    exit 1
}
