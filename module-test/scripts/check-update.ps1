[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$Ref,
    [string]$CacheDir,
    [string]$SkillDir
)

# 退出码：0 已是最新 / 2 有更新 / 1 出错
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-common.ps1')

try {
    Initialize-ConsoleEncoding
    Assert-GitAvailable

    if (-not $SkillDir) { $SkillDir = Join-Path (Join-Path $HOME '.codebuddy') 'skills/module-test' }
    if (-not $Ref) { $Ref = $script:DefaultRef }

    $manifest = Read-InstallManifest $SkillDir
    if (-not $manifest) {
        throw ('未找到安装记录（{0}）。AI/用户可运行 install.ps1 安装或接管现有目录。' -f (Join-Path $SkillDir '.install.json'))
    }
    if (-not $RepoUrl) { $RepoUrl = $manifest.repo }
    if (-not $RepoUrl) { $RepoUrl = $script:DefaultRepoUrl }
    if (-not $CacheDir) { $CacheDir = Join-Path (Join-Path $HOME '.codebuddy') 'skill-cache/module-test' }
    if (-not (Test-Path -LiteralPath (Join-Path $CacheDir '.git'))) {
        throw ('缓存仓库不存在：{0}。请重新运行 install.ps1。' -f $CacheDir)
    }

    Invoke-Git @('fetch', '--prune', 'origin') $CacheDir | Out-Null

    $newRef = 'origin/{0}' -f $Ref
    $newCommit = ((Invoke-Git @('rev-parse', $newRef) $CacheDir).Output -join '').Trim()
    $installedVersion = Get-SkillVersion (Join-Path $SkillDir 'SKILL.md')
    if (-not $installedVersion) { $installedVersion = $manifest.version }
    $remoteSkillMd = (Invoke-Git @('show', ('{0}:module-test/SKILL.md' -f $newRef)) $CacheDir).Output -join "`n"
    $remoteVersion = Get-VersionFromText $remoteSkillMd

    if ($newCommit -eq $manifest.commit) {
        Write-Output ('已是最新：v{0}（{1}）' -f $installedVersion, (Get-ShortCommit $newCommit))
        exit 0
    }

    Write-Output ('更新可用：v{0}（{1}） → v{2}（{3}）' -f $installedVersion, (Get-ShortCommit $manifest.commit), $remoteVersion, (Get-ShortCommit $newCommit))

    $probe = Invoke-Git @('cat-file', '-e', ('{0}^{{commit}}' -f $manifest.commit)) $CacheDir -AllowFailure
    if ($probe.Code -eq 0) {
        $log = (Invoke-Git @('log', '--oneline', '--no-decorate', ('{0}..{1}' -f $manifest.commit, $newCommit)) $CacheDir).Output
        Write-Output ('新提交（{0} 个）：' -f $log.Count)
        $log | Select-Object -First 10 | ForEach-Object { Write-Output ('  ' + $_) }
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
    Write-Output ('升级：powershell -NoProfile -File "{0}"' -f (Join-Path $SkillDir 'scripts/update.ps1'))
    Write-Output '有更新先告知用户并确认，不要在自测中途升级。'
    exit 2
} catch {
    Write-Output ('FAIL: ' + $_.Exception.Message)
    exit 1
}
