#Requires -Version 5.1
<#
.SYNOPSIS
    ePortal 校园网自动认证脚本（Windows / PowerShell）。

.DESCRIPTION
    检测当前是否处于「已连接 WiFi 但未认证」状态；若是，则自动向校园网
    ePortal 认证服务器提交账号 / 密码 / 运营商，完成上网认证。
    已在线时直接退出，不做任何多余动作。

    针对的接口族：认证页面 /eportal/index.jsp +
    提交接口 /eportal/InterFace.do?method=login（返回 JSON，含 result/message）。
    实测环境的门户页面标题为「RG-SAM+ Portal组件」，即锐捷 RG-SAM+ 的 Portal 组件。
    注意：网上不少资料把同一接口称作「Dr.COM ePortal」，但 Dr.COM 的 Web 认证
    实际使用另一套接口（POST /0.htm，参数 DDDDD / upass / 0MKKey），两者并非同一产品。

    认证入口（portalHost）与 queryString 均在运行时从网关的 302 跳转中自动发现，
    因此本脚本不包含任何学校的硬编码地址。

.PARAMETER Force
    即使检测到已在线，也强制重新提交一次认证。

.PARAMETER Status
    只打印当前网络状态与最近日志，不做任何认证动作。

.PARAMETER Console
    同时把日志输出到控制台（便于手动排查）。

.PARAMETER MaxAttempts
    一次运行内的最大尝试次数，默认 3。

.PARAMETER WaitWlanSeconds
    启动时等待关联到目标 SSID 的最长秒数，默认 60。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\EportalAutoLogin.ps1 -Console

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\EportalAutoLogin.ps1 -Status
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Status,
    [switch]$Console,
    [int]$MaxAttempts = 3,
    [int]$WaitWlanSeconds = 60
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 常量与路径
# ---------------------------------------------------------------------------
$Script:AppHome = if ($env:EPORTAL_AUTOLOGIN_HOME) { $env:EPORTAL_AUTOLOGIN_HOME } else { Join-Path $env:LOCALAPPDATA 'EportalAutoLogin' }
$Script:ConfigPath = Join-Path $Script:AppHome 'config.json'
$Script:LogDir = Join-Path $Script:AppHome 'logs'
$Script:Cc = New-Object System.Net.CookieContainer
$Script:KeepLogDays = 7

# 运营商名 -> ePortal 服务代码。
# LT/DX/YD/default 是这类门户的常见约定，可在 config.json 的
# serviceMap 字段中整体覆盖，以适配各校自己的服务命名。
$Script:DefaultServiceMap = @{
    '联通'   = 'LT'
    '电信'   = 'DX'
    '移动'   = 'YD'
    '校园网' = 'default'
}
$Script:ServiceMap = $Script:DefaultServiceMap.Clone()

# 探针地址：Windows 自带的连通性探测端点，未认证时会被校园网网关劫持到认证页
$Script:Probes = @(
    'http://www.msftconnecttest.com/redirect',
    'http://1.1.1.1'
)

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = '{0} [{1}] {2}' -f $ts, $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $Script:LogDir)) {
            New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
        }
        $file = Join-Path $Script:LogDir ('autologin-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    } catch { }
    if ($Console -or $Status) { Write-Host $line }
}

function Remove-OldLogs {
    try {
        if (-not (Test-Path -LiteralPath $Script:LogDir)) { return }
        $cutoff = (Get-Date).AddDays(-$Script:KeepLogDays)
        Get-ChildItem -LiteralPath $Script:LogDir -Filter 'autologin-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

# ---------------------------------------------------------------------------
# HTTP 底座（.NET 原生，完全控制重定向与 Cookie）
# ---------------------------------------------------------------------------
function Invoke-PortalHttp {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = 'GET',
        $Body = $null,
        [switch]$NoRedirect,
        [int]$TimeoutSec = 12,
        [switch]$UseSystemProxy
    )

    # --- 构造请求 ---
    $req = $null
    try {
        $req = [System.Net.WebRequest]::Create($Url)
        $req.Method = $Method
        $req.CookieContainer = $Script:Cc
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = -not $NoRedirect
        $req.MaximumAutomaticRedirections = 5
        $req.KeepAlive = $false
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
        if (-not $UseSystemProxy) { $req.Proxy = $null }

        if ($null -ne $Body -and [string]$Body -ne '') {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
            $req.ContentType = 'application/x-www-form-urlencoded; charset=UTF-8'
            $req.ContentLength = $bytes.Length
            $req.Headers.Add('X-Requested-With', 'XMLHttpRequest')
            $stream = $req.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Location = ''; Text = ('请求构造失败: ' + $_.Exception.Message) }
    }

    # --- 发送 ---
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            return [pscustomobject]@{ Ok = $false; Status = 0; Location = ''; Text = $_.Exception.Message }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Location = ''; Text = $_.Exception.Message }
    }

    # --- 读取 ---
    try {
        $status = [int]$resp.StatusCode
        $loc = [string]$resp.Headers['Location']
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        return [pscustomobject]@{ Ok = $true; Status = $status; Location = $loc; Text = $text }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Location = ''; Text = ('读取响应失败: ' + $_.Exception.Message) }
    }
}

# ---------------------------------------------------------------------------
# 网络状态探测
# ---------------------------------------------------------------------------
function Get-PortalQueryStringFromUrl {
    param([Parameter(Mandatory)][string]$Url)
    $i = $Url.IndexOf('?')
    if ($i -lt 0) { return '' }
    $qs = $Url.Substring($i + 1)
    # 认证页返回的 queryString 可能被单层或多层转义，这里解到露出明文参数为止
    for ($n = 0; $n -lt 3; $n++) {
        if ($qs -match 'wlanuserip=') { break }
        $next = [System.Uri]::UnescapeDataString($qs)
        if ($next -eq $qs) { break }
        $qs = $next
    }
    return $qs
}

function Get-PortalHostFromUrl {
    param([Parameter(Mandatory)][string]$Url)
    try { return ([System.Uri]$Url).Host } catch { return '' }
}

function Get-NetState {
    <#
      返回：
        State = Online   -> 已认证，可正常上网
        State = NeedAuth -> 被校园网认证页劫持，需登录（附带 QueryString / PortalHost）
        State = Offline  -> 网络不可用或未关联到局域网
    #>
    $errors = @()
    foreach ($probe in $Script:Probes) {
        $r = Invoke-PortalHttp -Url $probe -NoRedirect -TimeoutSec 10
        if (-not $r.Ok) { $errors += ('{0}: {1}' -f $probe, $r.Text); continue }

        $loc = $r.Location
        if ($loc -match '/eportal/index\.jsp') {
            return [pscustomobject]@{
                State       = 'NeedAuth'
                QueryString = (Get-PortalQueryStringFromUrl -Url $loc)
                PortalHost  = (Get-PortalHostFromUrl -Url $loc)
                Detail      = ('{0} -> {1}' -f $probe, $loc)
            }
        }
        if ($r.Text -match '/eportal/index\.jsp') {
            $m = [regex]::Match($r.Text, 'https?://[^"''<>\s]*?/eportal/index\.jsp\?[^"''<>\s]*')
            if ($m.Success) {
                return [pscustomobject]@{
                    State       = 'NeedAuth'
                    QueryString = (Get-PortalQueryStringFromUrl -Url $m.Value)
                    PortalHost  = (Get-PortalHostFromUrl -Url $m.Value)
                    Detail      = ('{0} -> (body) {1}' -f $probe, $m.Value)
                }
            }
        }
        # 明确拿到了非认证页的正常响应
        if ($r.Status -ge 200 -and $r.Status -lt 400) {
            return [pscustomobject]@{ State = 'Online'; QueryString = ''; PortalHost = ''; Detail = ('{0} -> HTTP {1}' -f $probe, $r.Status) }
        }
    }
    return [pscustomobject]@{ State = 'Offline'; QueryString = ''; PortalHost = ''; Detail = ($errors -join ' | ') }
}

# ---------------------------------------------------------------------------
# 无线网卡
# ---------------------------------------------------------------------------
function Get-WlanAdapter {
    try {
        return Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.PhysicalMediaType -like '*802.11*' } |
            Select-Object -First 1
    } catch { return $null }
}

function Get-WlanSsid {
    try {
        $raw = & netsh wlan show interfaces 2>$null
        foreach ($line in $raw) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
        }
    } catch { }
    return ''
}

function Get-WlanIPv4 {
    $adapter = Get-WlanAdapter
    if ($null -eq $adapter) { return '' }
    try {
        $addr = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1
        if ($addr) { return $addr.IPAddress }
    } catch { }
    return ''
}

function Wait-ForWlan {
    param([string]$Ssid, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $adapter = Get-WlanAdapter
        if ($null -ne $adapter -and $adapter.Status -eq 'Up') {
            $cur = Get-WlanSsid
            if ($cur -eq $Ssid -and (Get-WlanIPv4)) {
                return $true
            }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

# ---------------------------------------------------------------------------
# 编码工具
# ---------------------------------------------------------------------------
function Get-DoubleEncoded {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return [System.Uri]::EscapeDataString([System.Uri]::EscapeDataString($Value))
}

# ---------------------------------------------------------------------------
# 配置与凭据
# ---------------------------------------------------------------------------
function Get-EffectiveServiceMap {
    <#
      返回「内置映射 + config.json 中 serviceMap 覆盖项」合并后的有效映射。
      Setup-Credential.ps1 也复用本函数，以保证配置文件里的自定义运营商
      在下次初始化时同样出现在选择列表里。
    #>
    param($Config)
    $m = @{}
    foreach ($k in $Script:DefaultServiceMap.Keys) { $m[$k] = [string]$Script:DefaultServiceMap[$k] }
    if ($null -ne $Config -and
        ($Config.PSObject.Properties.Name -contains 'serviceMap') -and
        $null -ne $Config.serviceMap) {
        foreach ($p in $Config.serviceMap.PSObject.Properties) { $m[$p.Name] = [string]$p.Value }
    }
    return $m
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) {
        Write-Log -Level ERROR -Message ('配置文件不存在: {0}；请先运行 Setup-Credential.ps1' -f $Script:ConfigPath)
        return $null
    }
    try {
        $cfg = Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log -Level ERROR -Message ('配置文件解析失败: {0}' -f $_.Exception.Message)
        return $null
    }
    # 注意：必须写成 -notcontains，不能写成 "-not <集合> -contains"。
    # PowerShell 中 -not 的优先级高于 -contains，后者会被解析成
    # (-not $cfg.PSObject.Properties.Name) -contains $f，对非空对象恒为 $false，
    # 校验会静默失效。
    foreach ($f in @('userId', 'passwordDpapi', 'service', 'ssid')) {
        if ($cfg.PSObject.Properties.Name -notcontains $f) {
            Write-Log -Level ERROR -Message ('配置文件缺少字段: {0}' -f $f)
            return $null
        }
    }
    # 合并内置运营商映射与 config.json 中的自定义映射
    $Script:ServiceMap = Get-EffectiveServiceMap -Config $cfg
    return $cfg
}

function Get-PlainPassword {
    param([Parameter(Mandatory)][string]$Encrypted)
    $sec = ConvertTo-SecureString $Encrypted
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ---------------------------------------------------------------------------
# 认证
# ---------------------------------------------------------------------------
function Invoke-PortalLogin {
    param(
        [Parameter(Mandatory)][string]$PortalHost,
        [Parameter(Mandatory)][string]$QueryString,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$ServiceCode
    )

    $base = 'http://{0}/eportal/InterFace.do?method=' -f $PortalHost

    # 1) 先 GET 认证页，建立 JSESSIONID 会话（复刻浏览器行为）
    $idxUrl = 'http://{0}/eportal/index.jsp?{1}' -f $PortalHost, $QueryString
    $r = Invoke-PortalHttp -Url $idxUrl -NoRedirect -TimeoutSec 12
    if (-not $r.Ok) {
        return [pscustomobject]@{ Ok = $false; Message = ('打开认证页失败: {0}' -f $r.Text) }
    }

    # 2) 提交认证
    $payload = 'userId=' + (Get-DoubleEncoded $UserId) +
               '&password=' + $Password +
               '&service=' + (Get-DoubleEncoded $ServiceCode) +
               '&queryString=' + (Get-DoubleEncoded $QueryString) +
               '&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false'

    $r2 = Invoke-PortalHttp -Url ($base + 'login') -Method 'POST' -Body $payload -TimeoutSec 15
    if (-not $r2.Ok) {
        return [pscustomobject]@{ Ok = $false; Message = ('提交认证请求失败: {0}' -f $r2.Text) }
    }

    $result = $null
    try { $result = $r2.Text | ConvertFrom-Json } catch { }

    if ($null -eq $result) {
        return [pscustomobject]@{ Ok = $false; Message = ('认证响应无法解析: {0}' -f $r2.Text) }
    }
    if ($result.result -eq 'success') {
        return [pscustomobject]@{ Ok = $true; Message = '认证成功'; Raw = $result }
    }
    return [pscustomobject]@{ Ok = $false; Message = ('认证被拒绝: {0}' -f $result.message); Raw = $result }
}

# ---------------------------------------------------------------------------
# 通知（尽力而为，失败静默）
# ---------------------------------------------------------------------------
function Show-Toast {
    param([string]$Title, [string]$Message)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $tpl.GetElementsByTagName('text')
        $nodes.Item(0).AppendChild($tpl.CreateTextNode($Title)) | Out-Null
        $nodes.Item(1).AppendChild($tpl.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch { }
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
function Show-Status {
    Write-Host ''
    Write-Host '=== 校园网自动认证 · 当前状态 ===' -ForegroundColor Cyan
    $adapter = Get-WlanAdapter
    if ($adapter) {
        Write-Host ('网卡      : {0} ({1})' -f $adapter.Name, $adapter.InterfaceDescription)
        Write-Host ('链路状态  : {0}' -f $adapter.Status)
    } else {
        Write-Host '网卡      : 未找到无线网卡' -ForegroundColor Yellow
    }
    Write-Host ('当前 SSID : {0}' -f (Get-WlanSsid))
    Write-Host ('IPv4      : {0}' -f (Get-WlanIPv4))

    $cfg = $null
    if (Test-Path -LiteralPath $Script:ConfigPath) {
        try { $cfg = Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($cfg) {
        Write-Host ('账号      : {0}' -f $cfg.userId)
        Write-Host ('运营商    : {0} (service={1})' -f $cfg.serviceName, $cfg.service)
        Write-Host ('配置文件  : {0}' -f $Script:ConfigPath)
    } else {
        Write-Host '配置      : 尚未初始化，请先运行 Setup-Credential.ps1' -ForegroundColor Yellow
    }

    $state = Get-NetState
    $color = 'Green'
    if ($state.State -eq 'NeedAuth') { $color = 'Yellow' }
    if ($state.State -eq 'Offline') { $color = 'Red' }
    Write-Host ('连通状态  : {0}' -f $state.State) -ForegroundColor $color
    Write-Host ('探测详情  : {0}' -f $state.Detail)

    $task = Get-ScheduledTask -TaskName 'EportalAutoLogin' -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host ('计划任务  : 已安装（{0}）' -f $task.State)
    } else {
        Write-Host '计划任务  : 未安装' -ForegroundColor Yellow
    }

    $logFile = Join-Path $Script:LogDir ('autologin-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
    if (Test-Path -LiteralPath $logFile) {
        Write-Host ''
        Write-Host '--- 最近 15 条日志 ---' -ForegroundColor DarkGray
        Get-Content -LiteralPath $logFile -Tail 15 | ForEach-Object { Write-Host $_ }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
function Invoke-Main {
    if ($Status) { Show-Status; return 0 }

    Remove-OldLogs
    $cfg = Get-Config
    if ($null -eq $cfg) { return 2 }

    if (-not (Wait-ForWlan -Ssid $cfg.ssid -TimeoutSec $WaitWlanSeconds)) {
        Write-Log -Level WARN -Message ('等待 {0} 超时（{1}s），仍尝试探测认证状态' -f $cfg.ssid, $WaitWlanSeconds)
    }

    $state = Get-NetState
    Write-Log -Message ('网络探测: {0} | {1}' -f $state.State, $state.Detail)

    if ($state.State -eq 'Online' -and -not $Force) {
        Write-Log -Level OK -Message '当前已在线，无需认证'
        return 0
    }

    if ($state.State -eq 'Offline' -and -not $Force) {
        Write-Log -Level WARN -Message ('网络不可用（未接入 {0} 或路由未就绪），跳过本次认证' -f $cfg.ssid)
        return 4
    }

    $password = Get-PlainPassword -Encrypted $cfg.passwordDpapi
    $serviceCode = [string]$cfg.service
    $portalHost = $state.PortalHost
    if ([string]::IsNullOrWhiteSpace($portalHost)) { $portalHost = [string]$cfg.portalHost }
    $queryString = $state.QueryString
    if ([string]::IsNullOrWhiteSpace($queryString)) { $queryString = [string]$cfg.queryStringTemplate }

    if ([string]::IsNullOrWhiteSpace($portalHost)) {
        Write-Log -Level ERROR -Message '未能发现认证入口（portalHost）。请确认已连接校园网并手动打开一次认证页。'
        return 4
    }

    $backoffs = @(3, 6, 12)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log -Message ('第 {0}/{1} 次认证尝试（portal={2}, service={3}）' -f $attempt, $MaxAttempts, $portalHost, $serviceCode)

        $login = Invoke-PortalLogin -PortalHost $portalHost -QueryString $queryString `
                                    -UserId $cfg.userId -Password $password -ServiceCode $serviceCode

        if ($login.Ok) {
            Start-Sleep -Seconds 2
            $after = Get-NetState
            if ($after.State -eq 'Online' -or $after.State -eq 'NeedAuth') {
                if ($after.State -eq 'Online') {
                    Write-Log -Level OK -Message '认证成功，网络已放行'
                    return 0
                }
                Write-Log -Level WARN -Message ('认证返回成功但探测仍显示未放行: {0}' -f $after.Detail)
            } else {
                Write-Log -Level WARN -Message ('认证后探测异常: {0}' -f $after.Detail)
            }
        } else {
            Write-Log -Level ERROR -Message $login.Message
        }

        if ($attempt -lt $MaxAttempts) {
            $wait = $backoffs[[Math]::Min($attempt - 1, $backoffs.Count - 1)]
            Start-Sleep -Seconds $wait
            $state = Get-NetState
            if ($state.State -eq 'Online') {
                Write-Log -Level OK -Message '网络已恢复在线'
                return 0
            }
            if ($state.State -eq 'NeedAuth' -and -not [string]::IsNullOrWhiteSpace($state.QueryString)) {
                $queryString = $state.QueryString
                if (-not [string]::IsNullOrWhiteSpace($state.PortalHost)) { $portalHost = $state.PortalHost }
            }
        }
    }

    $msg = '认证失败：已达最大重试次数，请检查账号密码 / 运营商设置'
    Write-Log -Level ERROR -Message $msg
    Show-Toast -Title '校园网自动认证失败' -Message $msg
    return 3
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }

# 被其它脚本 dot-source 时只提供函数，不执行主流程
if ($MyInvocation.InvocationName -ne '.') {
    $code = Invoke-Main
    exit $code
}
