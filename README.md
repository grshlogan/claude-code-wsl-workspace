# claude-code-wsl-workspace

一个**可复刻的隔离 Claude Code 开发环境**：在 Windows 上用 WSL2 运行 Debian 12 客户端，所有网络流量强制走你自己 VPS 上的 WireGuard 隧道，出站默认全部拒绝（fail-closed），浏览器、凭据与项目文件全部留在 Linux 客户端内部。

这不是一个"翻墙工具"或"匿名方案"，而是一套**网络边界工程**：它把 Claude Code 的运行环境与 Windows 日常应用隔离开，并把客户端的互联网出口收窄到"仅一条 WireGuard 隧道"。

> ⚠️ **免责声明**：这套方案的目标是环境一致性与最小网络面，它**不是**防封号承诺，也**不是**身份隐匿保证。Windows 与 WSL 管理员始终可以检查或更改该环境。是否遵守 Anthropic 服务条款，责任在使用者自己。

---

## 架构总览

```
┌─────────────────────────── Windows 宿主 ───────────────────────────┐
│                                                                    │
│  start.cmd → start-claude-session.ps1                              │
│    ├─ ① 校验 .wslconfig（NAT + 关闭 DNS 隧道/autoProxy/端口转发）    │
│    ├─ ② 校验 Hyper-V 防火墙门卫（WSL 出站默认 Block，仅放行隧道）     │
│    ├─ ③ 校验 WSL 内 claude-guard / wg-quick 服务状态                │
│    ├─ ④ 校验 WireGuard 握手新鲜度 + 路由 + 出口 IP == VPS IP         │
│    └─ ⑤ 全部通过后才打开交互式 shell（不自动启动 Claude Code）        │
│                                                                    │
│  ┌──────────────── WSL 全局 Hyper-V 防火墙（宿主侧门卫）───────────┐  │
│  │  WSL 出站：默认 Block                                          │  │
│  │  仅放行：UDP → <VPS_IP>:51820（WireGuard 外层）                 │  │
│  │  IPv6：全部 Block；loopback 转发：关闭                          │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌──────────── WSL2: Debian 12 客户端（claude-debian12）──────────┐  │
│  │  普通用户 claude（无 sudo）                                    │  │
│  │  ├─ nftables claude_guard：出站默认 drop，仅放行 wg-claude 接口 │  │
│  │  ├─ wg-quick@wg-claude：AllowedIPs 0.0.0.0/0，FwMark 0xc1a0   │  │
│  │  ├─ 私钥仅存于客户端 /etc/wireguard/（0600，root 所有）         │  │
│  │  ├─ Firefox ESR 独立 profile（关 WebRTC/IPv6，无宿主代理）      │  │
│  │  ├─ GitHub 凭据：gh OAuth → 客户端 keyring（libsecret）        │  │
│  │  └─ 禁用 DrvFs 挂载 / Windows 互操作 / Windows PATH 注入       │  │
│  └──────────────────────────┬────────────────────────────────────┘  │
└─────────────────────────────┼───────────────────────────────────────┘
                              │ UDP 51820（唯一出站通道）
                              ▼
                 ┌─────────────────────────┐
                 │  你的 VPS（Debian 12）   │
                 │  claude-wg-peer 包：     │
                 │  ├─ 单 peer 合同校验      │
                 │  ├─ nftables 转发/NAT    │
                 │  └─ 只读验证命令          │
                 └────────────┬────────────┘
                              ▼
                        互联网（VPS 出口 IP）
```

**三层防线，全部默认拒绝：**

| 层 | 机制 | 默认策略 |
|---|---|---|
| Windows 宿主 | Hyper-V 防火墙（WSL 作用域） | 出站 Block，仅 1 条 UDP 放行 |
| Linux 客户端 | nftables `claude_guard`（priority -300） | 出站 drop，仅放行 `wg-claude` 接口 |
| 隧道本身 | WireGuard，AllowedIPs 0.0.0.0/0 | 只有持有密钥的 peer 能通信 |

任何一层失效，流量都不会落到直连路径上——没有"降级直连"的回退逻辑，这是设计原则。

## 特性

- **从零可复刻**：文档覆盖 VPS → Windows 宿主 → WSL 客户端 → 浏览器/GitHub → 验收的全流程
- **离线引导**：客户端初始配置在 `networkingMode=none` 下完成，密钥从不在客户端之外出现
- **每日启动门卫**：五道检查（宿主配置、防火墙、服务状态、握手、出口 IP），失败即拒绝进入
- **故障恢复工具**：隧道丢失检测、诊断快照、恢复流程（带维护窗口审批）
- **GitHub 凭据可选隔离**：推荐“客户端只做本地提交、远程凭据留在 Windows 侧人工审查后 push”的分离架构；如确需客户端内登录，token 只进 keyring 不落明文
- **VS Code 桥（可选）**：Windows 侧编辑器只能改客户端里的临时 prompt 文件，不是远程开发服务
- **开发工具链**：Python/uv、Node.js、Rust、C、FFmpeg、MinGW64 交叉编译，安装脚本可复用

## 快速开始

完整流程见 [docs/](docs/)，按顺序：

1. [架构与安全模型](docs/01-architecture.md) —— 先读这个，理解每层防线
2. [VPS 服务端](docs/02-vps.md) —— 准备一台 Debian 12 VPS，装 `claude-wg-peer`
3. [Windows 宿主](docs/03-windows-host.md) —— WSL2 配置、Hyper-V 门卫、`config.ps1`
4. [Debian 客户端](docs/04-guest-debian.md) —— 离线导入发行版、装客户端包、点火
5. [浏览器与 GitHub](docs/05-browser-and-github.md) —— Firefox profile + keyring OAuth
6. [开发工具链](docs/06-toolchain.md) —— Python/Node/Rust/C 基线
7. [验收与排障](docs/07-verification.md) —— 每日门卫、出口验证、常见故障

## 目录结构

```
├── README.md                 本文件
├── docs/                     中文部署文档（按编号阅读）
├── host/                     Windows 宿主侧脚本（PowerShell/cmd）
│   ├── start.cmd             日常入口
│   ├── lib/                  共享配置与公共函数（config.example.ps1 在此）
│   ├── setup/                一次性安装：Hyper-V 门卫、监控计划任务
│   ├── daily/                每次会话：启动/停机/编辑器桥
│   ├── diagnostics/          观测验证：健康记录、快照、STUN 探测、抓包
│   └── recovery/             隧道故障恢复（分级审批）
├── guest/                    Debian 12 客户端侧
│   ├── configure-endpoint.sh 把 VPS 地址/公钥写入客户端包模板
│   ├── package/              claude-wg-client .deb 源码（Debian 打包格式）
│   ├── browser/              Firefox ESR 独立 profile 配置
│   ├── github/               gh OAuth → keyring 安装脚本（附风险说明）
│   ├── loopback/             可拆卸的客户端 loopback 放行覆盖
│   └── toolchain/            开发工具链安装与验收脚本
└── vps/                      VPS 服务端
    ├── package/              claude-wg-peer .deb 源码
    ├── templates/            手动部署用模板（与包内容一致）
    └── tools/                单 peer 切换工具（可选）
```

## 设计原则

1. **Fail-closed**：任何组件失败时，结果必须是"没有网络"，而不是"绕过限制"
2. **最小放行面**：宿主侧 1 条 UDP 放行；客户端侧 1 个接口放行；隧道侧 1 个 peer
3. **显式优于自动**：密钥生成、点火、激活、peer 注册全部需要 `--yes` 显式确认
4. **密钥不出客户端**：私钥只存在于客户端文件系统（0600/root），从不出现在 Windows、Git 或聊天记录
5. **不共享工作树**：Windows 与客户端各自独立 Git checkout，只交换提交

## 适用与不适用

**适用**：想要一个与 Windows 日常应用隔离、网络出口可控、可重复搭建的 Claude Code / AI 编码环境。

**不适用**：
- 追求匿名性或规避平台风控（本方案不做也不应做此承诺）
- 需要在客户端内直接访问 Windows 文件或程序的场景（互操作被刻意禁用）
- 多人共用的服务器（单 peer 合同，1 客户端 : 1 VPS）

## License

[MIT](LICENSE)
