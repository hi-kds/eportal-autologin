#Requires -Version 5.1
<#
.SYNOPSIS
    校园网自动认证 —— 安装登录时自动运行的计划任务。

.DESCRIPTION
    1) 把脚本复制到 %LOCALAPPDATA%\EportalAutoLogin\（稳定位置，不受工作区清理影响）
    2) 注册计划任务：**默认只在用户登录时执行一次**，不做周期巡检。

    为什么默认不巡检（重要）：
      每次执行都要启动一个 powershell.exe 进程。而
      powershell.exe -WindowStyle Hidden 的机制是「系统先创建控制台窗口 →
      PowerShell 再把它隐藏」，中间那一下会在屏幕上闪一个黑框。
      巡检越频繁，闪得越频繁（每分钟巡检 = 每小时闪 60 次）。
      所以默认关闭巡检，只在登录时跑一次。

    若确实需要「掉线自动重连」，用 -IntervalMinutes N 显式开启巡检，
    代价是每隔 N 分钟会闪一次窗。

.PARAMETER IntervalMinutes
    巡检间隔（分钟）。**默认 0 = 不巡检，只在登录时执行一次。** 填正数才会加周期触发器。

.PARAMETER TaskName
    计划任务名称，默认 EportalAutoLogin。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1

.EXAMPLE
    # 开启每 30 分钟巡检一次（会有周期性闪窗）
    powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1 -IntervalMinutes 30
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 0,
    [string]$TaskName = 'EportalAutoLogin'
)

$ErrorActionPreference = 'Stop'

# --- 权限检查 ---------------------------------------------------------------
# 实测：注册「以当前用户身份运行」的计划任务不需要管理员权限（标准用户即可）。
# 所以这里只做提示，不拦截；真失败时下面的注册逻辑会报错。
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host '提示：当前不是管理员权限。' -ForegroundColor DarkGray
    Write-Host '注册用户级计划任务通常不需要管理员；若下面注册失败，请改用管理员身份重试。' -ForegroundColor DarkGray
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = if ($env:EPORTAL_AUTOLOGIN_HOME) { $env:EPORTAL_AUTOLOGIN_HOME } else { Join-Path $env:LOCALAPPDATA 'EportalAutoLogin' }
$mainScript = Join-Path $dest 'EportalAutoLogin.ps1'
$configPath = Join-Path $dest 'config.json'

Write-Host ''
Write-Host '=== 校园网自动认证 · 安装计划任务 ===' -ForegroundColor Cyan

# --- 检查凭据是否已初始化 ---------------------------------------------------
if (-not (Test-Path -LiteralPath $configPath)) {
    $localCfg = Join-Path $here 'config.json'
    if (Test-Path -LiteralPath $localCfg) {
        $configPath = $localCfg
    } else {
        Write-Host '未找到 config.json，请先运行 Setup-Credential.ps1 录入账号密码。' -ForegroundColor Red
        exit 2
    }
}

# --- 复制脚本到稳定目录 -----------------------------------------------------
if (-not (Test-Path -LiteralPath $dest)) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}
$copied = @()
foreach ($src in (Get-ChildItem -LiteralPath $here -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
    Copy-Item -LiteralPath $src.FullName -Destination (Join-Path $dest $src.Name) -Force
    $copied += $src.Name
}
if ($configPath -ne (Join-Path $dest 'config.json')) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $dest 'config.json') -Force
    $copied += 'config.json'
}
Write-Host ('脚本已复制到: {0}' -f $dest) -ForegroundColor DarkGray
Write-Host ('  ' + ($copied -join ', '))

# --- 构造计划任务 -----------------------------------------------------------
# 这里用完整 XML 注册，而不是 New-ScheduledTaskTrigger 那套 cmdlet。
# 原因：cmdlet 表达不了「无限期重复」——传 [TimeSpan]::MaxValue 会被序列化成
# P99999999DT23H59M59S，超出调度器允许的范围，报「任务 XML 包含格式不正确或超出范围的值」。
# 省略 <Duration> 元素才是调度器认可的「无限期」写法（等价于 GUI 里勾选"无限期"）。
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $pwsh)) { $pwsh = 'powershell.exe' }

$argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $mainScript

function ConvertTo-XmlText([string]$s) {
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&apos;')
}

# 周期巡检触发器：仅当 IntervalMinutes > 0 时才生成。
# 默认 0 = 不生成，即「只在登录时执行一次」。
$repeatBlock = ''
if ($IntervalMinutes -gt 0) {
    $startBoundary  = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
    $repeatInterval = 'PT{0}M' -f $IntervalMinutes
    $repeatBlock = @"
    <TimeTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Repetition>
        <Interval>$repeatInterval</Interval>
      </Repetition>
      <Enabled>true</Enabled>
    </TimeTrigger>
"@
}

$taskXml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>校园网 (ePortal) 自动认证：用户登录时执行一次。</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$(ConvertTo-XmlText $currentUser)</UserId>
    </LogonTrigger>
$repeatBlock  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(ConvertTo-XmlText $currentUser)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-XmlText $pwsh)</Command>
      <Arguments>$(ConvertTo-XmlText $argLine)</Arguments>
      <WorkingDirectory>$(ConvertTo-XmlText $dest)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

# --- 注册 -------------------------------------------------------------------
try {
    Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host ('XML 方式注册失败: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    Write-Host '改用回退方案（cmdlet）...' -ForegroundColor DarkGray
    try {
        $action  = New-ScheduledTaskAction -Execute $pwsh -Argument $argLine -WorkingDirectory $dest
        $tLogon  = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        $triggers = @($tLogon)
        if ($IntervalMinutes -gt 0) {
            $tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
                -RepetitionDuration (New-TimeSpan -Days 3650)
            $triggers += $tRepeat
        }
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings `
            -Description '校园网自动认证' -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ('注册计划任务失败: {0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 3
    }
}

# 注册后回查一次，避免后续拿到 $null 抛出难以定位的错误
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    Write-Host ('计划任务注册后未能查到（{0}）。若上面没有报错，请以管理员身份重试。' -f $TaskName) -ForegroundColor Red
    exit 3
}
Write-Host ''
Write-Host ('计划任务已注册: {0}（状态 {1}）' -f $task.TaskName, $task.State) -ForegroundColor Green
if ($IntervalMinutes -gt 0) {
    Write-Host ('  触发 : 用户登录时 + 每 {0} 分钟巡检（会有周期性闪窗）' -f $IntervalMinutes)
} else {
    Write-Host '  触发 : 仅用户登录时执行一次（不巡检，无周期性弹窗）'
}
Write-Host ('  账户 : {0}（非提权运行）' -f $currentUser)
Write-Host ('  命令 : {0} {1}' -f $pwsh, $argLine)

# --- 立即试跑一次 -----------------------------------------------------------
Write-Host ''
Write-Host '正在立即试跑一次...' -ForegroundColor Cyan
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 6
$logFile = Join-Path $dest ('logs\autologin-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
if (Test-Path -LiteralPath $logFile) {
    Get-Content -LiteralPath $logFile -Tail 8 | ForEach-Object { Write-Host ('  ' + $_) }
} else {
    Write-Host '  （尚未产生日志，可稍后运行 EportalAutoLogin.ps1 -Status 查看）' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '查看状态:  powershell -ExecutionPolicy Bypass -File "' -NoNewline
Write-Host ((Join-Path $dest 'EportalAutoLogin.ps1') + '" -Status') -NoNewline
Write-Host ''
Write-Host '卸载:      powershell -ExecutionPolicy Bypass -File "' -NoNewline
Write-Host ((Join-Path $dest 'Uninstall.ps1') + '"') -NoNewline
Write-Host ''
Write-Host ''
