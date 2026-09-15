#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnose why a skill or agent is not visible to the agent client.

.DESCRIPTION
    Reports: which paths exist; the link type and target of every installed entry;
    entries that are REAL directories where a link was expected (they drift);
    dangling links whose target was deleted from the repo; divergence between the
    two rule files; local host configuration; and GitHub proxy reachability.

    Read-only. Changes nothing.

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

Write-Head 'Paths'

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
            Write-Host "         copy local/hosts.example.yaml to local/hosts.yaml and fill it in"
        }
        else {
            Add-Problem "missing: $($c.Name) at $($c.Path)"
        }
    }
}

# ---------------------------------------------------------------- link inventory

function Show-Links {
    param([string] $Title, [string] $Path, [string] $RepoPath)

    Write-Head $Title
    if (-not (Test-Path -LiteralPath $Path)) { Write-Host '  (directory does not exist)'; return }

    $entries = @(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name)
    if ($entries.Count -eq 0) { Write-Host '  (empty)'; return }

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
            # Real content where a link was expected: it will silently drift.
            if ($e.Name -in @('common','research','remote') -or (Test-Path -LiteralPath (Join-Path $RepoPath (Join-Path 'skills' $e.Name)))) {
                Add-Problem "REAL directory (not a link, will drift): $($e.FullName)"
            }
            continue
        }

        if ($pointsIn) {
            $target = ($e.Target -join ',')
            if (-not (Test-Path -LiteralPath $target)) {
                Add-Problem "dangling link (target gone): $($e.FullName) -> $target"
            }
        }
    }
}

Show-Links -Title 'Codex skills'  -Path (Join-Path $CodexHome  'skills') -RepoPath (Join-Path $RepoRoot 'skills')
Show-Links -Title 'Codex agents'  -Path (Join-Path $CodexHome  'agents') -RepoPath (Join-Path $RepoRoot 'agents')
Show-Links -Title 'ZCode skills'  -Path (Join-Path $ZcodeHome  'skills') -RepoPath (Join-Path $RepoRoot 'skills')
Show-Links -Title 'ZCode agents'  -Path (Join-Path $ZcodeHome  'agents') -RepoPath (Join-Path $RepoRoot 'agents')
Show-Links -Title 'Claude skills' -Path (Join-Path $ClaudeHome 'skills') -RepoPath (Join-Path $RepoRoot 'skills')
Show-Links -Title 'Claude agents' -Path (Join-Path $ClaudeHome 'agents') -RepoPath (Join-Path $RepoRoot 'agents')

# ---------------------------------------------------------------- rule drift

Write-Head 'Rule file consistency'

$a = Join-Path $RepoRoot 'rules\AGENTS.md'
$c = Join-Path $RepoRoot 'rules\CLAUDE.md'
if ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $c)) {
    $ha = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
    $hc = (Get-FileHash -LiteralPath $c -Algorithm SHA256).Hash
    if ($ha -eq $hc) {
        Write-Host '  [OK]   AGENTS.md and CLAUDE.md are identical' -ForegroundColor Green
    }
    else {
        # The two files are deliberately separate (the clients read different names),
        # so they can drift apart silently.
        Write-Host '  [WARN] AGENTS.md and CLAUDE.md DIFFER' -ForegroundColor Yellow
        Write-Host "         $a"
        Write-Host "         $c"
        Add-Problem 'rules/AGENTS.md and rules/CLAUDE.md have diverged'
    }
}
else {
    Add-Problem 'one of the rule files is missing'
}

# ---------------------------------------------------------------- repo state

Write-Head 'Repository state'

if (Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) {
    $branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>&1) -join ''
    $dirty  = @(& git -C $RepoRoot status --porcelain 2>&1)
    Write-Host "  branch : $branch"
    if ($dirty.Count -eq 0) {
        Write-Host '  [OK]   working tree clean' -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] $($dirty.Count) uncommitted change(s)" -ForegroundColor Yellow
        $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "         $_" }
    }
    $remote = (& git -C $RepoRoot remote get-url origin 2>&1) -join ''
    Write-Host "  origin : $remote"

    # Guard against ever committing local-only values.
    $tracked = @(& git -C $RepoRoot ls-files 2>&1)
    $leaks = $tracked | Where-Object { $_ -match '^local/' -and $_ -notmatch 'hosts\.example\.yaml$' }
    if ($leaks.Count -gt 0) {
        Write-Host '  [FAIL] local/ files are TRACKED by git:' -ForegroundColor Red
        $leaks | ForEach-Object { Write-Host "         $_" }
        Add-Problem 'machine-specific local/ files are tracked by git'
    }
    else {
        Write-Host '  [OK]   no local/ files tracked' -ForegroundColor Green
    }
}
else {
    Write-Host '  (not a git repository)'
    Add-Problem 'repo root is not a git repository'
}

# ---------------------------------------------------------------- environment

Write-Head 'Environment'

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) { Write-Host "  [OK]   pwsh present: $($pwsh.Source)" -ForegroundColor Green }
else { Write-Host '  [warn] pwsh (PowerShell 7) not found; scripts fall back to 5.1 rules' -ForegroundColor Yellow }

# The WindowsApps python is a stub that prints an error yet exits 0, so check output.
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
if ($python) { Write-Host "  [OK]   real python: $python" -ForegroundColor Green }
else { Write-Host '  [warn] no real Python (needed only for -WithUpstream)' -ForegroundColor Yellow }

$effective = Get-ExecutionPolicy
Write-Host "  execution policy: $effective"
if ($effective -eq 'Restricted') {
    Write-Host '         a bare .\script.ps1 will be refused; use:' -ForegroundColor Yellow
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
        Write-Host "  [OK]   proxy reachable: $Proxy" -ForegroundColor Green
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        Write-Host "  [warn] proxy probe failed: $Proxy" -ForegroundColor Yellow
    }
}
else {
    Write-Host '  proxy: not configured (fine unless GitHub is blocked here)'
}

# ---------------------------------------------------------------- verdict

Write-Head 'Verdict'
if ($problems.Count -eq 0) {
    Write-Host '  No problems found.' -ForegroundColor Green
}
else {
    Write-Host "  $($problems.Count) problem(s):" -ForegroundColor Yellow
    foreach ($p in $problems) { Write-Host "    - $p" }
    Write-Host ''
    Write-Host '  Tip: re-run scripts\install.ps1 to recreate missing links and prune dangling ones.'
}
