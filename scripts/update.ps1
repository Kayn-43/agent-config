#Requires -Version 5.1
<#
.SYNOPSIS
    Pull the latest agent-config, then re-link everything.

.DESCRIPTION
    Because installation uses junctions and hard links, updating the repo content is
    usually enough on its own — linked files reflect edits immediately. This script
    additionally re-runs the installer so that newly added or deleted skills are
    linked and pruned.

.PARAMETER Proxy
    HTTP proxy for git, e.g. http://127.0.0.1:7897. Read from local/hosts.yaml when omitted.

.PARAMETER SkipPull
    Skip git pull (useful when the repo was updated by other means).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\update.ps1
#>
[CmdletBinding()]
param(
    [string] $Proxy,
    [switch] $SkipPull
)

$ErrorActionPreference = 'Continue'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $PSScriptRoot 'install.ps1'

function Write-Head { param([string] $Text) Write-Host ''; Write-Host ('=' * 62); Write-Host $Text; Write-Host ('=' * 62) }

Write-Head 'agent-config update'
Write-Host "  repo: $RepoRoot"

if (-not $SkipPull) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        Write-Host '  [warn] not a git repository; skipping pull' -ForegroundColor Yellow
    }
    else {
        $dirty = @(& git -C $RepoRoot status --porcelain 2>&1)
        if ($dirty.Count -gt 0) {
            Write-Host "  [warn] $($dirty.Count) uncommitted local change(s) — not pulling." -ForegroundColor Yellow
            Write-Host '         Commit, stash, or discard them first, then re-run.'
            $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "         $_" }
        }
        else {
            if (-not $Proxy) {
                $hostsFile = Join-Path $RepoRoot 'local\hosts.yaml'
                if (Test-Path -LiteralPath $hostsFile) {
                    $m = Select-String -LiteralPath $hostsFile -Pattern 'default_proxy:\s*"?([^"\s]+)"?' | Select-Object -First 1
                    if ($m) { $Proxy = $m.Matches[0].Groups[1].Value }
                }
            }
            if ($Proxy) {
                $env:HTTPS_PROXY = $Proxy
                $env:HTTP_PROXY  = $Proxy
                Write-Host "  using proxy: $Proxy"
            }

            Write-Host '  git pull --rebase'
            & git -C $RepoRoot pull --rebase
            $exit = $LASTEXITCODE
            if ($exit -ne 0) {
                Write-Host "  [warn] git pull failed (exit $exit)" -ForegroundColor Yellow
                Write-Host '         Continuing: linked content still reflects whatever is on disk.'
            }
            else {
                Write-Host '  [ok] up to date' -ForegroundColor Green
            }
        }
    }
}

Write-Head 'Refreshing links'
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [warn] installer exited $LASTEXITCODE" -ForegroundColor Yellow
}

Write-Head 'Done'
Write-Host '  Restart the agent (new conversation) so the skill list reloads.'
Write-Host '  Run scripts\doctor.ps1 to verify.'
