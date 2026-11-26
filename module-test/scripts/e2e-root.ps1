# 产物根 E2E_ROOT 统一解析（l4-run.ps1 / check-report.ps1 共用）
# 优先级：环境变量 E2E_ROOT > references/project-profile.md 的 E2E_ROOT= 行 > 默认 <repo>/E2E测试
# 相对路径按仓库根解析；绝对路径原样使用。产物根允许在仓库外。

function Get-E2ERoot {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$SkillRoot = ''
    )
    $raw = $env:E2E_ROOT
    if ([string]::IsNullOrWhiteSpace($raw) -and $SkillRoot) {
        $profile = Join-Path $SkillRoot 'references\project-profile.md'
        if (Test-Path -LiteralPath $profile) {
            foreach ($line in (Get-Content -LiteralPath $profile -Encoding UTF8)) {
                if ($line -match '^\s*E2E_ROOT\s*[:=]\s*(.+?)\s*$') {
                    $raw = $Matches[1].Trim().Trim('"').Trim("'").Trim('`')
                    break
                }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = 'E2E测试' }
    if ([System.IO.Path]::IsPathRooted($raw)) {
        return [System.IO.Path]::GetFullPath($raw).TrimEnd('\', '/')
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $raw)).TrimEnd('\', '/')
}

function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ([string]::Equals($p, $r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}
