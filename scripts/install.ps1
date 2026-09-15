#Requires -Version 5.1
<#
.SYNOPSIS
    Link this repository's skills, agents and rules into the agent client homes.

.DESCRIPTION
    Content is LINKED, never copied, so one edit propagates everywhere and nothing
    drifts. See README.md for why junctions and hard links are used instead of
    symbolic links.

    Directories -> directory junctions      (no elevation required)
    Files       -> hard links, else copy    (no elevation required)

    Also prunes entries that point into this repository but whose source has been
    deleted — those linger forever and make the skill list lie about what exists.
    Entries that do NOT point into this repository are never touched.

.PARAMETER DryRun
    Report what would happen; change nothing.

.PARAMETER WithUpstream
    Also install/refresh the third-party skills recorded in upstream.json.

.PARAMETER Proxy
    HTTP proxy for the upstream installs, e.g. http://127.0.0.1:7897.

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
    [string] $Proxy
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

# ---------------------------------------------------------------- helpers

function Write-Head { param([string] $Text) Write-Host ''; Write-Host ('=' * 62); Write-Host $Text; Write-Host ('=' * 62) }
function Info { param([string] $Text) Write-Host "  $Text" }
function Ok   { param([string] $Text) Write-Host "  [ok]    $Text" -ForegroundColor Green }
function Skip { param([string] $Text) Write-Host "  [skip]  $Text" -ForegroundColor DarkGray }
function Warn { param([string] $Text) Write-Host "  [warn]  $Text" -ForegroundColor Yellow }
function Prune{ param([string] $Text) Write-Host "  [prune] $Text" -ForegroundColor Magenta }
function Dry  { param([string] $Text) Write-Host "  [dry]   $Text" -ForegroundColor Cyan }

function Ensure-Directory {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) { return }
    if ($DryRun) { Dry "would create $Path"; return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Ok "created $Path"
}

# A junction (or any link) whose target no longer exists still shows up in the
# skill list. Only consider entries that point INTO this repository.
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

    Info "$Group/ : $($skills.Count) skills"

    foreach ($skill in $skills) {
        foreach ($dest in $Destinations) {
            $link = Join-Path $dest $skill.Name

            if (Test-Path -LiteralPath $link) {
                $existing = Get-Item -LiteralPath $link -Force
                if ($existing.LinkType) {
                    Skip "$link"
                    continue
                }
                # A real directory here means something copied it instead of linking.
                Warn "$link exists as a REAL directory, not a link — it will drift."
                Warn "       remove it manually, then re-run (install never deletes real directories)."
                continue
            }

            if ($DryRun) { Dry "junction $link -> $($skill.FullName)"; continue }

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
                Warn "junction failed for $link : $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------- file links

function Install-FileLink {
    param([string] $Source, [string] $Destination)

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }

    if (Test-Path -LiteralPath $Destination) {
        $existing = Get-Item -LiteralPath $Destination -Force
        if ($existing.LinkType) { Skip "$Destination"; return }
        Warn "$Destination exists as a real file, not a link — skipped."
        return
    }

    if ($DryRun) { Dry "hardlink $Destination -> $Source"; return }

    # Hard links need no elevation, unlike symbolic links.
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
        Warn "hard link unavailable, COPIED instead: $Destination"
        Warn "       this copy will not track repo edits."
    }
}

function Install-AgentFiles {
    param([string] $RepoPath, [string] $Destination)

    $agentDir = Join-Path $RepoPath 'agents'
    if (-not (Test-Path -LiteralPath $agentDir)) { return }

    foreach ($agent in (Get-ChildItem -LiteralPath $agentDir -Filter '*.md' | Sort-Object Name)) {
        Install-FileLink -Source $agent.FullName -Destination (Join-Path $Destination $agent.Name)
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

Write-Head 'agent-config installer'
Info "repo       : $RepoRoot"
Info "codex home : $CodexHome"
Info "zcode home : $ZcodeHome"
Info "claude home: $ClaudeHome"
Info "dry run    : $($DryRun.IsPresent)"

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'skills'))) {
    throw "Not a agent-config repo (no skills/ under $RepoRoot)"
}

Write-Head 'Directories'
foreach ($d in @($CodexHome, $CodexSkills, $CodexAgents, $ZcodeHome, $ZcodeSkills, $ZcodeAgents, $ClaudeHome, $ClaudeSkills, $ClaudeAgents)) {
    Ensure-Directory -Path $d
}

Write-Head 'Skills -> Codex'
foreach ($g in $SkillGroups) { Install-SkillGroup -Group $g -Destinations @($CodexSkills) -RepoPath $RepoRoot }

Write-Head 'Skills -> ZCode'
foreach ($g in $SkillGroups) { Install-SkillGroup -Group $g -Destinations @($ZcodeSkills) -RepoPath $RepoRoot }

Write-Head 'Skills -> Claude'
foreach ($g in $SkillGroups) { Install-SkillGroup -Group $g -Destinations @($ClaudeSkills) -RepoPath $RepoRoot }

Write-Head 'Agents'
Install-AgentFiles -RepoPath $RepoRoot -Destination $CodexAgents
Install-AgentFiles -RepoPath $RepoRoot -Destination $ZcodeAgents
Install-AgentFiles -RepoPath $RepoRoot -Destination $ClaudeAgents

Write-Head 'Rules'
Install-FileLink -Source (Join-Path $RepoRoot 'rules\AGENTS.md') -Destination (Join-Path $CodexHome  'AGENTS.md')
Install-FileLink -Source (Join-Path $RepoRoot 'rules\AGENTS.md') -Destination (Join-Path $ZcodeHome  'AGENTS.md')
Install-FileLink -Source (Join-Path $RepoRoot 'rules\CLAUDE.md') -Destination (Join-Path $ClaudeHome 'CLAUDE.md')

Write-Head 'Pruning dangling links'
Remove-DanglingLinks -Destination $CodexSkills  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ZcodeSkills  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ClaudeSkills -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $CodexAgents  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ZcodeAgents  -RepoPath $RepoRoot
Remove-DanglingLinks -Destination $ClaudeAgents -RepoPath $RepoRoot

# ---------------------------------------------------------------- upstream

if ($WithUpstream) {
    Write-Head 'Upstream skills (reinstalled from source)'

    $upstreamFile = Join-Path $RepoRoot 'upstream.json'
    if (-not (Test-Path -LiteralPath $upstreamFile -PathType Leaf)) {
        Warn "no upstream.json found; skipping"
    }
    else {
        $entries = (Get-Content -LiteralPath $upstreamFile -Raw -Encoding utf8 | ConvertFrom-Json).skills

        # Locate skill-installer's helper, which lives in the client's own skill tree.
        $installer = $null
        foreach ($root in @($CodexSkills, $ZcodeSkills, $ClaudeSkills)) {
            $candidate = Join-Path $root '.system\skill-installer\scripts\install-skill-from-github.py'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $installer = $candidate; break }
        }
        if (-not $installer) {
            Warn "skill-installer helper not found; install the .system skills first, then re-run."
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
                # Reject the Microsoft Store stub: it prints an error yet exits 0.
                if ($c -match 'WindowsApps') { continue }
                if (-not (Test-Path -LiteralPath $c)) { continue }
                $out = & $c '--version' 2>&1
                if (($out -join ' ') -match 'Python\s+3\.') { $python = $c; break }
            }

            if (-not $python) {
                Warn "no real Python found (the WindowsApps 'python' is a stub that exits 0). Skipping."
            }
            else {
                Info "python: $python"
                # Upstream skills install into the CANONICAL root ($CodexSkills), which is
                # where skill-installer defaults and where existing upstream skills already
                # live. The other client roots then get junctions to it, matching how this
                # machine is already laid out — never a second physical copy.
                Info "canonical root: $CodexSkills"

                foreach ($e in $entries) {
                    $dest = Join-Path $CodexSkills $e.name
                    Info "--- $($e.name)  ($($e.repo)@$($e.ref), license $($e.license))"
                    if ($e.license -like 'CC-BY-NC*') {
                        Warn "non-commercial license: $($e.license_note)"
                    }
                    if (Test-Path -LiteralPath $dest) {
                        if ($DryRun) { Dry "would remove and reinstall $dest"; continue }
                        Remove-Item -LiteralPath $dest -Recurse -Force
                    }
                    if ($DryRun) { Dry "would run the installer for $($e.path)"; continue }

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
                        Warn "installer failed for $($e.name) (exit $exit)"
                        continue
                    }
                    Ok "installed $($e.name) -> $CodexSkills"

                    foreach ($otherRoot in @($ZcodeSkills, $ClaudeSkills)) {
                        $otherLink = Join-Path $otherRoot $e.name
                        if (Test-Path -LiteralPath $otherLink) { Skip "$otherLink"; continue }
                        if ($DryRun) { Dry "junction $otherLink -> $dest"; continue }
                        $lp = @{ ItemType = 'Junction'; Path = $otherLink; Target = $dest }
                        try {
                            New-Item @lp | Out-Null
                            Ok "junction $($e.name) -> $(Split-Path -Leaf $otherRoot)"
                        }
                        catch {
                            Warn "junction failed for $otherLink : $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
    }
}

Write-Head 'Done'
if ($DryRun) { Info 'Dry run: nothing was written.' }
Info 'Restart the agent (new conversation) so the skill list reloads.'
Info 'Run scripts\doctor.ps1 to verify.'
