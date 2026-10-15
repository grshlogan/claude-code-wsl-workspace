# 00 · 部署 Runbook（唯一执行路径）

> AI 代理请先读根目录 [AGENTS.md](../AGENTS.md)。人类读者可顺序执行。
> 本文件是**唯一的执行顺序**；docs/02~07 是各阶段的深入参考，遇到问题再查。
>
> 实例命名：本文示例沿用的 `claude-debian12` 是开发者（作者本机）的实例名；
> 你可以用任何名字，只要在 `config.ps1` 里写明，全部工具照常工作。
>
> 符号约定：每步给出【命令】【预期】【失败时】三要素。预期不符即该阶段 FAIL，
> 停止并按"失败时"链接排查，不要继续。

## 总览

| 阶段 | 内容 | 深入文档 |
|---|---|---|
| A | 准备与自检（无系统变更） | — |
| B | VPS 服务端（部分） | [02](02-vps.md) |
| C | Windows 宿主进入离线状态 | [03](03-windows-host.md) |
| D | 客户端导入与硬化（离线） | [04](04-guest-debian.md) |
| E | 客户端包与密钥（离线） | [04](04-guest-debian.md) |
| F | VPS 登记公钥 + 客户端点火（离线） | [02](02-vps.md) |
| G | 恢复 NAT + 首次门卫验收 | [03](03-windows-host.md) |
| H | 端到端验收 | [07](07-verification.md) |

---

## 阶段 A：准备与自检

**A1** 确认宿主环境

```powershell
wsl --version          # 需要 WSL2，版本号 ≥ 2.0
$PSVersionTable.PSVersion.Major   # ≥ 5
```

【预期】能输出版本号。 【失败时】先升级 WSL：`wsl --update`。

**A2** 获取仓库并写配置（不提交）

```powershell
git clone <本仓库URL> ; cd claude-code-wsl-workspace
Copy-Item host\lib\config.example.ps1 host\lib\config.ps1
notepad host\lib\config.ps1    # 填入真实 $VpsEndpointIp
```

【预期 / 检查点 A】

- [ ] `host/lib/config.ps1` 存在，且 `$VpsEndpointIp` ≠ `203.0.113.10`
- [ ] `git status` 不显示 config.ps1（确认 .gitignore 生效）

**A3** 准备物料：Debian 12 rootfs tar（官方渠道，校验哈希）、
另一台有网 Debian 12 用于下载 4 个离线依赖包（见 D5）。

---

## 阶段 B：VPS 服务端（第一步）

**B1** 启用 IPv4 转发（VPS root）

```bash
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wg-claude.conf && sysctl --system
sysctl -n net.ipv4.ip_forward
```

【预期】输出 `1`。

**B2** 构建、上传、安装（本地 → VPS）

```bash
cd vps && dpkg-deb --build package wg-peer.deb && scp wg-peer.deb root@<VPS>:/root/
# VPS 上：
apt-get install -y wireguard-tools && dpkg -i /root/wg-peer.deb
```

**B3** 初始化服务端密钥（VPS）

```bash
claude-wg-peer init-server --yes
cat /etc/wireguard/wg-claude.pub   # 记下服务器公钥，E 阶段要用
```

【预期】`INITIALIZED inactive server contract`。
【失败时】[02-vps.md](02-vps.md) — 已有旧配置时不会覆盖，需人工决策。

**检查点 B**

- [ ] `claude-wg-peer status --json` 输出 JSON 且 `"interface_state":"down"`（尚未激活，正常）
- [ ] 服务器公钥已抄录（44 位 base64）

---

## 阶段 C：Windows 宿主进入离线状态

**C1** 写离线引导用的 `.wslconfig`

```ini
# %UserProfile%\.wslconfig
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

**C2** 安装宿主门卫（管理员 PowerShell）

```powershell
powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -File <仓库>\host\setup\apply-wsl-guard.ps1'"
```

【预期】输出 `HOST_GATE_STATIC_OK`。
【失败时】[03-windows-host.md §4](03-windows-host.md)。

**检查点 C**

- [ ] `host\setup\verify-wsl-guard.ps1` → `HOST_GATE_STATIC_OK`

---

## 阶段 D：客户端导入与硬化（全程离线）

**D1** 导入发行版

```powershell
mkdir E:\WSL\claude-debian12
wsl --import claude-debian12 E:\WSL\claude-debian12 <rootfs.tar> --version 2
```

**D2** 验证无路由（关键离线前提）

```powershell
wsl -d claude-debian12 -u root -- ip -4 route ; wsl -d claude-debian12 -u root -- ip -6 route
```

【预期】两者均无输出（只有 loopback）。
【失败时】确认 `.wslconfig` 的 `networkingMode=none` 已生效并 `wsl --shutdown` 重试。

**D3** 写入 `/etc/wsl.conf`（systemd、禁 automount/interop/解析器生成、默认用户），
创建用户：`useradd -m -u 1000 -s /bin/bash claude`，然后 `wsl --terminate claude-debian12`。

**D4** 离线验证硬化结果

```bash
mount | grep -i drvfs        # 无输出
echo $PATH | grep -i windows # 无输出
```

**D5** 离线安装 4 个依赖包并屏蔽系统 nftables

```bash
apt-get install -y /root/offline-debs/*.deb   # libnftnl11 libnftables1 nftables wireguard-tools
systemctl mask nftables.service
```

【检查点 D】

- [ ] `systemctl is-enabled nftables.service` → `masked`
- [ ] `which wg nft` 都有输出

---

## 阶段 E：客户端包与密钥（仍离线）

**E1** 写入端点（仓库目录，任意有 bash 的环境）

```bash
cd guest
sh configure-endpoint.sh <VPS_IP> "<服务器公钥>"
```

【预期】`configure-endpoint: OK`。 【检查】`grep -r 203.0.113.10 package/` 无输出。

**E2** 拷入客户端、构建、安装

```bash
dpkg-deb --build package wg-client.deb && dpkg -i wg-client.deb
```

**E3** 生成密钥（离线）

```bash
claude-wg-client init-client --yes    # → INITIALIZED without activation
claude-wg-client check-files          # → FILES_OK
cat /etc/wireguard/claude.pub         # 客户端公钥，F 阶段要用
```

【检查点 E】

- [ ] `FILES_OK`
- [ ] 客户端公钥已抄录

---

## 阶段 F：登记公钥 + 点火（仍离线）

**F1** VPS 登记客户端公钥

```bash
echo '<客户端公钥>' > /root/client.pub
claude-wg-peer register-peer --public-key-file /root/client.pub --yes --restart
```

【预期】`REGISTERED one peer` 且随后 `VERIFIED`（--restart 会自动全套校验）。
【失败时】[02-vps.md §4](02-vps.md) — 常见：VPS 未开 SSH 22 或 ip_forward 未生效。

**F2** 客户端点火（仍处 networkingMode=none，无握手属正常）

```bash
claude-wg-client arm-offline --yes    # → ARMED_OFFLINE
claude-wg-client check-guard          # → GUARD_OK
```

【检查点 F】

- [ ] `ARMED_OFFLINE` 且 `GUARD_OK`

---

## 阶段 G：恢复 NAT + 首次验收

**G1** `.wslconfig` 改回 `networkingMode=nat`（其余四项不动），`wsl --shutdown`。

**G2** 首次门卫验收

```powershell
host\start.cmd -CheckOnly
```

【预期】五道检查全部 `[PASS]`。
【失败时】[07-verification.md](07-verification.md) 故障表。

**检查点 G**

- [ ] 五道 `[PASS]`：HOST_GATE / GUEST_SERVICES / WIREGUARD / ROUTE_AND_EXIT / 启动

---

## 阶段 H：端到端验收

| # | 检查 | 命令 | 预期 |
|---|---|---|---|
| H1 | 出口 IP | 客户端内 `curl --disable -4 https://api.ipify.org` | == VPS IP |
| H2 | DNS | `resolv.conf` 内容 + `curl https://1.1.1.1` | 仅 1.1.1.1 且可解析 |
| H3 | 直连拒绝 | 强制 eth0 的请求 | 失败/超时 |
| H4 | IPv6 拒绝 | `curl -6 https://ipv6.icanhazip.com` | 失败 |
| H5 | 断隧道演练（可选） | VPS 临时停 wg → 客户端无网（**非直连**） | 恢复后 H1 仍通过 |
| H6 | 重启演练 | `wsl --shutdown` → `host\start.cmd -CheckOnly` | 五道 PASS |

【检查点 H】全部勾选后，部署完成。日常入口：`host\start.cmd`。

---

## 完成后

- 日常使用：[host/README.md](../host/README.md)
- 监控/排障/恢复：[07-verification.md](07-verification.md)
- 浏览器与 GitHub 凭据决策：[05-browser-and-github.md](05-browser-and-github.md)
