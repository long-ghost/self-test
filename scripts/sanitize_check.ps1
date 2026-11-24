param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$excluded = @('.git', 'dist', 'tests/fixtures')
$localConfigs = @(
    'module-test/references/project-profile.md',
    'module-test/references/test-accounts.csv',
    'module-test/references/code-owners.json',
    'module-test/references/setup-status.md'
)
$extensions = @('.md', '.py', '.ps1', '.json', '.csv', '.yml', '.yaml', '.txt')

$patterns = @(
    ('D' + '实绩'),
    ('192' + '\.168'),
    ('zc' + '_token'),
    ('X-' + 'Accesstoken'),
    ('s_' + 'user'),
    ('s_' + 'dept_user'),
    ('agent' + '-browser'),
    ('C:' + '\\Users\\'),
    ('E:' + '\\Desktop\\'),
    '[A-Za-z]:\\[A-Za-z0-9_. -]+\\[A-Za-z0-9_. -]+',
    '\b1[3-9]\d{9}\b'
)

$files = Get-ChildItem -LiteralPath $rootFull -Recurse -File |
    Where-Object {
        $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
        $skip = $localConfigs -contains $rel
        if (-not $skip) {
            foreach ($dir in $excluded) {
                if ($rel -eq $dir -or $rel.StartsWith($dir + '/')) { $skip = $true; break }
            }
        }
        (-not $skip) -and ($extensions -contains $_.Extension.ToLower())
    }

$hits = @()
foreach ($file in $files) {
    foreach ($pattern in $patterns) {
        $found = Select-String -LiteralPath $file.FullName -Pattern $pattern -AllMatches
        foreach ($m in $found) {
            $hits += [pscustomobject]@{
                File = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/')
                Line = $m.LineNumber
                Pattern = $pattern
                Text = $m.Line.Trim()
            }
        }
    }
}

if ($hits.Count -eq 0) {
    Write-Output 'PASS: 脱敏扫描无命中'
    exit 0
}

Write-Output ("FAIL: 脱敏扫描命中 {0} 处" -f $hits.Count)
$hits | Select-Object -First 50 | ForEach-Object {
    Write-Output ("  - {0}:{1} [{2}] {3}" -f $_.File, $_.Line, $_.Pattern, $_.Text)
}
exit 1
