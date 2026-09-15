#Requires -Version 5.1
<#
.SYNOPSIS
    拉取最新 agent-config，然后重新链接全部内容。

.DESCRIPTION
    由于安装使用 junction 和硬链接，通常只更新仓库内容就够了——链接文件会立即
    反映改动。本脚本额外重跑安装器，以便新增或删除的技能被正确链接和清理。

.PARAMETER Proxy
    用于 git 的 HTTP 代理，例如 http://127.0.0.1:7897。省略时从 local/hosts.yaml 读取。

.PARAMETER SkipPull
    跳过 git pull（适用于仓库已通过其他方式更新的情况）。

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

Write-Head 'agent-config 更新'
Write-Host "  仓库：$RepoRoot"

if (-not $SkipPull) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        Write-Host '  [warn] 不是 git 仓库，跳过拉取' -ForegroundColor Yellow
    }
    else {
        $dirty = @(& git -C $RepoRoot status --porcelain 2>&1)
        if ($dirty.Count -gt 0) {
            Write-Host "  [warn] 有 $($dirty.Count) 处未提交改动——不执行拉取。" -ForegroundColor Yellow
            Write-Host '         请先提交、暂存或丢弃这些改动，然后重跑。'
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
                Write-Host "  使用代理：$Proxy"
            }

            Write-Host '  git pull --rebase'
            & git -C $RepoRoot pull --rebase
            $exit = $LASTEXITCODE
            if ($exit -ne 0) {
                Write-Host "  [warn] git pull 失败（退出码 $exit）" -ForegroundColor Yellow
                Write-Host '         继续执行：链接内容仍反映磁盘上的现状。'
            }
            else {
                Write-Host '  [ok] 已是最新' -ForegroundColor Green
            }
        }
    }
}

Write-Head '刷新链接'
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [warn] 安装器退出码 $LASTEXITCODE" -ForegroundColor Yellow
}

Write-Head '完成'
Write-Host '  请新开一个对话——技能列表在会话启动时加载。'
Write-Host '  用 scripts\doctor.ps1 验证。'
