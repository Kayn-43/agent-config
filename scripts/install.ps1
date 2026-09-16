#Requires -Version 5.1
<#
.SYNOPSIS
    把本仓库的技能、agents 和规则链接进各 agent 客户端的目录。

.DESCRIPTION
    内容只做“链接”，绝不拷贝，因此改一处即到处生效，不会出现副本失同步。
    关于为何使用 junction 与硬链接而不是符号链接，见 README.md。

    目录 -> 目录联接（Junction）      （不需要管理员权限）
    文件 -> 硬链接，失败时退回复制   （不需要管理员权限）

    同时清理指向本仓库、但源已被删除的条目——它们会永远残留，让技能列表谎报
    实际存在的内容。不指向本仓库的条目绝不触碰。

.PARAMETER DryRun
    只报告将要发生什么，不改动任何东西。

.PARAMETER WithUpstream
    同时安装/刷新 upstream.json 中记录的第三方技能。

.PARAMETER Proxy
    用于上游安装的 HTTP 代理，例如 http://127.0.0.1:7897。

.PARAMETER Exclude
    本次运行额外跳过的技能名。持久化的跳过列表在 disabled.json——优先用那个，
    因为 update.ps1 会重跑本脚本，一次性的参数会被遗忘。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -WithUpstream -Proxy http://127.0.0.1:7897
#>
[CmdletBinding()]
param(
    [switch] $DryRun,
    [switch] $WithUpstream,
    [string] $Proxy,

    # Additional skill names to skip for this run. The persistent list lives in
    # disabled.json; prefer that, because update.ps1 re-runs this script and a
    # one-off flag would be forgotten.
    # 额外的技能仓库根目录（例如私有仓库 ~/agent-config-private）。其 skills/ 下的技能
    # 会一并链接到三个客户端根。默认自动探测 ~/agent-config-private。
    [string[]] $ExtraRepo,
    [switch] $SkipPrivate
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths

$RepoRoot = Split-Path -Parent $PSScriptRoot

$CodexHome  = Join-Path $HOME '.codex'
$ZcodeHome  = Join-Path $HOME '.zcode'
$ClaudeHome = Join-Path $HOME '.claude'

$CodexSkills  = Join-Path $CodexHome  'skills'
$CodexAgents  = Join-Path $CodexHome  'agents'
$ZcodeSkills  = Join-Path $ZcodeHome  'skills'
$ZcodeAgents  = Join-Path $ZcodeHome  'agents'
$ClaudeSkills = Join-Path $ClaudeHome 'skills'
$ClaudeAgents = Join-Path $ClaudeHome 'agents'

$SkillGroups = @('common', 'research', 'remote')

# ---------------------------------------------------------------- 额外仓库

# 默认自动探测私有仓库：通用知识在 public，项目知识在 private，两者都链接。
if (-not $SkipPrivate) {
    $defaultPrivate = Join-Path $HOME 'agent-config-private'
    if ((Test-Path -LiteralPath $defaultPrivate) -and ($ExtraRepo -notcontains $defaultPrivate)) {
        $ExtraRepo = @($ExtraRepo) + $defaultPrivate
    }
}

# ---------------------------------------------------------------- disabled skills

# 仓库里存在、但本机不得建立链接的技能。
# 每次运行都从 disabled.json 读取，因此该决定能延续到 update.ps1。
$script:Disabled = @{}
$script:DisabledReason = @{}

$disabledFile = Join-Path $RepoRoot 'disabled.json'
if (Test-Path -LiteralPath $disabledFile -PathType Leaf) {
    try {
        $disabledDoc = Get-Content -LiteralPath $disabledFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($d in $disabledDoc.skills) {
            $script:Disabled[$d.name] = $true
            $script:DisabledReason[$d.name] = $d.reason
        }
    }
    catch {
        Warn "无法解析 disabled.json : $($_.Exception.Message)"
    }
}
if ($Exclude) {
    foreach ($n in $Exclude) {
        $script:Disabled[$n] = $true
        $script:DisabledReason[$n] = 'excluded via -Exclude (this run only)'
    }
}

# ---------------------------------------------------------------- helpers

function Write-Head { param([string] $Text) Write-Host ''; Write-Host ('=' * 62); Write-Host $Text; Write-Host ('=' * 62) }
function Info { param([string] $Text) Write-Host "  $Text" }
function Ok   { param([string] $Text) Write-Host "  [ok]    $Text" -ForegroundColor Green }
function Skip { param([string] $Text) Write-Host "  [skip]  $Text" -ForegroundColor DarkGray }
function Warn { param([string] $Text) Write-Host "  [warn]  $Text" -ForegroundColor Yellow }
function Prune{ param([string] $Text) Write-Host "  [prune] $Text" -ForegroundColor Magenta }
function Dry  { param([string] $Text) Write-Host "  [dry]   $Text" -ForegroundColor Cyan }
function Off  { param([string] $Text) Write-Host "  [off]   $Text" -ForegroundColor DarkYellow }

# 按 UTF-8 **无 BOM** 读写文本。Windows PowerShell 5.1 的 `-Encoding utf8` 会写 BOM，
# 而 agent/skill 文件的 frontmatter 对 BOM 敏感，所以直接用 .NET API。
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextFile {
    param([string] $Path, [string] $Text)
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Ensure-Directory {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) { return }
    if ($DryRun) { Dry "将创建 $Path"; return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Ok "已创建 $Path"
}

# 目标已不存在的 junction（或任何链接）仍会出现在技能列表里。
# 因此只处理指向本仓库的条目。
function Test-PointsIntoRepo {
    param([string] $Target, [string] $RepoPath)
    if (-not $Target) { return $false }
    $t = $Target -replace '/', '\'
    $r = $RepoPath -replace '/', '\'
    return $t.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------- skill links

function Install-SkillGroup {
    param([string] $Group, [string[]] $Destinations, [string] $RepoPath)

    $groupDir = Join-Path $RepoPath (Join-Path 'skills' $Group)
    if (-not (Test-Path -LiteralPath $groupDir)) { return }

    $skills = @(Get-ChildItem -LiteralPath $groupDir -Directory | Sort-Object Name)
    if ($skills.Count -eq 0) { return }

    Info "$Group/ : $($skills.Count) 个技能"

    foreach ($skill in $skills) {
        if ($script:Disabled.ContainsKey($skill.Name)) { continue }
        foreach ($dest in $Destinations) {
            $link = Join-Path $dest $skill.Name

            if (Test-Path -LiteralPath $link) {
                $existing = Get-Item -LiteralPath $link -Force
                if ($existing.LinkType) {
                    Skip "$link"
                    continue
                }
                # 这里是真实目录，说明某处把它复制了而不是建立链接。
                Warn "$link 是真实目录而不是链接——它会失同步。"
                Warn "       请手动删除后重跑（本脚本绝不删除真实目录）。"
                continue
            }

            if ($DryRun) { Dry "将建立 junction $link -> $($skill.FullName)"; continue }

            $linkParams = @{
                ItemType = 'Junction'
                Path     = $link
                Target   = $skill.FullName
            }
            try {
                New-Item @linkParams | Out-Null
                Ok "junction $($skill.Name) -> $Group/"
            }
            catch {
                Warn "junction 创建失败：$link : $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------- agent 模型绑定

# ~/.agent-local/agent-models.json 里的模型绑定（机器相关，永不入 Git）。
# 有绑定的 agent **不能用硬链接**：硬链接操作的是同一个 inode，改写客户端那份等于
# 改写 Git 仓库里的定义，绑定就会混进版本控制。因此这类 agent 生成
# "仓库定义 + 注入一行 model:" 的副本，每次运行都重新生成，所以不会漂移。
$script:AgentModels = @{}
$agentModelsFile = Join-Path $HOME '.agent-local\agent-models.json'
if (Test-Path -LiteralPath $agentModelsFile -PathType Leaf) {
    try {
        $doc = Get-Content -LiteralPath $agentModelsFile -Raw -Encoding utf8 | ConvertFrom-Json
        if ($doc.agents) {
            foreach ($p in $doc.agents.PSObject.Properties) { $script:AgentModels[$p.Name] = $p.Value }
        }
    }
    catch {
        Warn "无法解析 agent-models.json : $($_.Exception.Message)"
    }
}

function New-AgentWithModel {
    param([string] $Source, [string] $Destination, [string] $Model)

    $lines = [System.IO.File]::ReadAllLines($Source, [System.Text.Encoding]::UTF8)
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw "agent 文件缺少 frontmatter：$Source"
    }

    $out = New-Object System.Collections.ArrayList
    [void]$out.Add($lines[0])
    $closed = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if (-not $closed -and $lines[$i].Trim() -eq '---') {
            [void]$out.Add('model: "' + $Model + '"')
            [void]$out.Add($lines[$i])
            $closed = $true
            continue
        }
        [void]$out.Add($lines[$i])
    }
    if (-not $closed) { throw "agent 文件 frontmatter 未闭合：$Source" }

    # 必须先删除目标再写：若目标当前是硬链接，直接写会穿透链接改掉仓库源文件。
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
    Write-TextFile -Path $Destination -Text (($out -join "`n") + "`n")
}

# ---------------------------------------------------------------- file links

function Install-FileLink {
    param([string] $Source, [string] $Destination)

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }

    if (Test-Path -LiteralPath $Destination) {
        $existing = Get-Item -LiteralPath $Destination -Force
        if ($existing.LinkType) { Skip "$Destination"; return }
        Warn "$Destination 是真实文件而非链接——已跳过。"
        return
    }

    if ($DryRun) { Dry "将建立硬链接 $Destination -> $Source"; return }

    # 与符号链接不同，硬链接不需要管理员权限。
    try {
        $linkParams = @{
            ItemType = 'HardLink'
            Path     = $Destination
            Target   = $Source
        }
        New-Item @linkParams | Out-Null
        Ok "hard link $Destination"
    }
    catch {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        Warn "硬链接不可用，已改为复制：$Destination"
        Warn "       该副本不会跟随仓库的改动。"
    }
}

function Install-AgentFiles {
    param([string] $RepoPath, [string] $Destination)

    $agentDir = Join-Path $RepoPath 'agents'
    if (-not (Test-Path -LiteralPath $agentDir)) { return }

    foreach ($agent in (Get-ChildItem -LiteralPath $agentDir -Filter '*.md' | Sort-Object Name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($agent.Name)
        $dest = Join-Path $Destination $agent.Name

        if ($script:AgentModels.ContainsKey($name)) {
            # 派生文件，每次重新生成；不做"已存在就跳过"的保护。
            if ($DryRun) { Dry "将生成（注入 model）$dest"; continue }
            try {
                New-AgentWithModel -Source $agent.FullName -Destination $dest -Model $script:AgentModels[$name]
                Ok "生成 $($agent.Name)（已注入 model）"
            }
            catch {
                Warn "生成失败：$dest : $($_.Exception.Message)"
            }
            continue
        }

        Install-FileLink -Source $agent.FullName -Destination $dest
    }
}

# 链接一个"额外仓库"的技能。支持两种布局：
#   skills/<name>/              扁平
#   skills/<group>/<name>/      分组
function Install-ExtraRepo {
    param([string] $Root, [string[]] $Destinations)

    $skillsRoot = Join-Path $Root 'skills'
    if (-not (Test-Path -LiteralPath $skillsRoot)) { return }

    $candidates = New-Object System.Collections.ArrayList
    foreach ($child in (Get-ChildItem -LiteralPath $skillsRoot -Directory | Sort-Object Name)) {
        if (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md')) {
            [void]$candidates.Add($child)
        }
        else {
            foreach ($g in (Get-ChildItem -LiteralPath $child.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                if (Test-Path -LiteralPath (Join-Path $g.FullName 'SKILL.md')) { [void]$candidates.Add($g) }
            }
        }
    }

    $label = Split-Path -Leaf $Root
    Info "$label : $($candidates.Count) 个技能"

    foreach ($skill in $candidates) {
        if ($script:Disabled.ContainsKey($skill.Name)) { continue }
        foreach ($dest in $Destinations) {
            $link = Join-Path $dest $skill.Name
            if (Test-Path -LiteralPath $link) { Skip "$link"; continue }
            if ($DryRun) { Dry "将建立 junction $link -> $($skill.FullName)"; continue }
            $lp = @{ ItemType = 'Junction'; Path = $link; Target = $skill.FullName }
            try {
                New-Item @lp | Out-Null
                Ok "junction $($skill.Name) <- $label"
            }
            catch {
                Warn "junction 创建失败：$link : $($_.Exception.Message)"
            }
        }
    }
}

# 上游技能：规范副本在 .codex（由 skill-installer 安装），另两个根链接过去。
# 这一步只建链接，不重装——重装由 -WithUpstream 负责。
# 少了这一步，.claude / .zcode 会看不到上游技能（曾经的真实情况）。
$upstreamFile = Join-Path $RepoRoot 'upstream.json'
if (Test-Path -LiteralPath $upstreamFile -PathType Leaf) {
    $upstreamNames = @(
        (Get-Content -LiteralPath $upstreamFile -Raw -Encoding utf8 | ConvertFrom-Json).skills |
            ForEach-Object { $_.name }
    )

    Write-Head '上游技能 -> 另两个客户端根'
    foreach ($name in $upstreamNames) {
        $canonical = Join-Path $CodexSkills $name
        if (-not (Test-Path -LiteralPath $canonical -PathType Container)) {
            Warn "$name : 规范副本不在 $CodexSkills —— 跳过（用 -WithUpstream 安装）"
            continue
        }
        foreach ($otherRoot in @($ZcodeSkills, $ClaudeSkills)) {
            $link = Join-Path $otherRoot $name
            if (Test-Path -LiteralPath $link) { Skip "$link"; continue }
            if ($DryRun) { Dry "将建立 junction $link -> $canonical"; continue }
            $lp = @{ ItemType = 'Junction'; Path = $link; Target = $canonical }
            try {
                New-Item @lp | Out-Null
                Ok "junction $name <- .codex"
            }
            catch {
                Warn "junction 创建失败：$link : $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------- prune

function Remove-DanglingLinks {
    param([string] $Destination, [string] $RepoPath)

    if (-not (Test-Path -LiteralPath $Destination)) { return }

    foreach ($entry in (Get-ChildItem -LiteralPath $Destination -Force)) {
        if (-not $entry.LinkType) { continue }
        if (-not (Test-PointsIntoRepo -Target $entry.Target -RepoPath $RepoPath)) { continue }

        $targetPath = $entry.Target
        if ([string]::IsNullOrWhiteSpace($targetPath)) { $targetPath = $entry.FullName }

        if (Test-Path -LiteralPath $targetPath) { continue }

        if ($DryRun) { Dry "would prune dangling link $($entry.FullName)"; continue }
        Remove-Item -LiteralPath $entry.FullName -Force
        Prune "$($entry.Name)  (target gone: $targetPath)"
    }
}

# ---------------------------------------------------------------- main

Write-Head 'agent-config 安装器'
Info "仓库       : $RepoRoot"
Info "codex 目录 : $CodexHome"
Info "zcode 目录 : $ZcodeHome"
Info "claude 目录: $ClaudeHome"
Info "仅报告     : $($DryRun.IsPresent)"

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'skills'))) {
    throw "这不是 agent-config 仓库（$RepoRoot 下没有 skills/）"
}

Write-Head '目录'
foreach ($d in @($CodexHome, $CodexSkills, $CodexAgents, $ZcodeHome, $ZcodeSkills, $ZcodeAgents, $ClaudeHome, $ClaudeSkills, $ClaudeAgents)) {
    Ensure-Directory -Path $d
}

if ($script:Disabled.Count -gt 0) {
    Write-Head '已禁用的技能（仓库中存在，刻意不建立链接）'
    foreach ($n in ($script:Disabled.Keys | Sort-Object)) {
        Off "$n"
        Info "      $($script:DisabledReason[$n])"
    }
    Info '编辑 disabled.json 后重跑即可启用。'
}

Write-Head '技能 -> Codex'
foreach ($g in $SkillGroups) { Install-SkillGroup -Group $g -Destinations @($CodexSkills) -RepoPath $RepoRoot }

Write-Head '技能 -> ZCode'
foreach ($g in $SkillGroups) { Install-SkillGroup -Group $g -Destinations @($ZcodeSkills) -RepoPath $RepoRoot }

Write-Head '技能 -> Claude'
foreach ($g in $SkillGroups) { Install-SkillGroup -Group $g -Destinations @($ClaudeSkills) -RepoPath $RepoRoot }

if ($ExtraRepo) {
    foreach ($r in $ExtraRepo) {
        if (Test-Path -LiteralPath $r) {
            Write-Head "额外仓库 -> 三个客户端根 : $r"
            Install-ExtraRepo -Root $r -Destinations @($CodexSkills, $ZcodeSkills, $ClaudeSkills)
        }
        else {
            Warn "额外仓库不存在，跳过：$r"
        }
    }
}

Write-Head '子 agent'
Install-AgentFiles -RepoPath $RepoRoot -Destination $CodexAgents
Install-AgentFiles -RepoPath $RepoRoot -Destination $ZcodeAgents
Install-AgentFiles -RepoPath $RepoRoot -Destination $ClaudeAgents

Write-Head '规则'
Install-FileLink -Source (Join-Path $RepoRoot 'rules\AGENTS.md') -Destination (Join-Path $CodexHome  'AGENTS.md')
Install-FileLink -Source (Join-Path $RepoRoot 'rules\AGENTS.md') -Destination (Join-Path $ZcodeHome  'AGENTS.md')
Install-FileLink -Source (Join-Path $RepoRoot 'rules\CLAUDE.md') -Destination (Join-Path $ClaudeHome 'CLAUDE.md')

Write-Head '清理悬空链接'
Remove-DanglingLinks -Destination $CodexSkills  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ZcodeSkills  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ClaudeSkills -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $CodexAgents  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ZcodeAgents  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ClaudeAgents -RepoPath $RepoRoot

# 额外仓库的悬空链接单独清理（它们的链接指向另一个仓库根）。
if ($ExtraRepo) {
    foreach ($r in $ExtraRepo) {
        $extraSkills = Join-Path $r 'skills'
        if (-not (Test-Path -LiteralPath $extraSkills)) { continue }
        Remove-DanglingLinks -Destination $CodexSkills  -RepoPath $extraSkills
        Remove-DanglingLinks -Destination $ZcodeSkills  -RepoPath $extraSkills
        Remove-DanglingLinks -Destination $ClaudeSkills -RepoPath $extraSkills
    }
}

# ---------------------------------------------------------------- upstream

if ($WithUpstream) {
    Write-Head '上游技能（从源头重装）'

    $upstreamFile = Join-Path $RepoRoot 'upstream.json'
    if (-not (Test-Path -LiteralPath $upstreamFile -PathType Leaf)) {
        Warn "未找到 upstream.json，跳过"
    }
    else {
        $entries = (Get-Content -LiteralPath $upstreamFile -Raw -Encoding utf8 | ConvertFrom-Json).skills

        # 定位 skill-installer 的辅助脚本，它位于客户端自己的技能树里。
        $installer = $null
        foreach ($root in @($CodexSkills, $ZcodeSkills, $ClaudeSkills)) {
            $candidate = Join-Path $root '.system\skill-installer\scripts\install-skill-from-github.py'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $installer = $candidate; break }
        }
        if (-not $installer) {
            Warn "未找到 skill-installer 的辅助脚本；请先让 .system 技能就位，再重跑。"
        }
        else {
            $python = $null
            foreach ($c in @(
                (Join-Path $HOME 'anaconda3\python.exe'),
                (Join-Path $HOME 'miniconda3\python.exe'),
                'C:\ProgramData\anaconda3\python.exe',
                'E:\anaconda3\python.exe',
                'D:\anaconda3\python.exe'
            )) {
                # 排除微软商店的桩程序：它打印错误但退出码为 0。
                if ($c -match 'WindowsApps') { continue }
                if (-not (Test-Path -LiteralPath $c)) { continue }
                $out = & $c '--version' 2>&1
                if (($out -join ' ') -match 'Python\s+3\.') { $python = $c; break }
            }

            if (-not $python) {
                Warn "未找到真实 Python（WindowsApps 下的 python 是退出码为 0 的桩程序）。跳过。"
            }
            else {
                Info "python: $python"
                # 上游技能装进**规范根**（$CodexSkills）：那既是 skill-installer 的默认
                # 目标，也是现有上游技能实际所在的位置。另两个客户端根随后链接到它，
                # 与本机既有布局一致——始终只有一份物理拷贝。
                Info "规范根：$CodexSkills"

                foreach ($e in $entries) {
                    $dest = Join-Path $CodexSkills $e.name
                    Info "--- $($e.name)  ($($e.repo)@$($e.ref), license $($e.license))"
                    if ($e.license -like 'CC-BY-NC*') {
                        Warn "非商业许可：$($e.license_note)"
                    }
                    if (Test-Path -LiteralPath $dest) {
                        if ($DryRun) { Dry "将删除并重装 $dest"; continue }
                        Remove-Item -LiteralPath $dest -Recurse -Force
                    }
                    if ($DryRun) { Dry "将为 $($e.path) 运行安装器"; continue }

                    $argList = @(
                        $installer
                        '--repo', $e.repo
                        '--ref',  $e.ref
                        '--path', $e.path
                        '--dest', $CodexSkills
                        '--method', 'git'
                    )
                    if ($Proxy) { $env:HTTPS_PROXY = $Proxy; $env:HTTP_PROXY = $Proxy }
                    & $python @argList
                    $exit = $LASTEXITCODE
                    if ($exit -ne 0) {
                        Warn "$($e.name) 安装失败（退出码 $exit）"
                        continue
                    }
                    Ok "已安装 $($e.name) -> $CodexSkills"

                    foreach ($otherRoot in @($ZcodeSkills, $ClaudeSkills)) {
                        $otherLink = Join-Path $otherRoot $e.name
                        if (Test-Path -LiteralPath $otherLink) { Skip "$otherLink"; continue }
                        if ($DryRun) { Dry "将建立 junction $otherLink -> $dest"; continue }
                        $lp = @{ ItemType = 'Junction'; Path = $otherLink; Target = $dest }
                        try {
                            New-Item @lp | Out-Null
                            Ok "junction $($e.name) -> $(Split-Path -Leaf $otherRoot)"
                        }
                        catch {
                            Warn "junction 创建失败：$otherLink : $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
    }
}

Write-Head '完成'
if ($DryRun) { Info 'Dry run: nothing was written.' }
Info '请新开一个对话——技能列表在会话启动时加载。'
Info '用 scripts\doctor.ps1 验证。'
