# 架构与安全模型

## 三层防线

本方案把"软件能上网"的决策拆成三层独立控制，任何一层说"不行"，流量就走不出去：

```
应用 (Claude/Firefox/curl)
   │
   ▼
┌─────────────────────────────────────────────────────────┐
│ 第一层：Linux 客户端 nftables (claude_guard)             │
│  hook: output, priority -300, policy: drop              │
│  允许: IPv4 经 wg-cla 接口出站                           │
│  允许: 标记 0xc1a0 的 IPv4 UDP → VPS:51820 (WG 外层)     │
│  拒绝: 所有 IPv6 出站；其余全部 drop                      │
└─────────────────────────────────────────────────────────┘
   │  只有一条路: WireGuard 隧道
   ▼
┌─────────────────────────────────────────────────────────┐
│ 第二层：WireGuard 隧道                                   │
│  AllowedIPs = 0.0.0.0/0 (全部流量进隧道)                 │
│  私钥只在客户端 /etc/wireguard/claude.key (0600)         │
│  FwMark 0xc1a0: 内核 WG 套接字自身流量用标记逃出第一层     │
└─────────────────────────────────────────────────────────┘
   │  UDP 到 VPS:51820 (唯一物理出口)
   ▼
┌─────────────────────────────────────────────────────────┐
│ 第三层：Windows Hyper-V 防火墙 (WSL 作用域)               │
│  默认: WSL 入站/出站全部 Block, loopback 关闭             │
│  唯一放行: UDP → VPS IP:51820                            │
│  IPv4 按 VPS 地址拆成两段 Block (低段/高段)               │
│  IPv6 全部 Block                                        │
└─────────────────────────────────────────────────────────┘
   │
   ▼
互联网 ← VPS NAT 出口 (claude-wg-peer, 单 peer 合同)
```

## 禁止"降级直连"

大多数 VPN 配置的失败模式是"隧道断了就走默认路由"——这正是要避免的。本方案的约定：

- 隧道断 → `claude_guard` 的出站规则不变 → 所有应用流量 **drop**（没有网，而不是直连）
- `claude_guard` 挂了 → Hyper-V 层仍然只放行 WG 端口的 UDP → 应用流量依然出不去
- Hyper-V 层挂了 → 客户端 nft 层仍然兜底
- 两层都挂 → 需要管理员权限才可能发生，那已经不在威胁模型内

DNS 同样被锁死：`/etc/resolv.conf` 只有一个 `nameserver 1.1.1.1`，而 1.1.1.1 只能通过隧道到达。Windows 侧关闭了 `dnsTunneling`、`autoProxy` 和 `localhostForwarding`，客户端关闭了 `generateResolvConf`。

## 关键设计决策

| 决策 | 理由 |
|---|---|
| WG 外层流量用 FwMark 逃过 nft 层 | 否则 WG 自身的 UDP 也会被自己的 output 链 drop，死锁 |
| nft 链 priority -300 | 早于绝大多数其他链，先说"不" |
| Hyper-V 用地址分段而非单条 Block | `Block 0.0.0.0-除VPS外` 无法用一条规则表达；拆成低/高两段 |
| 单 peer 合同（VPS 端） | 一台 VPS 服务一个客户端；包的 verify 命令会拒绝多 peer |
| 密钥只在客户端生成 | `init-client` 在离线状态下生成 0600 私钥；公钥人工带到 VPS 注册 |
| 安装包零副作用 | 两个 .deb 安装时都不写密钥、不配 DNS、不启服务、不动路由 |
| 显式 `--yes` | 所有改变网络状态的操作都要求人工确认参数 |

## 隔离面：客户端内部

除了网络，客户端还隔离了文件系统和进程环境（`/etc/wsl.conf`）：

```ini
[automounter]
enabled=false          # 不挂载 Windows 盘符
mountFsTab=false

[interop]
enabled=false          # 不能执行 .exe
appendWindowsPath=false # Windows PATH 不注入

[network]
generateResolvConf=false

[boot]
systemd=true
```

效果：Claude Code 及其子进程看不到 Windows 文件、调不了 Windows 程序、没有 Windows 代理变量。项目、Git 凭据、浏览器 profile 全部留在 ext4 内。

**边界说明**：这是 WSL 用户/进程级隔离，不是虚拟机级隔离。Windows 管理员（或被攻陷的 Windows 主机）始终可以读取客户端内存和磁盘。要完整隔离需要额外的虚拟化层，本方案不承诺这一点。

## 威胁模型

**防得住：**
- 应用进程意外直连（三层任何一层都能单独挡住）
- DNS 泄漏到 Windows 或本地网关
- WebRTC/QUIC 等绕过代理的尝试（IPv6 被 drop，UDP 只剩 WG 端口）
- 供应链来的恶意依赖偷偷外传数据（出口只有你的 VPS）
- 客户端内的凭证被 Windows 侧普通进程读到

**防不住：**
- Windows 管理员级别的窥探（Hyper-V 主机边界之外）
- VPS 提供商/司法管辖层面的风险
- 你自己把密钥或 token 复制出去
- WSL 内核/Windows 自身的漏洞

## 与传统方案的对比

| 维度 | "Clash/代理 + 环境变量" | 本方案 |
|---|---|---|
| 流量拦截点 | 应用自愿读取代理变量 | 内核层强制 |
| DNS | 常泄漏 | 锁定隧道内 resolver |
| IPv6 | 常漏 | nft + Hyper-V 双层 drop |
| 失败模式 | 直连（危险） | 无网（安全） |
| 凭据 | 常混在 Windows | 只在客户端 ext4 |
| 可复现 | 靠记忆 | 文档 + 脚本 + 校验命令 |
