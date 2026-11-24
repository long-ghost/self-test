[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$ref = Join-Path $skillRoot 'references'

$profile = Join-Path $ref 'project-profile.md'
$accounts = Join-Path $ref 'test-accounts.csv'
$owners = Join-Path $ref 'code-owners.json'
$status = Join-Path $ref 'setup-status.md'

$exampleProfile = Join-Path $ref 'project-profile.example.md'
$exampleAccounts = Join-Path $ref 'test-accounts.example.csv'
$exampleOwners = Join-Path $ref 'code-owners.example.json'

function Copy-IfMissing([string]$Source, [string]$Target) {
    if (Test-Path -LiteralPath $Target) { return $false }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
    return $true
}

$created = @()
if (Copy-IfMissing $exampleProfile $profile) { $created += 'project-profile.md' }
if (Copy-IfMissing $exampleAccounts $accounts) { $created += 'test-accounts.csv' }
if (Copy-IfMissing $exampleOwners $owners) { $created += 'code-owners.json' }

$detected = @()
if (Test-Path -LiteralPath (Join-Path $Root '.git')) { $detected += 'Git 仓库' }
foreach ($marker in @('package.json', 'pom.xml', 'build.gradle', 'pyproject.toml', 'requirements.txt', 'AGENTS.md', 'README.md')) {
    if (Test-Path -LiteralPath (Join-Path $Root $marker)) { $detected += $marker }
}
foreach ($pattern in @('application*.yml', 'application*.yaml', '.env*', 'vite.config.*')) {
    Get-ChildItem -LiteralPath $Root -File -Filter $pattern -ErrorAction SilentlyContinue |
        Select-Object -First 3 | ForEach-Object { $detected += $_.Name }
}
Get-ChildItem -LiteralPath $Root -Recurse -Depth 3 -File -Filter '*.csproj' -ErrorAction SilentlyContinue |
    Select-Object -First 3 | ForEach-Object { $detected += $_.FullName.Substring($Root.Length).TrimStart('\', '/') }
foreach ($dir in @('.codebuddy/rules', 'docs/requirements', 'docs/plans', 'docs/standards')) {
    if (Test-Path -LiteralPath (Join-Path $Root $dir)) { $detected += $dir }
}

if ($created -contains 'project-profile.md') {
    $auto = @(
        '',
        '## AUTO-DETECTED',
        '',
        "- 项目根：``$Root``",
        "- 探测项：" + (($detected | ForEach-Object { "``$_``" }) -join '、'),
        '- 未探测项保留占位符，请按项目实际补充。'
    ) -join "`r`n"
    Add-Content -LiteralPath $profile -Value $auto -Encoding UTF8
}

if ($created -contains 'code-owners.json') {
    $codeowners = Join-Path $Root 'CODEOWNERS'
    $ownersMap = [ordered]@{}
    if (Test-Path -LiteralPath $codeowners) {
        foreach ($line in (Get-Content -LiteralPath $codeowners -Encoding UTF8)) {
            $trim = $line.Trim()
            if (-not $trim -or $trim.StartsWith('#')) { continue }
            $parts = $trim -split '\s+'
            if ($parts.Count -ge 2) {
                $ownersMap[$parts[0]] = @($parts[1..($parts.Count - 1)] | ForEach-Object { $_.TrimStart('@') })
            }
        }
    }
    $ownerNotes = if ($ownersMap.Count -gt 0) { '从 CODEOWNERS 生成，请按模块核对' } else { '未找到 CODEOWNERS；可按模块/路径前缀补充' }
    $ownerJson = [ordered]@{ owners = $ownersMap; notes = $ownerNotes }
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
        $authors = @(& git -C $Root log --format=%an -n 20 2>$null | Sort-Object -Unique | Select-Object -First 5)
        if ($authors.Count -gt 0) { $ownerJson['suggested_owners'] = $authors }
    }
    [System.IO.File]::WriteAllText($owners, ($ownerJson | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

$missing = @()
$pending = @()
if (-not (Test-Path -LiteralPath $profile)) {
    $missing += 'project-profile.md（文件缺失）'
}
elseif ((Get-Content -LiteralPath $profile -Raw -Encoding UTF8) -match 'TODO|<project>|<module>|REPLACE_ME') {
    $pending += 'project-profile.md（仍有 TODO/占位符）'
}
if (-not (Test-Path -LiteralPath $accounts)) {
    $missing += 'test-accounts.csv（文件缺失）'
}
elseif ((Get-Content -LiteralPath $accounts -Raw -Encoding UTF8) -match 'REPLACE_ME') {
    $pending += 'test-accounts.csv（仍有 REPLACE_ME）'
}

$statusLines = @(
    '# 初始化状态',
    '',
    "生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "项目根：$Root",
    '',
    '## 已探测',
    ''
)
if ($detected.Count -gt 0) {
    foreach ($item in $detected) { $statusLines += "- $item" }
} else {
    $statusLines += '- 未探测到常见工程文件'
}
$statusLines += @(
    '',
    '## 待填写',
    '',
    '- `references/project-profile.md`：端口、启动命令、数据库、鉴权、浏览器、项目规则。',
    '- `references/test-accounts.csv`：真实测试账号；姓名/电话/密码为 `REPLACE_ME` 时必须补填。',
    '- `references/code-owners.json`：按模块/路径前缀补责任人；没有可留空。',
    '',
    '## 档位影响',
    '',
    '- L1：无需账号，可执行静态/契约核对。',
    '- L2/L3：缺 project-profile 或 test-accounts 时不得开测；先补齐。',
    '- 未安装 `agents/module-test-runner.md`：仍可自测，但按 R-19 降级并声明结论上限。'
)
if ($created.Count -gt 0) {
    $statusLines += @('', '## 本次创建', '')
    foreach ($item in $created) { $statusLines += "- $item" }
}
[System.IO.File]::WriteAllLines($status, $statusLines, (New-Object System.Text.UTF8Encoding($false)))

Write-Output "初始化完成，项目根：$Root"
Write-Output "本地配置：$ref"
Write-Output "状态清单：$status"
if ($created.Count -gt 0) { Write-Output ('已创建模板：' + ($created -join '、')) }
if ($pending.Count -gt 0) {
    Write-Warning ('待填写：' + ($pending -join '、'))
}
if ($missing.Count -gt 0) {
    Write-Warning ('L2/L3 仍缺：' + ($missing -join '、'))
}
if ($CheckOnly -and ($missing.Count -gt 0 -or $pending.Count -gt 0)) { exit 1 }
exit 0
