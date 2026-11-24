# install.ps1 / update.ps1 / check-update.ps1 共用函数，由调用方 dot-source 引入。

$script:DefaultRepoUrl = 'https://github.com/long-ghost/self-test.git'
$script:DefaultRef = 'main'
$script:PreservedConfigs = @(
    'references/project-profile.md',
    'references/test-accounts.csv',
    'references/code-owners.json',
    'references/setup-status.md'
)

function Initialize-ConsoleEncoding {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    $env:GIT_PAGER = 'cat'
}

function Assert-GitAvailable {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw '未找到 git，请先安装 Git 并加入 PATH。'
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$WorkDir = '',
        [switch]$AllowFailure
    )
    $prev = Get-Location
    $prevEap = $ErrorActionPreference
    # 原生命令写 stderr 时，Stop 模式会把重定向内容当终止错误；这里局部放宽再自行判断退出码。
    $ErrorActionPreference = 'Continue'
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        $out = @(& git @ArgumentList 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    } finally {
        Set-Location $prev
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ('git {0} 执行失败（退出码 {1}）：{2}' -f ($ArgumentList -join ' '), $code, ($out -join "`n"))
    }
    [pscustomobject]@{ Code = $code; Output = $out }
}

function Get-ShortCommit {
    param([string]$Commit)
    if (-not $Commit) { return 'unknown' }
    if ($Commit.Length -le 7) { return $Commit }
    return $Commit.Substring(0, 7)
}

function Get-VersionFromText {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(?m)^version:\s*[''"]?([0-9A-Za-z._-]+)[''"]?\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-SkillVersion {
    param([string]$SkillMdPath)
    if (-not (Test-Path -LiteralPath $SkillMdPath)) { return $null }
    return Get-VersionFromText (Get-Content -LiteralPath $SkillMdPath -Raw -Encoding UTF8)
}

function Read-InstallManifest {
    param([string]$SkillDir)
    $p = Join-Path $SkillDir '.install.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-InstallManifest {
    param(
        [string]$SkillDir,
        [string]$Version,
        [string]$Commit,
        [string]$Ref,
        [string]$Repo,
        [string]$InstalledAt
    )
    $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    if (-not $InstalledAt) { $InstalledAt = $now }
    $obj = [ordered]@{
        skill       = 'module-test'
        version     = $Version
        commit      = $Commit
        ref         = $Ref
        repo        = $Repo
        installedAt = $InstalledAt
        updatedAt   = $now
    }
    $json = $obj | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $SkillDir '.install.json') -Value $json -Encoding UTF8
}

# 以仓库为准同步技能目录：保留本地配置、删除仓库中已不存在的文件、重写 .install.json 由调用方负责。
function Sync-SkillTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [string[]]$Preserve = @()
    )
    $srcFull = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    $dstFull = [System.IO.Path]::GetFullPath($TargetDir).TrimEnd('\', '/')

    $backup = @{}
    foreach ($rel in $Preserve) {
        $p = Join-Path $dstFull $rel
        if (Test-Path -LiteralPath $p) { $backup[$rel] = [System.IO.File]::ReadAllBytes($p) }
    }

    $sourceRels = @{}
    Get-ChildItem -LiteralPath $srcFull -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($srcFull.Length).TrimStart('\', '/')
        $sourceRels[$rel.Replace('\', '/')] = $true
        $dest = Join-Path $dstFull $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }

    $preserveSet = @{}
    foreach ($rel in $Preserve) { $preserveSet[$rel.Replace('\', '/')] = $true }

    Get-ChildItem -LiteralPath $dstFull -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($dstFull.Length).TrimStart('\', '/').Replace('\', '/')
        if ($_.Name -eq '.install.json') { return }
        if ($preserveSet.ContainsKey($rel)) { return }
        if (-not $sourceRels.ContainsKey($rel)) {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }

    foreach ($rel in $Preserve) {
        if (-not $backup.ContainsKey($rel)) { continue }
        $p = Join-Path $dstFull $rel
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes($p, $backup[$rel])
    }
}

# 安装时默认复制 agent；更新时只处理已存在的 agent，且不覆盖用户改过的内容。
function Install-AgentFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$AgentDir,
        [switch]$OnlyIfExists
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) { return 'missing-source' }
    $target = Join-Path $AgentDir 'module-test-runner.md'
    if ($OnlyIfExists -and -not (Test-Path -LiteralPath $target)) { return 'absent' }
    if (-not (Test-Path -LiteralPath $target)) {
        if (-not (Test-Path -LiteralPath $AgentDir)) {
            New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $SourcePath -Destination $target -Force
        return 'copied'
    }
    $srcHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $same = $srcHash -eq $dstHash
    if ($same) { return 'unchanged' }
    Copy-Item -LiteralPath $SourcePath -Destination ($target + '.new') -Force
    return 'pending'
}

function Get-ChangelogSection {
    param([string]$Text, [string]$Version)
    if (-not $Text -or -not $Version) { return $null }
    $lines = $Text -split "`r?`n"
    $start = -1
    $headPattern = '^##\s+v?' + [regex]::Escape($Version)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $headPattern) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = $lines.Count
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^##\s') { $end = $j; break }
    }
    return ($lines[$start..($end - 1)] -join "`n").Trim()
}
