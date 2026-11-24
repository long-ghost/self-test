[CmdletBinding()]
param(
    [string]$PackageScript = '',
    [string]$OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repo 'module-test'
$out = Join-Path $repo $OutDir

if (-not (Test-Path -LiteralPath $skill)) { throw "skill 目录不存在：$skill" }

$sanitize = Join-Path $repo 'scripts\sanitize_check.ps1'
& powershell -NoProfile -File $sanitize -Root $repo
if ($LASTEXITCODE -ne 0) { throw '脱敏检查未通过，禁止打包。' }

foreach ($local in @('project-profile.md', 'test-accounts.csv', 'code-owners.json', 'setup-status.md')) {
    $p = Join-Path (Join-Path $skill 'references') $local
    if (Test-Path -LiteralPath $p) {
        throw "发现本机真实配置 $local；请移出后再打包，避免进入 zip。"
    }
}

if ([string]::IsNullOrWhiteSpace($PackageScript)) {
    $PackageScript = $env:CODEBUDDY_SKILL_CREATOR
    if ([string]::IsNullOrWhiteSpace($PackageScript) -or -not (Test-Path -LiteralPath $PackageScript)) {
        throw '未找到 skill-creator 的 package_skill.py；请用 -PackageScript 指定路径，或设置 CODEBUDDY_SKILL_CREATOR。'
    }
}

$cacheDirs = @(Get-ChildItem -LiteralPath $skill -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue)
if ($cacheDirs.Count -gt 0) { $cacheDirs | Remove-Item -Recurse -Force }
$pycFiles = @(Get-ChildItem -LiteralPath $skill -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.pyc' })
if ($pycFiles.Count -gt 0) { $pycFiles | Remove-Item -Force }

New-Item -ItemType Directory -Force -Path $out | Out-Null
& python -X utf8 $PackageScript $skill $out
if ($LASTEXITCODE -ne 0) { throw "打包失败，退出码 $LASTEXITCODE" }
Write-Output "发布包输出目录：$out"
