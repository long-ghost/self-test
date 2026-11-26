[CmdletBinding()]
param(
    [string]$RunnerDir = (Join-Path $env:USERPROFILE '.codebuddy\skill-data\module-test\l4-runner'),
    [switch]$Install,
    [switch]$CheckOnly,
    [switch]$ModelVerify,
    [switch]$SkipPlaywright
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $skillRoot 'assets'

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments, [string]$WorkDir = '')
    $prev = Get-Location
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        $out = @(& $File @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    } finally {
        Set-Location $prev
        $ErrorActionPreference = $prevEap
    }
    [pscustomobject]@{ Code = $code; Output = $out }
}

$missing = @()

# ---------- Node ----------
$nodeOk = $false
$nodeVersion = ''
if (Get-Command node -ErrorAction SilentlyContinue) {
    $nodeVersion = (@(& node -v 2>$null) -join '').Trim()
    $raw = $nodeVersion.TrimStart('v')
    $parts = $raw -split '\.'
    if ($parts.Count -ge 2) {
        $major = 0
        $minor = 0
        [void][int]::TryParse($parts[0], [ref]$major)
        [void][int]::TryParse($parts[1].Split('-')[0], [ref]$minor)
        if (($major -eq 20 -and $minor -ge 19) -or ($major -eq 22 -and $minor -ge 12) -or ($major -ge 24)) {
            $nodeOk = $true
        }
    }
}
if ($nodeOk) { Write-Output "OK   Node $nodeVersion" } else {
    Write-Output "MISS Node 版本需 ^20.19 || ^22.12 || >=24（当前：$nodeVersion）"
    $missing += 'Node 版本'
}

# ---------- pnpm ----------
$pnpmPath = ''
if (Get-Command pnpm -ErrorAction SilentlyContinue) {
    $pnpmPath = (Get-Command pnpm).Source
    $pnpmVersion = (@(& $pnpmPath -v 2>$null) -join '').Trim()
    Write-Output "OK   pnpm $pnpmVersion"
} else {
    Write-Output 'MISS 未找到 pnpm（npm i -g pnpm）'
    $missing += 'pnpm'
}

# ---------- runner 目录与模板 ----------
if (-not (Test-Path -LiteralPath $RunnerDir)) {
    New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
}
$packageJson = Join-Path $RunnerDir 'package.json'
if (-not (Test-Path -LiteralPath $packageJson) -or $Install) {
    $packageText = @(
        '{',
        '  "name": "module-test-l4-runner",',
        '  "private": true,',
        '  "version": "1.0.0",',
        '  "type": "module"',
        '}',
        ''
    ) -join "`n"
    Write-Utf8 $packageJson $packageText
    Write-Output "OK   写入 package.json：$packageJson"
}

$templateDir = Join-Path $RunnerDir 'templates'
$configTarget = Join-Path $templateDir 'midscene.config.ts'
$configSource = Join-Path $assets 'midscene-config-template.ts'
if (-not (Test-Path -LiteralPath $configTarget) -or $Install) {
    if (Test-Path -LiteralPath $configSource) {
        $configText = Get-Content -LiteralPath $configSource -Raw -Encoding UTF8
        Write-Utf8 $configTarget $configText
        Write-Output "OK   写入配置模板：$configTarget"
    } else {
        Write-Output "MISS 技能资产缺失：$configSource"
        $missing += 'midscene-config-template.ts'
    }
}

$envExample = Join-Path $RunnerDir '.env.example'
if (-not (Test-Path -LiteralPath $envExample)) {
    $envText = @(
        '# 复制为 .env 后填写；.env 只留在本机 runner 目录，绝不入仓、绝不复制到产物',
        'MIDSCENE_MODEL_NAME=',
        'MIDSCENE_MODEL_API_KEY=',
        'MIDSCENE_MODEL_BASE_URL=',
        'MIDSCENE_MODEL_FAMILY=',
        'L4_BASE_URL=http://localhost:3000',
        'L4_COOKIES='
    ) -join "`n"
    Write-Utf8 $envExample ($envText + "`n")
    Write-Output "OK   写入 .env.example：$envExample"
}

# ---------- 依赖 ----------
$nodeModules = Join-Path $RunnerDir 'node_modules'
$midsceneInstalled = Test-Path -LiteralPath (Join-Path $nodeModules '@midscene\test')
if ($midsceneInstalled) { Write-Output 'OK   @midscene/test 已安装' } else {
    Write-Output 'MISS 未安装依赖（运行本脚本加 -Install）'
    $missing += '@midscene/test'
}

$chromiumPath = ''
if ($pnpmPath -and $midsceneInstalled) {
    $probe = Invoke-Native $pnpmPath @(
        'exec', 'node', '-e',
        "const{chromium}=require('playwright');process.stdout.write(chromium.executablePath())"
    ) $RunnerDir
    if ($probe.Code -eq 0) {
        $chromiumPath = ($probe.Output -join '').Trim()
    }
}
if ($chromiumPath -and (Test-Path -LiteralPath $chromiumPath)) {
    Write-Output "OK   Chromium：$chromiumPath"
} else {
    Write-Output 'MISS 未安装 Chromium（-Install 会执行 playwright install chromium）'
    $missing += 'Chromium'
}

# ---------- 模型 Key ----------
$dotEnv = Join-Path $RunnerDir '.env'
$hasEnvKey = -not [string]::IsNullOrWhiteSpace($env:MIDSCENE_MODEL_API_KEY)
$hasFileKey = $false
if (Test-Path -LiteralPath $dotEnv) {
    $envText = Get-Content -LiteralPath $dotEnv -Raw -Encoding UTF8
    if ($envText -match '(?m)^\s*MIDSCENE_MODEL_API_KEY\s*=\s*\S+') { $hasFileKey = $true }
}
if ($hasEnvKey -or $hasFileKey) { Write-Output 'OK   模型 Key 已配置（值不回显）' } else {
    Write-Output 'MISS 未配置 MIDSCENE_MODEL_API_KEY（进程环境或 runner/.env）'
    $missing += '模型 Key'
}

# ---------- 安装 ----------
$installFailed = $false
if ($Install -and -not $nodeOk) {
    Write-Output 'FAIL Node 版本不满足要求，无法安装'
    exit 2
}
$needInstall = ($missing -contains '@midscene/test') -or (($missing -contains 'Chromium') -and -not $SkipPlaywright)
if ($Install -and $needInstall) {
    if (-not $pnpmPath) {
        Write-Output 'FAIL 没有 pnpm，无法安装'
        exit 2
    }
    Write-Output '>>> pnpm add -D @midscene/test @midscene/web playwright'
    $add = Invoke-Native $pnpmPath @('add', '-D', '@midscene/test', '@midscene/web', 'playwright') $RunnerDir
    $add.Output | ForEach-Object { Write-Output $_ }
    if ($add.Code -ne 0) { $installFailed = $true }

    if (-not $installFailed -and -not $SkipPlaywright) {
        Write-Output '>>> pnpm exec playwright install chromium'
        $pw = Invoke-Native $pnpmPath @('exec', 'playwright', 'install', 'chromium') $RunnerDir
        $pw.Output | ForEach-Object { Write-Output $_ }
        if ($pw.Code -ne 0) { $installFailed = $true }
    }

    if (-not $installFailed) {
        $specPath = Join-Path $RunnerDir 'node-spec.md'
        Write-Output '>>> pnpm exec midscene-test nodes --config ./templates/midscene.config.ts --project web'
        $spec = Invoke-Native $pnpmPath @(
            'exec', 'midscene-test', 'nodes',
            '--config', './templates/midscene.config.ts',
            '--project', 'web'
        ) $RunnerDir
        if ($spec.Code -eq 0) {
            Write-Utf8 $specPath (($spec.Output -join "`n") + "`n")
            Write-Output "OK   node-spec.md：$specPath"
        } else {
            $spec.Output | ForEach-Object { Write-Output $_ }
            Write-Output 'FAIL 生成 node-spec.md 失败'
            $installFailed = $true
        }
    }
    if (-not $installFailed) {
        $missing = @($missing | Where-Object { $_ -ne '@midscene/test' -and $_ -ne 'Chromium' })
        $midsceneInstalled = $true
    }
}

# ---------- 模型连通性 ----------
if (-not $installFailed -and $ModelVerify) {
    if (-not $pnpmPath -or -not $midsceneInstalled) {
        Write-Output 'FAIL 依赖未就绪，无法验证模型'
        exit 2
    }
    Write-Output '>>> pnpm exec midscene-test model verify'
    $verify = Invoke-Native $pnpmPath @('exec', 'midscene-test', 'model', 'verify') $RunnerDir
    $verify.Output | ForEach-Object { Write-Output $_ }
    if ($verify.Code -ne 0) {
        Write-Output 'FAIL 模型连通性检查未通过'
        exit 1
    }
}

Write-Output ''
if ($installFailed) {
    Write-Output 'FAIL 安装过程出错'
    exit 1
}
if ($missing.Count -gt 0) {
    if ($CheckOnly) {
        Write-Output ('未就绪：' + ($missing -join '、'))
        exit 2
    }
    Write-Output ('仍缺：' + ($missing -join '、'))
    exit 2
}
Write-Output "就绪：$RunnerDir"
exit 0
