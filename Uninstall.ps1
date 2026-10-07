#Requires -Version 5.1
<#
.SYNOPSIS
    校园网自动认证 —— 卸载。

.DESCRIPTION
    注销计划任务；可选删除本地数据目录（配置、加密凭据、日志、脚本副本）。
    默认保留配置，只移除开机自启；加 -Purge 则连数据一起删除。

.PARAMETER Purge
    连同 %LOCALAPPDATA%\EportalAutoLogin 整个目录一起删除（含加密凭据与日志）。

.PARAMETER TaskName
    计划任务名称，默认 EportalAutoLogin。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
    [switch]$Purge,
    [string]$TaskName = 'EportalAutoLogin'
)

$ErrorActionPreference = 'Stop'

$dest = if ($env:EPORTAL_AUTOLOGIN_HOME) { $env:EPORTAL_AUTOLOGIN_HOME } else { Join-Path $env:LOCALAPPDATA 'EportalAutoLogin' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ''
Write-Host '=== 校园网自动认证 · 卸载 ===' -ForegroundColor Cyan

# --- 1) 注销计划任务 --------------------------------------------------------
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    # 注销自己的用户级任务通常不需要管理员，直接尝试，失败再提示
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host ('已注销计划任务: {0}' -f $TaskName) -ForegroundColor Green
    } catch {
        Write-Host ('注销计划任务失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host '如提示权限不足，请用管理员身份重新运行本脚本。' -ForegroundColor Yellow
    }
} else {
    Write-Host '未发现已注册的计划任务，跳过。' -ForegroundColor DarkGray
}

# --- 2) 可选删除数据目录 ----------------------------------------------------
if ($Purge) {
    Write-Host ''
    Write-Host ('将要删除以下目录及其全部内容: {0}' -f $dest) -ForegroundColor Yellow
    if (Test-Path -LiteralPath $dest) {
        Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 20 |
            ForEach-Object { Write-Host ('  ' + $_.FullName) -ForegroundColor DarkGray }

        $ans = Read-Host '确认删除？输入 YES 继续'
        if ($ans -eq 'YES') {
            try {
                Remove-Item -LiteralPath $dest -Recurse -Force
                Write-Host ('已删除: {0}' -f $dest) -ForegroundColor Green
                if ($here -eq $dest) {
                    Write-Host '（当前脚本所在副本已一并删除；工作区中的原始副本不受影响）' -ForegroundColor DarkGray
                }
            } catch {
                Write-Host ('删除失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
            }
        } else {
            Write-Host '已取消删除，仅移除了开机自启。' -ForegroundColor DarkGray
        }
    } else {
        Write-Host '目录不存在，跳过。' -ForegroundColor DarkGray
    }
} else {
    Write-Host ''
    Write-Host ('已保留本地数据目录: {0}' -f $dest) -ForegroundColor DarkGray
    Write-Host '如需连同加密凭据与日志一起清除，请加 -Purge 重新运行。' -ForegroundColor DarkGray
}

Write-Host ''
