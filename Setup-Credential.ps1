#Requires -Version 5.1
<#
.SYNOPSIS
    校园网自动认证 —— 凭据初始化。

.DESCRIPTION
    交互式录入账号、密码、运营商，并把密码用 Windows DPAPI（当前用户作用域）
    加密后写入本地配置文件。加密后的密文只能在「本机 + 本用户」下解密，
    配置文件被复制到其它电脑或其它账户都无法还原出明文。

    认证入口（portalHost）与 SSID 会尽量自动探测：运行前请先连上校园网 WiFi，
    并让浏览器打开一次任意网页，使网关弹出认证页。

.PARAMETER UserId
    账号（学号 / 工号）。省略则交互式输入。

.PARAMETER ServiceName
    运营商名称，需与 config 中的 serviceMap 键名一致。省略则交互式选择。

.PARAMETER Ssid
    校园网 WiFi 名称。省略则采用当前已连接的 SSID。

.PARAMETER PortalHost
    认证入口地址（IP 或域名）。省略则从网关 302 跳转中自动提取。

.PARAMETER SkipVerify
    跳过保存后的实测验证。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-Credential.ps1
#>
[CmdletBinding()]
param(
    [string]$UserId,
    [string]$ServiceName,
    [string]$Ssid,
    [string]$PortalHost,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'EportalAutoLogin.ps1')

$home_ = if ($env:EPORTAL_AUTOLOGIN_HOME) { $env:EPORTAL_AUTOLOGIN_HOME } else { Join-Path $env:LOCALAPPDATA 'EportalAutoLogin' }
$configPath = Join-Path $home_ 'config.json'

Write-Host ''
Write-Host '=== 校园网自动认证 · 凭据初始化 ===' -ForegroundColor Cyan
Write-Host ''

# --- 读取已有配置作为默认值 -------------------------------------------------
$old = $null
if (Test-Path -LiteralPath $configPath) {
    try { $old = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if ($old) {
    Write-Host ('检测到已有配置（账号 {0}，运营商 {1}），直接回车可沿用。' -f $old.userId, $old.serviceName) -ForegroundColor DarkGray
    Write-Host ''
    if (-not $UserId) { $UserId = [string]$old.userId }
    if (-not $ServiceName) { $ServiceName = [string]$old.serviceName }
    if (-not $Ssid) { $Ssid = [string]$old.ssid }
}

# --- 有效运营商映射（内置映射 + 已有 config.json 中的 serviceMap 覆盖项）----
$svcMap = Get-EffectiveServiceMap -Config $old

# --- 账号 -------------------------------------------------------------------
if (-not $UserId) {
    $UserId = (Read-Host '请输入校园网账号').Trim()
}
if ([string]::IsNullOrWhiteSpace($UserId)) { throw '账号不能为空。' }

# --- SSID -------------------------------------------------------------------
if (-not $Ssid) {
    $detected = Get-WlanSsid
    $hint = if ($detected) { ('（当前已连接 {0}，直接回车采用）' -f $detected) } else { '' }
    $Ssid = (Read-Host ('请输入校园网 WiFi 名称' + $hint)).Trim()
    if ([string]::IsNullOrWhiteSpace($Ssid)) { $Ssid = $detected }
}
if ([string]::IsNullOrWhiteSpace($Ssid)) {
    throw 'SSID 不能为空：请先连上校园网 WiFi 再运行，或用 -Ssid 显式指定。'
}

# --- 运营商 -----------------------------------------------------------------
if (-not $ServiceName) {
    $names = @($svcMap.Keys | Sort-Object)
    Write-Host ''
    Write-Host '请选择运营商：'
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ('  {0}) {1}    ({2})' -f ($i + 1), $names[$i], $svcMap[$names[$i]])
    }
    $pick = (Read-Host ('输入序号，直接回车 = 1 ({0})' -f $names[0])).Trim()
    if ([string]::IsNullOrWhiteSpace($pick)) {
        $ServiceName = $names[0]
    } else {
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $names.Count) {
            throw ('无效的序号: {0}' -f $pick)
        }
        $ServiceName = $names[$idx - 1]
    }
}
$serviceCode = $svcMap[$ServiceName]
if (-not $serviceCode) {
    throw ('未知运营商: {0}。如需自定义，请在 config.json 的 serviceMap 中增加后再运行本脚本，或用 -ServiceName 传入已有键名。' -f $ServiceName)
}

# --- 密码 -------------------------------------------------------------------
Write-Host ''
$sec1 = Read-Host '请输入校园网密码（输入时不显示）' -AsSecureString
$sec2 = Read-Host '请再次输入以确认' -AsSecureString

$b1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec1)
$b2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2)
try {
    $p1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
    $p2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
}
if ([string]::IsNullOrEmpty($p1)) { throw '密码不能为空。' }
if ($p1 -ne $p2) { throw '两次输入的密码不一致。' }

# --- 加密（DPAPI / 当前用户作用域） -----------------------------------------
$encrypted = ConvertFrom-SecureString $sec1

# --- 探测认证入口 -----------------------------------------------------------
$state = Get-NetState
$queryTemplate = ''
if ([string]::IsNullOrWhiteSpace($PortalHost)) {
    if ($state.State -eq 'NeedAuth' -and $state.PortalHost) {
        $PortalHost = $state.PortalHost
    }
}
if ($state.State -eq 'NeedAuth' -and $state.QueryString) {
    $queryTemplate = $state.QueryString
}

if ([string]::IsNullOrWhiteSpace($PortalHost)) {
    Write-Host ''
    Write-Host '提示：未能自动发现认证入口。' -ForegroundColor Yellow
    Write-Host '      脚本在每次运行时都会重新探测，通常不影响使用；' -ForegroundColor DarkGray
    Write-Host '      若后续认证一直失败，可用 -PortalHost 显式指定。' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host ('已发现认证入口: {0}' -f $PortalHost) -ForegroundColor DarkGray
}

# --- 写配置 -----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $home_)) {
    New-Item -ItemType Directory -Path $home_ -Force | Out-Null
}

# 有效映射与内置映射不同时，把 serviceMap 一并写入，便于下次初始化沿用
$svcMapCustom = $false
if ($svcMap.Count -ne $Script:DefaultServiceMap.Count) {
    $svcMapCustom = $true
} else {
    foreach ($k in $svcMap.Keys) {
        if (-not $Script:DefaultServiceMap.ContainsKey($k) -or
            [string]$Script:DefaultServiceMap[$k] -ne [string]$svcMap[$k]) { $svcMapCustom = $true; break }
    }
}

$cfg = [ordered]@{
    userId               = $UserId
    passwordDpapi        = $encrypted
    serviceName          = $ServiceName
    service              = $serviceCode
    ssid                 = $Ssid
    portalHost           = [string]$PortalHost
    queryStringTemplate  = $queryTemplate
    updatedAt            = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schemaVersion        = 1
}
if ($svcMapCustom) { $cfg['serviceMap'] = $svcMap }
$cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

Write-Host ''
Write-Host ('配置已写入: {0}' -f $configPath) -ForegroundColor Green
Write-Host ('  账号   : {0}' -f $UserId)
Write-Host ('  SSID   : {0}' -f $Ssid)
Write-Host ('  运营商 : {0}  (service={1})' -f $ServiceName, $serviceCode)
Write-Host '  密码   : 已用 DPAPI 加密（仅本机本用户可解密）'

# --- 验证 -------------------------------------------------------------------
if (-not $SkipVerify) {
    Write-Host ''
    Write-Host '正在实测验证...' -ForegroundColor Cyan

    $state = Get-NetState
    if ($state.State -eq 'Online') {
        Write-Host '  当前已在线，无法在在线状态下验证认证流程。' -ForegroundColor Yellow
        Write-Host ('  提示：断开重连 {0} 后运行  .\EportalAutoLogin.ps1 -Console  即可看到完整认证过程。' -f $Ssid) -ForegroundColor DarkGray
    } elseif ($state.State -eq 'Offline') {
        Write-Host ('  当前网络不可用，跳过验证。请连上 {0} 后再测。' -f $Ssid) -ForegroundColor Yellow
    }

    if ($state.State -eq 'NeedAuth') {
        $login = Invoke-PortalLogin -PortalHost $state.PortalHost -QueryString $state.QueryString `
                                    -UserId $UserId -Password $p1 -ServiceCode $serviceCode
        if ($login.Ok) {
            Write-Host '  认证成功 ✓' -ForegroundColor Green
        } else {
            Write-Host ('  认证失败 ✗ {0}' -f $login.Message) -ForegroundColor Red
            Write-Host '  常见原因：密码错误、运营商选错、或该账号已被运营商停用。' -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Write-Host '下一步：运行 Install-Task.ps1 安装登录时自动执行的计划任务（通常无需管理员）。' -ForegroundColor Cyan
Write-Host ''
