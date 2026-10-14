# guest/ — Debian 12 客户端

运行在 WSL2 Debian 12 发行版内的一切。

## 目录

| 目录 | 内容 | 是否含隐私 |
|---|---|---|
| `package/` | `claude-wg-client` .deb 源码：出站防火墙 `claude_guard`、WireGuard 模板、CLI | 否（已脱敏） |
| `browser/` | Firefox ESR 独立 profile 配置：启动器、桌面入口、`user.js` | 否 |
| `github/` | gh OAuth → keyring 脚本（**不推荐**，见 docs/05 的凭据分离建议） | 否 |
| `loopback/` | 可拆卸的 guest loopback 放行覆盖（调试用） | 否 |
| `toolchain/` | 开发工具链安装与验收脚本 | 否 |
| `configure-endpoint.sh` | 把你的 VPS 地址/端口/服务器公钥写入包模板 | 否 |

## 快速说明

- `package/` 中的模板使用 RFC 5737 文档地址 `203.0.113.10` 和全零占位公钥。
  **部署前必须运行** `./configure-endpoint.sh <VPS_IP> <服务器公钥>` 替换。
- 客户端私钥由 `claude-wg-client init-client --yes` 在 guest 内部生成，权限
  `0600`，root 所有——它**永远不会**出现在这个仓库或任何导出物里。
- 安装包不会自动联网、不会写 DNS、不会启动服务；点火（`arm-offline`）必须在
  `networkingMode=none` 的离线状态下完成。详见 `docs/04-guest-debian.md`。
