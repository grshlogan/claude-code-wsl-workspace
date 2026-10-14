# VPS 服务端部署

> 前置阅读：[01-architecture.md](01-architecture.md)

## 前置条件

- 一台你控制的 VPS，Debian 12 (Bookworm)，有 root SSH 权限
- 公网 IPv4（本方案的客户端模板按 IPv4 设计）
- 防火墙/安全组放行 **UDP 51820**（本方案固定的 WG 端口）
- VPS 上已启用 IPv4 转发（下面的步骤会处理）
- VPS 的 SSH 端口保持 22 且运行中（包的校验命令会检查）

> 本方案使用 WG 端口 `51820`、隧道网段 `10.77.42.0/30`（服务端 `.1`，客户端 `.2`）。
> 若需修改，需同时改动 `vps/package` 与 `guest/package` 中的多处校验，不建议。

## 1. 启用 IPv4 转发

```bash
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wg-claude.conf
sysctl --system
sysctl -n net.ipv4.ip_forward   # 必须输出 1
```

## 2. 上传并安装 claude-wg-peer

在本地把 `vps/package/` 打包并传到 VPS：

```bash
# 本地（或在 VPS 上克隆本仓库）
cd vps
dpkg-deb --build package claude-wg-peer_0.1.3_all.deb
scp claude-wg-peer_0.1.3_all.deb root@你的VPS:/root/
```

在 VPS 上安装。安装过程**零副作用**：不建密钥、不改配置、不启服务。

```bash
apt-get install -y wireguard-tools   # 包的依赖，走 VPS 自己的网络
dpkg -i /root/claude-wg-peer_0.1.3_all.deb
```

## 3. 初始化服务端（生成密钥）

```bash
claude-wg-peer init-server --yes
```

这一步会：
- 生成 `/etc/wireguard/wg-claude.key`（0600）和 `.pub`（0644）
- 写入 `/etc/wireguard/wg-claude.conf`（仅 Address/ListenPort，无 peer）
- **不启动任何服务**

取出服务器公钥（下一步客户端配置需要）：

```bash
cat /etc/wireguard/wg-claude.pub
```

## 4. 注册客户端 peer

先完成 [04-guest-debian.md](04-guest-debian.md) 第 6 步，拿到**客户端公钥**
（客户端上 `cat /etc/wireguard/claude.pub`），把它保存为 VPS 上的一个文件再注册：

```bash
echo '客户端公钥' > /root/client.pub
claude-wg-peer register-peer --public-key-file /root/client.pub --yes --restart
```

`--restart` 会启动 `wg-quick@wg-claude` 和转发服务，并自动执行全套校验
（peer 合同、NAT 规则、SSH 存活、默认路由）。校验失败会拒绝执行。

## 5. 验证服务端

```bash
claude-wg-peer verify          # 全套校验
claude-wg-peer status --json   # JSON 状态（不打印密钥）
claude-wg-peer check-firewall  # 仅 NAT/转发规则
claude-wg-peer check-peer      # 仅 peer 合同
```

一切就绪后，回到 [04-guest-debian.md](04-guest-debian.md) 继续客户端点火。

## 运维注意

- **不要**在 VPS 上用 NetworkManager/Cockpit 编辑这个 WG 接口
- 包删除在服务运行时会被拒绝（防止误删正在保护的配置）
- `tools/replace-single-peer.py` 仅用于“已有旧 peer、要换成新客户端”的迁移场景，需要你逐字审阅脚本后手动执行
- VPS 上如有其他业务（如网站），本包只创建自己的 nft 表（`wg_claude_forward`/`wg_claude_nat`），不触碰其他规则
