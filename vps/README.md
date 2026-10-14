# vps/ — VPS 服务端（Debian 12）

运行在你自己 VPS 上的 WireGuard 服务端。与客户端是**两套独立的包**，不要装错位置。

## 目录

| 目录 | 内容 |
|---|---|
| `package/` | `claude-wg-peer` .deb 源码：单 peer 合同校验、转发/NAT 防火墙、只读验证命令 |
| `templates/` | 手动部署用的模板文件（与包内一致，供参考或自定义构建） |
| `tools/replace-single-peer.py` | 可选：把已有的单 peer 从旧客户端公钥切换到新公钥 |

## 设计要点

- **单 peer 合同**：VPS 上只允许一个客户端 peer（`10.77.42.2/32`），包的
  `verify`/`check-peer` 命令会强制校验这一点，任何多余 peer 都会导致验证失败。
- **不拥有密钥**：包只提供 systemd drop-in（从 `/etc/wireguard/wg-claude.key`
  加载私钥）、转发防火墙和验证命令；密钥由 `init-server` 在 VPS 本地生成。
- **显式激活**：`init-server` → `register-peer --public-key-file` → （显式重启）
  三步分开执行，包安装本身不改变任何运行状态。

部署步骤见 `docs/02-vps.md`。
