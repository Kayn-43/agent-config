#Requires -Version 5.1
<#
.SYNOPSIS
    诊断技能或 agent 为什么在客户端里看不到。

.DESCRIPTION
    报告内容：各路径是否存在；每个已安装条目的链接类型与目标；本应是链接却是
    **真实目录**的条目（它们会失同步）；目标已从仓库删除的悬空链接；两个规则
    文件是否分叉；本机主机配置；以及 GitHub 代理可达性。

    只读，不改动任何东西。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
#>
[CmdletBinding()]
param(
    [string] $Proxy
)

$ErrorActionPreference = 'Continue'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$CodexHome  = Join-Path $HOME '.codex'
$ZcodeHome  = Join-Path $HOME '.zcode'
$ClaudeHome = Join-Path $HOME '.claude'

function Write-Head { param([string] $Text) Write-Host ''; Write-Host ('=' * 62); Write-Host $Text; Write-Host ('=' * 62) }

$problems = New-Object System.Collections.ArrayList
function Add-Problem { param([string] $Text) [void]$problems.Add($Text) }

# ---------------------------------------------------------------- paths

Write-Head '路径'

$checks = @(
    @{ Name = 'repo root'          ; Path = $RepoRoot },
    @{ Name = 'repo skills'        ; Path = (Join-Path $RepoRoot 'skills') },
    @{ Name = 'codex home'         ; Path = $CodexHome },
    @{ Name = 'codex skills'       ; Path = (Join-Path $CodexHome 'skills') },
    @{ Name = 'codex agents'       ; Path = (Join-Path $CodexHome 'agents') },
    @{ Name = 'zcode home'         ; Path = $ZcodeHome },
    @{ Name = 'zcode skills'       ; Path = (Join-Path $ZcodeHome 'skills') },
    @{ Name = 'zcode agents'       ; Path = (Join-Path $ZcodeHome 'agents') },
    @{ Name = 'claude home'        ; Path = $ClaudeHome },
    @{ Name = 'claude skills'      ; Path = (Join-Path $ClaudeHome 'skills') },
    @{ Name = 'claude agents'      ; Path = (Join-Path $ClaudeHome 'agents') },
    @{ Name = 'codex AGENTS.md'    ; Path = (Join-Path $CodexHome 'AGENTS.md') },
    @{ Name = 'zcode AGENTS.md'    ; Path = (Join-Path $ZcodeHome 'AGENTS.md') },
    @{ Name = 'claude CLAUDE.md'   ; Path = (Join-Path $ClaudeHome 'CLAUDE.md') },
    @{ Name = 'local/hosts.yaml'   ; Path = (Join-Path $RepoRoot 'local\hosts.yaml') }
)

foreach ($c in $checks) {
    if (Test-Path -LiteralPath $c.Path) {
        Write-Host ("  [OK]   {0,-18} {1}" -f $c.Name, $c.Path) -ForegroundColor Green
    }
    else {
        Write-Host ("  [MISS] {0,-18} {1}" -f $c.Name, $c.Path) -ForegroundColor Yellow
        if ($c.Name -eq 'local/hosts.yaml') {
            Write-Host "         把 local/hosts.example.yaml 复制为 local/hosts.yaml 并填入真实值"
        }
        else {
            Add-Problem "缺失：$($c.Name) 于 $($c.Path)"
        }
    }
}

# ---------------------------------------------------------------- link inventory

function Show-Links {
    param([string] $Title, [string] $Path, [string] $RepoPath)

    Write-Head $Title
    if (-not (Test-Path -LiteralPath $Path)) { Write-Host '  （目录不存在）'; return }

    $entries = @(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name)
    if ($entries.Count -eq 0) { Write-Host '  （空）'; return }

    $rows = foreach ($e in $entries) {
        $type = if ($e.LinkType) { $e.LinkType } else { 'REAL' }
        $target = if ($e.Target) { ($e.Target -join ',') } else { '' }
        [pscustomobject]@{
            Name   = $e.Name
            Type   = $type
            Target = $target
        }
    }
    $rows | Format-Table -AutoSize

    foreach ($e in $entries) {
        $pointsIn = $false
        if ($e.Target) {
            $t = ($e.Target -join ',') -replace '/', '\'
            $r = $RepoPath -replace '/', '\'
            $pointsIn = $t.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
        }

        if (-not $e.LinkType) {
            # 本应是链接、却是真实内容：它会静默失同步。
            if ($e.Name -in @('common','research','remote') -or (Test-Path -LiteralPath (Join-Path $RepoPath (Join-Path 'skills' $e.Name)))) {
                Add-Problem "真实目录（不是链接，会失同步）：$($e.FullName)"
            }
            continue
        }

        if ($pointsIn) {
            $target = ($e.Target -join ',')
            if (-not (Test-Path -LiteralPath $target)) {
                Add-Problem "悬空链接（目标已不存在）：$($e.FullName) -> $target"
            }
        }
    }
}

Show-Links -Title 'Codex 技能'  -Path (Join-Path $CodexHome  'skills') -RepoPath (Join-Path $RepoRoot 'skills')
Show-Links -Title 'Codex 子 agent'  -Path (Join-Path $CodexHome  'agents') -RepoPath (Join-Path $RepoRoot 'agents')
Show-Links -Title 'ZCode 技能'  -Path (Join-Path $ZcodeHome  'skills') -RepoPath (Join-Path $RepoRoot 'skills')
Show-Links -Title 'ZCode 子 agent'  -Path (Join-Path $ZcodeHome  'agents') -RepoPath (Join-Path $RepoRoot 'agents')
Show-Links -Title 'Claude 技能' -Path (Join-Path $ClaudeHome 'skills') -RepoPath (Join-Path $RepoRoot 'skills')
Show-Links -Title 'Claude 子 agent' -Path (Join-Path $ClaudeHome 'agents') -RepoPath (Join-Path $RepoRoot 'agents')

# ---------------------------------------------------------------- rule drift

Write-Head '规则文件一致性'

$a = Join-Path $RepoRoot 'rules\AGENTS.md'
$c = Join-Path $RepoRoot 'rules\CLAUDE.md'
if ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $c)) {
    $ha = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
    $hc = (Get-FileHash -LiteralPath $c -Algorithm SHA256).Hash
    if ($ha -eq $hc) {
        Write-Host '  [OK]   AGENTS.md 与 CLAUDE.md 内容一致' -ForegroundColor Green
    }
    else {
        # 这两份文件是刻意分开的（两个客户端读的文件名不同），
        # 所以它们可能在无人察觉的情况下分叉。
        Write-Host '  [WARN] AGENTS.md 与 CLAUDE.md 内容不一致' -ForegroundColor Yellow
        Write-Host "         $a"
        Write-Host "         $c"
        Add-Problem 'rules/AGENTS.md 与 rules/CLAUDE.md 已分叉'
    }
}
else {
    Add-Problem '其中一个规则文件缺失'
}

# ---------------------------------------------------------------- freshness

Write-Head '链接内容新鲜度'

# 硬链接会在编辑器替换仓库文件时**静默失效**：仓库得到新 inode，而每个既有链接
# 仍指向旧 inode，客户端那份继续提供陈旧内容，同时 LinkType 依然报 HardLink。
# 所以链接类型在这里什么都证明不了——必须比对内容。
$pairs = @(
    @{ Home = (Join-Path $CodexHome  'AGENTS.md'); Source = (Join-Path $RepoRoot 'rules\AGENTS.md') },
    @{ Home = (Join-Path $ZcodeHome  'AGENTS.md'); Source = (Join-Path $RepoRoot 'rules\AGENTS.md') },
    @{ Home = (Join-Path $ClaudeHome 'CLAUDE.md'); Source = (Join-Path $RepoRoot 'rules\CLAUDE.md') }
)

foreach ($d in @(
    @{ Dir = (Join-Path $CodexHome  'agents'); Src = (Join-Path $RepoRoot 'agents') },
    @{ Dir = (Join-Path $ZcodeHome  'agents'); Src = (Join-Path $RepoRoot 'agents') },
    @{ Dir = (Join-Path $ClaudeHome 'agents'); Src = (Join-Path $RepoRoot 'agents') }
)) {
    if (-not (Test-Path -LiteralPath $d.Dir)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $d.Dir -File -Force -ErrorAction SilentlyContinue)) {
        $pairs += @{ Home = $f.FullName; Source = (Join-Path $d.Src $f.Name) }
    }
}

$staleLinks = 0
$localVariants = 0
foreach ($p in $pairs) {
    if (-not (Test-Path -LiteralPath $p.Home   -PathType Leaf)) { continue }
    if (-not (Test-Path -LiteralPath $p.Source -PathType Leaf)) { continue }

    $homeHash = (Get-FileHash -LiteralPath $p.Home   -Algorithm SHA256).Hash
    $repoHash = (Get-FileHash -LiteralPath $p.Source -Algorithm SHA256).Hash
    if ($homeHash -eq $repoHash) { continue }

    $item = Get-Item -LiteralPath $p.Home -Force
    if ($item.LinkType) {
        $staleLinks++
        Write-Host "  [STALE] $($p.Home)" -ForegroundColor Red
        Write-Host "          类型是 $($item.LinkType)，但内容与仓库副本不一致"
        Add-Problem "陈旧 $($item.LinkType)：$($p.Home) 与 $($p.Source) 不一致"
    }
    else {
        $localVariants++
        Write-Host "  [local] $($p.Home)" -ForegroundColor DarkGray
        Write-Host '          真实文件，与仓库副本不同——属预期的本机变体'
    }
}

if ($staleLinks -eq 0 -and $localVariants -eq 0) {
    Write-Host '  [OK]   所有规则/agent 文件都与仓库源一致' -ForegroundColor Green
}
if ($staleLinks -gt 0) {
    Write-Host ''
    Write-Host '  陈旧链接会提供过期内容。修法：删掉客户端目录下那份，再跑' -ForegroundColor Yellow
    Write-Host '  scripts\install.ps1 重新链接。（本仓库真实遇到过：两个规则文件被翻译后，' -ForegroundColor Yellow
    Write-Host '  既有的硬链接仍保留着旧文本。）' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- repo state

Write-Head '仓库状态'

if (Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) {
    $branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>&1) -join ''
    $dirty  = @(& git -C $RepoRoot status --porcelain 2>&1)
    Write-Host "  分支   : $branch"
    if ($dirty.Count -eq 0) {
        Write-Host '  [OK]   工作区干净' -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] 有 $($dirty.Count) 处未提交改动" -ForegroundColor Yellow
        $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "         $_" }
    }
    $remote = (& git -C $RepoRoot remote get-url origin 2>&1) -join ''
    Write-Host "  远端   : $remote"

    # 防止把仅属于本机的值误提交进仓库。
    $tracked = @(& git -C $RepoRoot ls-files 2>&1)
    $leaks = $tracked | Where-Object { $_ -match '^local/' -and $_ -notmatch 'hosts\.example\.yaml$' }
    if ($leaks.Count -gt 0) {
        Write-Host '  [FAIL] local/ 下的文件被 git 跟踪了：' -ForegroundColor Red
        $leaks | ForEach-Object { Write-Host "         $_" }
        Add-Problem '机器相关的 local/ 文件被 git 跟踪'
    }
    else {
        Write-Host '  [OK]   没有 local/ 文件被跟踪' -ForegroundColor Green
    }
}
else {
    Write-Host '  （不是 git 仓库）'
    Add-Problem '仓库根目录不是 git 仓库'
}

# ---------------------------------------------------------------- environment

Write-Head '环境'

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) { Write-Host "  [OK]   已安装 pwsh：$($pwsh.Source)" -ForegroundColor Green }
else { Write-Host '  [warn] 未找到 pwsh（PowerShell 7）；脚本回落到 5.1 规则' -ForegroundColor Yellow }

# WindowsApps 下的 python 是桩程序，会打印错误但退出码为 0，所以要检查输出。
$python = $null
foreach ($c in @(
    (Join-Path $HOME 'anaconda3\python.exe'),
    (Join-Path $HOME 'miniconda3\python.exe'),
    'C:\ProgramData\anaconda3\python.exe',
    'E:\anaconda3\python.exe',
    'D:\anaconda3\python.exe'
)) {
    if ($c -match 'WindowsApps') { continue }
    if (-not (Test-Path -LiteralPath $c)) { continue }
    $out = & $c '--version' 2>&1
    if (($out -join ' ') -match 'Python\s+3\.') { $python = $c; break }
}
if ($python) { Write-Host "  [OK]   真实 Python：$python" -ForegroundColor Green }
else { Write-Host '  [warn] 未找到真实 Python（仅 -WithUpstream 需要）' -ForegroundColor Yellow }

$effective = Get-ExecutionPolicy
Write-Host "  执行策略：$effective"
if ($effective -eq 'Restricted') {
    Write-Host '         裸写 .\script.ps1 会被拒绝，请改用：' -ForegroundColor Yellow
    Write-Host '         powershell -ExecutionPolicy Bypass -File <full path>'
}

if (-not $Proxy) {
    $hostsFile = Join-Path $RepoRoot 'local\hosts.yaml'
    if (Test-Path -LiteralPath $hostsFile) {
        $m = Select-String -LiteralPath $hostsFile -Pattern 'default_proxy:\s*"?([^"\s]+)"?' | Select-Object -First 1
        if ($m) { $Proxy = $m.Matches[0].Groups[1].Value }
    }
}
if ($Proxy) {
    try {
        $probe = Join-Path ([System.IO.Path]::GetTempPath()) ('doctor-probe-' + [guid]::NewGuid().ToString('N'))
        Invoke-WebRequest -Uri 'https://github.com' -Proxy $Proxy -TimeoutSec 15 -UseBasicParsing -OutFile $probe
        Write-Host "  [OK]   代理可达：$Proxy" -ForegroundColor Green
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        Write-Host "  [warn] 代理探测失败：$Proxy" -ForegroundColor Yellow
    }
}
else {
    Write-Host '  代理：未配置（除非本机访问 GitHub 受阻，否则无妨）'
}

# ---------------------------------------------------------------- 架构边界

Write-Head '架构边界（三层结构）'

$PrivateRoot = Join-Path $HOME 'agent-config-private'
$AgentLocal  = Join-Path $HOME '.agent-local'

function Add-Fail {
    param([string] $Text)
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
    Add-Problem $Text
}

# --- 允许在 .codex/skills 下以真实目录存在的名字 -----------------------------
# 客户端目录只是消费者。原创内容必须来自 Git 仓库，不能直接写在客户端目录里。
$allowedReal = @('.system')
$upstreamFile = Join-Path $RepoRoot 'upstream.json'
if (Test-Path -LiteralPath $upstreamFile -PathType Leaf) {
    $allowedReal += @(
        (Get-Content -LiteralPath $upstreamFile -Raw -Encoding utf8 | ConvertFrom-Json).skills |
            ForEach-Object { $_.name }
    )
}

$consumerRoots = @(
    @{ Root = (Join-Path $CodexHome  'skills'); Allowed = $allowedReal },
    @{ Root = (Join-Path $ZcodeHome  'skills'); Allowed = @() },
    @{ Root = (Join-Path $ClaudeHome 'skills'); Allowed = @() }
)

foreach ($c in $consumerRoots) {
    if (-not (Test-Path -LiteralPath $c.Root)) { continue }
    $real = @(Get-ChildItem -LiteralPath $c.Root -Force | Where-Object { -not $_.LinkType })
    if ($real.Count -eq 0) {
        Write-Host "  [ok]   $($c.Root) : 无真实技能目录" -ForegroundColor Green
        continue
    }
    foreach ($e in $real) {
        if ($c.Allowed -contains $e.Name) {
            Write-Host "  [ok]   $($c.Root) : $($e.Name)（声明过的真实目录）" -ForegroundColor Green
        }
        else {
            Add-Fail "FAIL: unmanaged real skill detected -> $($e.FullName)"
        }
    }
}

# --- 仓库里不得出现机器身份 / 凭据文件 ---------------------------------------
$forbiddenRegex = '^(hosts\.yaml|hosts\..*\.yaml|askpass.*|.*\.key|.*\.pem|.*\.secret|\.env|\.env\..*)$'

$repoRoots = @($RepoRoot)
if (Test-Path -LiteralPath $PrivateRoot) { $repoRoots += $PrivateRoot }

foreach ($root in $repoRoots) {
    $label = Split-Path -Leaf $root

    # 工作区里的文件（按文件名判断——技能正文里会提到 hosts.yaml，所以不能按内容判断）
    $hits = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -match $forbiddenRegex }
    )
    foreach ($h in $hits) {
        Add-Fail "FAIL: credential-shaped file in ${label}: $($h.FullName)"
    }

    # 已跟踪的文件（防止历史上提交过、现在被 gitignore 掩盖）
    if (Test-Path -LiteralPath (Join-Path $root '.git')) {
        $bad = @(& git -C $root ls-files 2>&1 | Where-Object { (Split-Path -Leaf $_) -match $forbiddenRegex })
        foreach ($b in $bad) {
            Add-Fail "FAIL: credential-shaped file TRACKED in ${label}: $b"
        }

        # 私钥内容的最后一道闸（很低的误报率）
        foreach ($rel in @(& git -C $root ls-files 2>&1)) {
            $p = Join-Path $root $rel
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            if ((Get-Item -LiteralPath $p).Length -gt 2MB) { continue }
            $text = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            if ($text -match 'BEGIN [A-Z ]*PRIVATE KEY') {
                Add-Fail "FAIL: private key material in ${label}: $rel"
            }
        }
    }
    else {
        Add-Fail "FAIL: not a git repository -> $root"
    }
}

# --- ~/.agent-local 必须与 Git 彻底隔离 --------------------------------------
if (-not (Test-Path -LiteralPath $AgentLocal)) {
    Write-Host '  [warn] ~/.agent-local 不存在（新机器需先恢复它）' -ForegroundColor Yellow
}
else {
    if ((Get-Item -LiteralPath $AgentLocal -Force).LinkType) {
        Add-Fail "FAIL: ~/.agent-local itself is a link: $AgentLocal"
    }
    if (Test-Path -LiteralPath (Join-Path $AgentLocal '.git')) {
        Add-Fail "FAIL: ~/.agent-local contains a .git directory"
    }
    $backLinks = @(
        Get-ChildItem -LiteralPath $AgentLocal -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LinkType }
    )
    foreach ($b in $backLinks) {
        $t = ($b.Target -join ',')
        if ((Test-PointsIntoRepo -Target $t -RepoPath $RepoRoot) -or
            ($PrivateRoot -and (Test-PointsIntoRepo -Target $t -RepoPath $PrivateRoot))) {
            Add-Fail "FAIL: ~/.agent-local contains a link back into a Git repo: $($b.FullName)"
        }
    }
    Write-Host "  [ok]   ~/.agent-local : 与 Git 仓库隔离（检查了 $((@(Get-ChildItem -LiteralPath $AgentLocal -Force)).Count) 个顶层条目）" -ForegroundColor Green
}

# --- 两个仓库必须 clean ------------------------------------------------------
foreach ($root in $repoRoots) {
    $label = Split-Path -Leaf $root
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { continue }
    $dirty = @(& git -C $root status --porcelain 2>&1)
    if ($dirty.Count -eq 0) {
        Write-Host "  [ok]   ${label} : 工作区干净" -ForegroundColor Green
    }
    else {
        Add-Fail "FAIL: ${label} has $($dirty.Count) uncommitted change(s)"
    }
}

# ---------------------------------------------------------------- verdict

Write-Head '结论'
if ($problems.Count -eq 0) {
    Write-Host '  未发现问题。' -ForegroundColor Green
}
else {
    Write-Host "  发现 $($problems.Count) 个问题：" -ForegroundColor Yellow
    foreach ($p in $problems) { Write-Host "    - $p" }
    Write-Host ''
    Write-Host '  提示：重跑 scripts\install.ps1 可重建缺失的链接并清理悬空链接。'
}
