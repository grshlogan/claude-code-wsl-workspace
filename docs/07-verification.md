> 本篇是 Runbook [阶段 H](00-runbook.md) 的深入参考及日常运维手册。

# 验收与排障

## 部署完成后的验收清单

按顺序执行，全部通过才算部署完成：

```text
□ 1. 宿主配置      start.cmd -CheckOnly → 五道检查全部 [PASS]
□ 2. 门卫静态      host\setup\verify-wsl-guard.ps1 → HOST_GATE_STATIC_OK
□ 3. 客户端防火墙  claude-wg-client check-guard → GUARD_OK
□ 4. 隧道握手      wg show wg-claude latest-handshake → < 5 分钟
□ 5. 出口 IP       客户端内 curl https://api.ipify.org → 等于 VPS IP
□ 6. DNS           resolv.conf 只有 1.1.1.1，且域名解析正常
□ 7. 直连拒绝      强制走 eth0 的请求 → 失败/超时
□ 8. IPv6 拒绝     curl -6 https://ipv6.icanhazip.com → 失败
□ 9. 断隧道演练    (可选) 在 VPS 临时 stop wg 服务 → 客户端完全无网(不是直连)
□ 10. 重启演练     wsl --shutdown 后重新 start.cmd → 全部通过
```

### 关键命令速查

```bash
# 客户端内（root）
claude-wg-client status          # 服务/接口/防火墙状态
claude-wg-client check-guard     # GUARD_OK 校验
wg show wg-claude                # 握手/传输计数

# 客户端内（普通用户）
curl --disable -4 https://api.ipify.org    # 期望：VPS IP
curl --disable -6 --max-time 5 https://ipv6.icanhazip.com  # 期望：失败
```

```powershell
# Windows（host/ 目录）
setup\verify-wsl-guard.ps1           # 静态门卫校验
diagnostics\show-network-health.ps1        # 最近健康记录
```

## 深度验收工具

- `host\diagnostics\guest-network-snapshot.py` — 通过 root stdin 送入客户端运行，输出完整
  只读快照（路由、nft 计数器、握手、出口探测），自动分类 PASS / FAIL
- `host\diagnostics\udp-egress-probe.py` — STUN 探测：确认所有 UDP 出口都是 VPS IP，
  直连 eth0 的 UDP 收到 EPERM
- `host\diagnostics\capture-wg-headers.ps1 -ConfirmCapture` — 20 秒内核级抓包，
  证明外层 UDP 只发往 VPS:51820

## 常见故障

| 症状 | 可能原因 | 处理 |
|---|---|---|
| `start.cmd` 报 HOST_GATE 失败 | Hyper-V 规则漂移，或 `.wslconfig` 被改 | 重跑 `setup\apply-wsl-guard.ps1`（须在 networkingMode=none 下），核对 `.wslconfig` |
| GUEST_SERVICES 失败 | 客户端内服务没起来 | `wsl -d <distro> -u root` 进去查 `systemctl status claude-guard wg-quick@wg-claude` |
| 握手超龄 | VPS 侧 peer 丢了或密钥不匹配 | 检查 VPS `claude-wg-peer status --json`；公钥对不上就重新 register |
| 出口 IP 不对 | 路由走了别的接口 | `ip route get 1.1.1.1` 应显示 `dev wg-claude`；查 nft 计数器 |
| DNS 失败 | resolv.conf 被覆盖 | 应只有 `nameserver 1.1.1.1`；确认 `generateResolvConf=false` |
| 完全无网 | 可能是断隧道演练的正常结果 | 恢复 VPS 侧服务，等待握手；不要"修"客户端防火墙 |
| 直连居然通了 | 严重事故：三层防线被破坏 | 立即 `dailystop-wsl-session.ps1 -ConfirmShutdown`，然后逐层排查 |
| `nftables.service` 报错 | 有人启用了系统 nftables | 应保持 masked；只允许 `claude_guard` 表存在 |

## 隧道丢失恢复

`host\recovery\recover-wireguard.ps1` 提供分级的诊断与恢复：

```powershell
recovery\recover-wireguard.ps1                      # 只读检查客户端+服务端状态
recovery\recover-wireguard.ps1 -Mode Client -ConfirmRestart    # 重启客户端隧道
recovery\recover-wireguard.ps1 -Mode Server -ConfirmRestart `
    -ConfirmVpsMaintenance -MaintenanceWindow "upgrade-2026-xx-xx"  # VPS 维护窗口
```

安全机制：
- SSH 只连 config.ps1 里钉死的 host key（指纹不匹配直接拒绝）
- VPS 侧操作强制要求命名维护窗口
- 所有操作写审计日志（`logs/wireguard-recovery.jsonl`）

## 红线（不要做的事）

1. 不要为了"临时上上网"停掉 `claude_guard` 或清空 nft 表
2. 不要在客户端启用 `generateResolvConf` 或第二个 resolver
3. 不要把 `.wslconfig` 改回 mirrored / 开启 localhost 转发
4. 不要将客户端私钥、keyring 内容、浏览器 profile 复制到 Windows
5. 不要让 Windows 和客户端共享同一个 Git 工作目录

