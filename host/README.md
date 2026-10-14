# host/ — Windows 宿主侧

Windows 侧不运行 Claude 本身，只负责三件事：**门卫**（启动前校验）、**入口**（受保护的启动/停止）、**观测与恢复**。

## 目录导览（按使用频率排列）

```
host/
├── start.cmd                  ★ 日常入口（唯一需要记住的命令）
├── open-claude-browser.cmd    ★ 在客户端内打开 Firefox
│
├── lib/                       共享库（不需要直接运行）
│   ├── config.example.ps1     ← 复制为 config.ps1 并填写你的 VPS 信息
│   ├── load-config.ps1        配置加载器（config.ps1 存在则用之，否则用模板）
│   └── wsl-runtime.ps1        进程执行/生命周期互斥锁等公共函数
│
├── setup/                     一次性安装（装完不再碰）
│   ├── apply-wsl-guard.ps1    安装 Hyper-V 门卫防火墙（管理员，需离线状态）
│   ├── verify-wsl-guard.ps1   门卫只读校验（start.cmd 每次启动也会调用）
│   └── install-network-diagnostics-task.ps1  注册 60 秒健康监控计划任务（可选）
│
├── daily/                     每次会话使用
│   ├── start-claude-session.ps1  start.cmd 的实际实现：五道门卫 + 交互 shell
│   ├── stop-wsl-session.ps1      安全停机（-ConfirmShutdown）
│   └── claude-editor-bridge.ps1  VS Code 编辑器桥（可选）
│
├── diagnostics/               观测与验证（日常排障）
│   ├── show-network-health.ps1   查看最近健康记录（最常用）
│   ├── watch-network-health.ps1  采集健康记录（计划任务自动运行）
│   ├── guest-network-snapshot.py 客户端内只读快照（路由/防火墙计数器/出口）
│   ├── udp-egress-probe.py       STUN 探测：确认 UDP 出口只指向 VPS
│   ├── capture-wg-headers.ps1    20 秒内核抓包（需 -ConfirmCapture）
│   └── network-test-watchdog.ps1 网络测试安全网：600 秒无确认则恢复离线
│
└── recovery/                  隧道故障恢复
    ├── recover-wireguard.ps1     诊断/恢复（分级审批，见下）
    └── wireguard-recovery-peer.py 配套的只读探测助手（经 stdin 注入执行）
```

## 使用路径

**第一次安装**（按顺序）：配置 → 门卫 → 客户端部署（见 docs/03、04）→ 装回 NAT。

**每天**：`start.cmd` → 门卫全绿自动进入 shell → 工作完 `stop-wsl-session.ps1 -ConfirmShutdown`。

**怀疑网络有问题**：`diagnostics\show-network-health.ps1` 看趋势 → 不明确就跑 `diagnostics\guest-network-snapshot.py`（经 recover 或手工 stdin 注入）→ 确认隧道断了走 `recovery\recover-wireguard.ps1`。

## 配置

```powershell
Copy-Item lib\config.example.ps1 lib\config.ps1
notepad lib\config.ps1
```

| 变量 | 含义 |
|---|---|
| `$WslDistro` | WSL 发行版名（默认 `claude-debian12`） |
| `$LinuxUser` / `$LinuxHome` | 客户端内的普通用户与家目录 |
| `$VpsEndpointIp` / `$VpsWgPort` | VPS 地址与 WireGuard 端口 |
| `$VpsSshHostKey` / `$VpsSshFingerprint` | SSH 主机密钥 pin（recovery 用，可留空） |
| `$BridgeStopScript` | 停机前可选钩子脚本 |
| `$VsCodePath` | 编辑器桥使用的 VS Code 路径 |
| `$WslMemory` / `$WslProcessors` | 网络测试看门狗恢复离线态时的资源配置 |

未创建 `config.ps1` 时回退到模板默认值（文档示例 IP `203.0.113.10`），只适合只读检查，不能用于真实运行。**`config.ps1` 不会被提交。**

## 门卫五道检查（start.cmd 自动执行）

1. **HOST_GATE** — Hyper-V 规则与 `.wslconfig` 精确匹配
2. **GUEST_SERVICES** — 客户端内两个服务 active
3. **WIREGUARD** — 握手 ≤ 15 分钟且有流量
4. **ROUTE_AND_EXIT** — 路由走 wg 接口且出口 IP == `$VpsEndpointIp`
5. 全过才开 shell；任何一道失败即退出，绝不"自动修复"

## 环境变量与参数

Python 诊断脚本的期望出口 IP 通过**命令行首参数**传入（调用方从 config 自动带出）；
`udp-egress-probe.py` 另接受 `--expected-exit`。也支持 `CLAUDE_VPS_ENDPOINT_IP`
环境变量作为后备。缺省值为文档示例 IP，仅适合只读检查。
