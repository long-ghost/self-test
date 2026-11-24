<#
.SYNOPSIS
  导出 module-test 技能的脱敏副本，用于转发 / 打包 / 分享。

.DESCRIPTION
  复制技能目录到目标路径，并把 references/test-accounts.csv 重写为脱敏版：
  - 手机号默认只保留前 3 位与后 4 位；
  - 密码统一写成 ******；
  - 也可用 -OmitAccounts 直接不导出账号表（对外分享推荐）。

  只读取本机原表，只写入目标目录，绝不改动本机原文件。

.PARAMETER Dest
  导出目录（不存在会自动创建；已存在则合并覆盖）。

.PARAMETER OmitAccounts
  不导出账号表（最安全，适合完全对外）。

.PARAMETER KeepPhone
  保留完整手机号（只脱敏密码），适合只在内网小范围流转。

.EXAMPLE
  powershell -NoProfile -File scripts/export-sanitized.ps1 -Dest <export-dir>

.EXAMPLE
  powershell -NoProfile -File scripts/export-sanitized.ps1 -Dest <export-dir> -OmitAccounts
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Dest,
    [switch]$OmitAccounts,
    [switch]$KeepPhone
)

$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md'))) {
    throw "未找到 SKILL.md，当前脚本可能不在技能目录的 scripts/ 下：$PSScriptRoot"
}

$srcFull = (Resolve-Path -LiteralPath $skillRoot).Path.TrimEnd('\')
$destFull = [System.IO.Path]::GetFullPath($Dest).TrimEnd('\')
if ($destFull -eq $srcFull -or $destFull.StartsWith($srcFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "导出目录不能位于技能目录内部：$destFull"
}

New-Item -ItemType Directory -Force -Path $destFull | Out-Null
Copy-Item -Path (Join-Path $srcFull '*') -Destination $destFull -Recurse -Force
$copiedAccounts = Join-Path $destFull 'references\test-accounts.csv'
if (Test-Path -LiteralPath $copiedAccounts) { Remove-Item -LiteralPath $copiedAccounts -Force }
Write-Output "[1/3] 已复制技能文件到 $destFull（已移除复制过来的明文账号表）"

$accountsSrc = Join-Path $srcFull 'references\test-accounts.csv'
$accountsDest = Join-Path $destFull 'references\test-accounts.csv'

if ($OmitAccounts) {
    if (Test-Path -LiteralPath $accountsDest) { Remove-Item -LiteralPath $accountsDest -Force }
    Write-Output '[2/3] 已按 -OmitAccounts 跳过账号表'
    Write-Output '[3/3] 完成：导出副本不含任何账号密码'
    exit 0
}

if (-not (Test-Path -LiteralPath $accountsSrc)) {
    if (Test-Path -LiteralPath $accountsDest) { Remove-Item -LiteralPath $accountsDest -Force }
    Write-Output '[2/3] 源账号表不存在，跳过脱敏'
    Write-Output '[3/3] 完成：导出副本不含账号表'
    exit 0
}

$rows = Import-Csv -LiteralPath $accountsSrc -Encoding UTF8
$masked = @()
foreach ($row in $rows) {
    $phone = [string]$row.'联系电话'
    if (-not $KeepPhone -and $phone -match '^(\d{3})\d{4}(\d{4})$') {
        $phone = $Matches[1] + '****' + $Matches[2]
    }
    $masked += [pscustomobject][ordered]@{
        '姓名'     = $row.'姓名'
        '部门'     = $row.'部门'
        '联系电话' = $phone
        '密码'     = '******'
        '适用场景' = $row.'适用场景'
    }
}

$duplicates = $masked | Group-Object '联系电话' | Where-Object { $_.Count -gt 1 -and $_.Name -ne '******' }
if ($duplicates) {
    Write-Warning ('账号表里存在重复联系电话：' + (($duplicates | ForEach-Object { $_.Name }) -join ', '))
}

$csvLines = $masked | ConvertTo-Csv -NoTypeInformation
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllLines($accountsDest, $csvLines, $utf8WithBom)
Write-Output ("[2/3] 已生成脱敏账号表：{0} 条记录（密码打码{1}）" -f $masked.Count, $(if ($KeepPhone) { '，手机号保留' } else { '，手机号中间 4 位打码' }))
Write-Output '[3/3] 完成：导出副本可安全转发'
