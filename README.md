# ePortal 校园网自动认证

Windows 上用的校园网自动认证脚本。开机（登录）后自动完成认证，
掉线时可手动或按间隔重连，不用再打开浏览器手点一遍。

用 PowerShell 写成，不依赖 Python 或任何第三方库，也不需要管理员权限。

> **适用范围**：采用 **ePortal 网页认证**的校园网 —— 即认证页面为
> `/eportal/index.jsp`、提交接口为 `/eportal/InterFace.do?method=login`
> （返回 JSON，含 `result` / `message` 字段）。
>
> 本项目实测环境的门户页面标题是 `RG-SAM+ Portal组件`，即**锐捷 RG-SAM+** 的
> Portal 组件。需要提醒的是：网上不少项目和教程把这一接口写作「Dr.COM ePortal」，
> 但 Dr.COM 的 Web 认证实际走的是另一套接口（`POST /0.htm`，参数为
> `DDDDD` / `upass` / `0MKKey`），两者并非同一产品，选型时请注意区分。
>
> 不管哪家厂商，只要认证入口与提交接口的形态一致，通常就能用。
> 认证入口地址与 queryString 都在运行时从网关的 302 跳转中自动发现，
> 因此代码里**不含任何学校的硬编码地址**。
> 不同学校、不同版本的门户在参数命名上可能有差异，可能需要少量调整，详见「常见问题」。

---

## 特性

- **状态感知**：先探测是否真的需要认证，已在线时直接退出，不重复提交
- **自动发现认证入口**：从 302 跳转中提取 `portalHost` 与 `queryString`，
  兼容 queryString 被单层 / 多层转义的情况（最多反转义 3 层）
- **凭据加密**：密码用 Windows DPAPI 以「当前用户」作用域加密后落盘，
  换电脑、换用户都无法解密；配置文件中不存在明文密码
- **指数退避重试**：一次运行内最多尝试 3 次，间隔 3s / 6s / 12s，中途若恢复在线立即停止
- **日志轮转**：按天写日志，自动清理 7 天前的文件
- **失败通知**：认证失败时弹出系统通知，不必去翻日志
- **可选巡检**：默认只在登录时执行一次；需要掉线自动重连时可显式开启周期巡检

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11 |
| PowerShell | 5.1（系统自带） |
| 权限 | 普通用户即可，无需管理员 |
| 依赖 | 无 |

---

## 快速开始

把仓库放到任意目录（**建议路径不含中文和空格**），然后在 PowerShell 中执行：

```powershell
# 1. 录入账号、密码、运营商（交互式，密码输入时不回显）
powershell -ExecutionPolicy Bypass -File .\Setup-Credential.ps1

# 2. 安装计划任务（登录时自动认证），并按提示立即试跑一次
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

完成。之后每次登录 Windows，脚本会自动向校园网提交认证。

需要「掉线自动重连」时，用巡检模式重装一次：

```powershell
# 每 30 分钟检查一次，掉线则重连（代价：每 30 分钟会闪一次窗口）
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1 -IntervalMinutes 30
```

### 手动操作

```powershell
# 查看当前状态：网卡 / SSID / IP / 是否在线 / 最近 15 条日志
powershell -ExecutionPolicy Bypass -File .\EportalAutoLogin.ps1 -Status

# 手动跑一次，并把日志打到控制台
powershell -ExecutionPolicy Bypass -File .\EportalAutoLogin.ps1 -Console

# 强制重新认证一次（即使检测到已在线）
powershell -ExecutionPolicy Bypass -File .\EportalAutoLogin.ps1 -Force -Console
```

---

## 配置说明

配置写在 `%LOCALAPPDATA%\EportalAutoLogin\config.json`，由 `Setup-Credential.ps1`
生成，**正常情况下不需要手改**。字段含义：

| 字段 | 说明 |
|---|---|
| `userId` | 校园网账号（学号 / 工号） |
| `passwordDpapi` | DPAPI 加密后的密码。**不要手工填写**，只能用 `Setup-Credential.ps1` 生成 |
| `serviceName` | 运营商显示名，如 `联通` / `电信` / `移动` / `校园网` |
| `service` | 提交给门户的服务代码，常见为 `LT` / `DX` / `YD` / `default` |
| `ssid` | 校园网 WiFi 名称。脚本启动后会等待关联到这个 SSID |
| `portalHost` | 认证入口地址。留空时每次运行自动发现 |
| `queryStringTemplate` | queryString 兜底模板。通常留空即可，认证时会实时取用 |
| `serviceMap` | 可选。运营商名 → 服务代码的映射，用于适配各校自己的命名。`Setup-Credential.ps1` 会把内置映射与本字段合并后供你选择，自定义项也会被写回配置 |

除 `config.json` 外，整个脚本不读写任何其他本地状态。

---

## 工作原理

```
探测探针 (msftconnecttest/redirect, 1.1.1.1)
        │
        ├─ 正常响应 ────────────────► 已认证，退出
        │
        └─ 302 到 /eportal/index.jsp?<queryString>
                    │
                    ├─ 提取 portalHost 与 queryString
                    ├─ GET 认证页，建立 JSESSIONID 会话
                    └─ POST /eportal/InterFace.do?method=login
                                │
                                └─ result == "success" ──► 再次探测确认放行
```

关键点是**先 GET 认证页再 POST**。不少只发 POST 的实现会收到
「当前页面已超时，请重新刷新页面」之类的报错，原因是缺少认证页下发的会话。

---

## 常见问题

**Q：认证一直失败？**

按顺序排查：

1. 手动打开浏览器访问任意网站，看弹出的认证页是否正常。不正常说明是校园网侧的问题。
2. 确认运营商选择正确。`service` 传错时门户会返回明确的拒绝信息，日志里有。
3. 运行 `-Status` 看探测详情，确认真的处于 `NeedAuth` 状态。
4. 若日志提示「未能发现认证入口」，说明网关没按标准方式 302。这时手动打开一次认证页，
   从浏览器地址栏复制完整的 `index.jsp?...` 地址，用 `Setup-Credential.ps1 -PortalHost <地址>` 指定。
5. 若门户回包是 `WEB认证设备未注册，请确认SAM+/portal/设备上的参数配置是否一致`，
   说明提交的 queryString 里缺少网关能识别的接入设备信息（`wlanacname` / `nasip` 等）。
   **这不是脚本的配置错误** —— 这些字段由网关在 302 跳转时下发，所以正确做法是断网后重连，
   让脚本重新自动发现，而不是手工拼一个 queryString。

**Q：每次登录都会闪一下黑框？**

这是 `powershell.exe -WindowStyle Hidden` 的固有限制：系统先创建控制台窗口，
PowerShell 再把它隐藏，中间那一下会露出来。不开启巡检时一天只闪一次。
彻底消除需要改用无窗口宿主（如编译为 exe 或改用 VBS 包装），本仓库未包含。

**Q：同学的学校能用吗？**

只要对方也是同形态的 ePortal 认证（认证页 `/eportal/index.jsp` + 提交接口
`/eportal/InterFace.do`），通常改 `ssid` 就能用。运营商命名不同时用 `serviceMap` 覆盖。
若门户接口路径不是 `/eportal/`，需要改 `EportalAutoLogin.ps1` 里的探测与提交常量。

**Q：怎么卸载？**

```powershell
# 只移除开机自启，保留配置
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1

# 连同配置、加密凭据、日志一起删除
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1 -Purge
```

---

## 免责声明

**使用前请阅读 [DISCLAIMER.md](DISCLAIMER.md)。** 简要说明：

- 本工具**只做一件事**：把你手动登录时会做的动作自动化，提交**你自己的**账号密码。
- 它**不绕过认证**、**不破解**、**不修改认证系统**、**不共享账号**、
  **不突破学校的同时在线设备数限制**。
- 使用前请自行确认符合所在学校的网络管理规定。风险由使用者自行承担。

---

## License

[MIT](LICENSE)
