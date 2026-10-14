# Debian 12 客户端部署

> 前置阅读：[03-windows-host.md](03-windows-host.md) 已完成到"离线引导状态"

这是全流程中最讲究的一篇：密钥在客户端内生成、防火墙在无网状态下点火、
最后才切回 NAT。**步骤顺序不要调换。**

## 1. 获取 Debian 12 rootfs

任选一种官方渠道获取 Debian 12 (Bookworm) 的 WSL/容器 rootfs tar：

- Debian 官方 cloud images（genericcloud/amd64 tarball）
- `wsl --install` 的 Debian 发行版再导出（`wsl --export Debian`）
- Docker Hub 官方 `debian:bookworm` 镜像导出

校验你拿到的文件的官方摘要（渠道页面/签名），不要使用来历不明的镜像。

## 2. 离线导入发行版

确认 `.wslconfig` 处于 `networkingMode=none` 且已 `wsl --shutdown`：

```powershell
mkdir E:\WSL\claude-debian12
wsl --import claude-debian12 E:\WSL\claude-debian12 <rootfs.tar.gz> --version 2
wsl -d claude-debian12 -u root -- cd /
```

此时客户端应当**只有 loopback，没有任何 IPv4/IPv6 路由**。验证：

```bash
ip -4 route; ip -6 route   # 都应为空
```

## 3. 系统硬化 + 用户

在客户端内（root）写入 `/etc/wsl.conf`：

```ini
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[network]
generateResolvConf=false

[user]
default=claude
```

创建无 sudo 的普通用户（UID 1000 与文件引用一致）：

```bash
useradd -m -u 1000 -s /bin/bash claude
```

`wsl --terminate claude-debian12` 后重新进入，确认：
`mount` 无 Windows 盘符、`echo $PATH` 无 Windows 路径、`ip route` 仍为空。

## 4. 离线安装依赖包

客户端缺 4 个包：`libnftnl11`、`libnftables1`、`nftables`、`wireguard-tools`。
在**另一台有网的 Debian 12**（或临时容器）上下载：

```bash
# 在有网的 Debian 12 上
apt-get download libnftnl11 libnftables1 nftables wireguard-tools
# 通过 \\wsl.localhost\claude-debian12\tmp\ 或 scp 拷进客户端 /root/offline-debs/
```

在客户端内（root）安装：

```bash
apt-get install -y /root/offline-debs/*.deb   # 离线安装，无网络请求
apt-get clean
```

> 安全起见，可核对每个 .deb 与 Debian 官方软件源的 SHA256（下载页有）。

另外把系统的 `nftables.service` 屏蔽掉——它会在启动时 flush 整个规则表，
与我们的守护表冲突：

```bash
systemctl mask nftables.service
```

## 5. 配置并构建客户端包

回到 **Windows 侧**的仓库目录，把你的 VPS 信息写进包模板：

```powershell
cd guest
sh configure-endpoint.sh <VPS_IP> <服务器公钥>   # 在 WSL Debian 里运行，或任意有 bash 的环境
grep -r "203.0.113.10" package/                   # 应无输出 = 替换干净
```

脚本会替换 `package/` 内的 3 处：`wg-claude.conf`（Endpoint + 服务器公钥）、
`claude-guard.nft`（放行规则）、`claude-wg-client`（CLI 校验字符串）。

构建 .deb（在客户端内执行，或任意 Debian 12 环境）：

```bash
# 把 Windows 侧 guest/package 拷入客户端（例如 /root/build/package）
cd /root/build
dpkg-deb --build package claude-wg-client_0.1.0_all.deb
dpkg -i claude-wg-client_0.1.0_all.deb
```

## 6. 生成客户端密钥（离线）

```bash
claude-wg-client init-client --yes
```

- 在客户端本地生成 0600 私钥 `/etc/wireguard/claude.key`（**永不外传**）
- 生成 0644 公钥 `/etc/wireguard/claude.pub`
- 写入 `/etc/wireguard/wg-claude.conf`（来自包模板）和 `/etc/resolv.conf`（仅 `nameserver 1.1.1.1`）

**取出客户端公钥**，拿到 VPS 上完成 [02-vps.md](02-vps.md) 第 4 步（register-peer）：

```bash
cat /etc/wireguard/claude.pub
```

## 7. 点火（仍处于 networkingMode=none）

```bash
claude-wg-client arm-offline --yes    # 启用守护 + 启动 WG（此刻还不会有握手）
claude-wg-client check-guard          # 期望: GUARD_OK
```

## 8. 切回 NAT 并验收

按 [03-windows-host.md](03-windows-host.md) 第 6 步把 `.wslconfig` 改回 `nat`，
`wsl --shutdown` 后运行：

```powershell
host\start.cmd -CheckOnly
```

五道门卫全绿即部署完成。此后客户端的互联网**只能**通过隧道存在。

## 9. 时区（可选）

客户端默认建议与 VPS 时区一致，且不跟随 Windows：

```bash
timedatectl set-timezone America/Los_Angeles   # 或你选择的时区
```

并在 `/etc/wsl.conf` 追加：

```ini
[time]
useWindowsTimezone=false
```

## 常见坑

| 现象 | 原因 |
|---|---|
| `init-client` 拒绝运行 | 存在路由 = 不在离线状态；先 `wsl --shutdown` 并确认 `networkingMode=none` |
| `arm-offline` 报 nftables 未 mask | 第 4 步的 `systemctl mask` 没做 |
| 点火后无握手 | VPS 未 register-peer，或两侧公钥抄错 |
| 握手有了但上不了网 | VPS 端 `net.ipv4.ip_forward` 未开，或转发服务未启动 |
| `wsl --shutdown` 后门卫失效 | 正常情况不会；若发生见 [07-verification.md](07-verification.md) |
