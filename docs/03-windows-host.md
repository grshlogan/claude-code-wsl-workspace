# Windows 宿主部署

> 前置阅读：[01-architecture.md](01-architecture.md) · 建议先完成 [02-vps.md](02-vps.md) 的第 1–3 步（拿到服务器公钥）

## 前置条件

- Windows 11（Hyper-V 防火墙 API 需要 Win11）
- WSL2（`wsl --version` 建议 ≥ 2.0；需支持 `networkingMode` 等配置项）
- 管理员权限（仅安装 Hyper-V 门卫时需要）

## 1. 拿到本仓库

```powershell
git clone https://github.com/你的用户名/claude-code-wsl-workspace.git
cd claude-code-wsl-workspace
```

## 2. 写配置文件

```powershell
Copy-Item host\lib\config.example.ps1 host\lib\config.ps1
notepad host\lib\config.ps1
```

必填：`$VpsEndpointIp`（你的 VPS IPv4）。可选：SSH 主机密钥 pin（用于恢复工具）、
VS Code 路径（用于编辑器桥）。`config.ps1` 已被 `.gitignore` 忽略，不会提交。

## 3. 进入离线引导状态

客户端的密钥生成和点火必须在**无网状态**下进行（防止配置中途被直连流量污染）。
临时把全局 WSL 切到 `networkingMode=none`：

```ini
# %UserProfile%\.wslconfig —— 引导期间
[wsl2]
networkingMode=none
dnsTunneling=false
autoProxy=false
localhostForwarding=false
firewall=true
```

```powershell
wsl --shutdown
```

> 引导完成后会把 `networkingMode` 改回 `nat`，其余四项保持不变。

## 4. 安装 Hyper-V 门卫（管理员 PowerShell）

```powershell
# 仍在 networkingMode=none 时执行；脚本会自行校验这一点
powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -File <仓库路径>\host\setup\apply-wsl-guard.ps1'"
```

脚本做的事：
- 在 `networkingMode=none` 之外运行会**拒绝执行**
- 创建 5 条出站规则：IPv4 低段 Block、IPv4 高段 Block、IPv6 两段 Block、
  以及唯一一条 Allow（UDP → `$VpsEndpointIp:$VpsWgPort`）
- 规则范围根据 `config.ps1` 自动计算，无需手写 IP
- 设置 WSL 作用域默认策略：入站/出站 Block、loopback 关闭
- 最后自动运行 `setuperify-wsl-guard.ps1` 自检，输出 `HOST_GATE_STATIC_OK` 即通过

## 5. 验证门卫

```powershell
powershell -File host\setup\verify-wsl-guard.ps1
# 期望输出: HOST_GATE_STATIC_OK: ...
```

接下来完成 [04-guest-debian.md](04-guest-debian.md)，之后回到这里。

## 6. 切回日常 NAT 状态

客户端点火成功后，把 `.wslconfig` 的 `networkingMode` 改回 `nat`（其余不变）：

```ini
[wsl2]
networkingMode=nat
dnsTunneling=false
autoProxy=false
localhostForwarding=false
firewall=true
memory=24GB        # 按机器调整
processors=24      # 按机器调整
swap=0
```

```powershell
wsl --shutdown
```

## 7. 日常使用

```text
host\start.cmd              # 日常入口: 五道门卫全过才进 shell
host\start.cmd -CheckOnly   # 只做检查
host\open-claude-browser.cmd # 打开客户端内 Firefox
host\daily\stop-wsl-session.ps1 -ConfirmShutdown   # 安全停机
```

`start.cmd` 的五道门卫（任何一道失败都会拒绝进入，且不会"修复"网络）：

1. **HOST_GATE** — `setup\verify-wsl-guard.ps1` 确认防火墙规则精确匹配 + `.wslconfig` 五项设置正确
2. **GUEST_SERVICES** — 客户端内 `claude-guard` 与 `wg-quick@wg-claude` 服务 active
3. **WIREGUARD** — 最近握手 ≤ 15 分钟、有传输计数
4. **ROUTE_AND_EXIT** — `ip route get 1.1.1.1` 走 wg 接口 + 公网出口 IP == `$VpsEndpointIp`
5. 全过 → 打开交互 shell（不自动启动 Claude/浏览器）

## 可选组件

- **网络健康监控**（计划任务，每 60 秒只读采集）：
  管理员运行 `host\setup\install-network-diagnostics-task.ps1`，日志在 `host\diagnostics\logs\`
- **隧道恢复**：`host\recovery\recover-wireguard.ps1`（诊断；重启动作需要 `-ConfirmRestart`，
  涉及 VPS 的操作还需要 `-ConfirmVpsMaintenance` 和维护窗口名，见 [07-verification.md](07-verification.md)）
- **编辑器桥**：让 Windows 侧 VS Code 只能编辑客户端里的临时 prompt 文件，
  见 `host\daily\claude-editor-bridge.ps1`（不是 Remote-WSL，不装 VS Code Server）
