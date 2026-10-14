# AGENTS.md — AI 代理守则

本文件是给**执行部署的 AI 代理**看的。人类读者请从 [README](README.md) 开始。

## 阅读顺序

1. 本文件（守则与红线）
2. [docs/00-runbook.md](docs/00-runbook.md) —— **唯一的执行路径**，按阶段顺序执行
3. 执行到某阶段需要细节时，才读对应深入文档（02~07），不要通读全部文档再动手

## 执行协议

- **按 runbook 阶段顺序执行，不要跳步、不要合并步骤。**
- 每个检查点必须实际运行命令并比对预期输出。输出不匹配 = 该阶段 FAIL。
- FAIL 时**停止并报告**，报告格式：阶段号、执行的命令、实际输出、runbook 对应的排障链接。
  **禁止自行"修复"后继续**（尤其禁止通过放松配置让检查通过）。
- 每完成一个阶段，向用户输出该阶段的检查点表格（PASS/FAIL + 证据摘要）。
- 所有命令按 runbook 原样执行。不要发明参数、不要省略 `--yes` 类确认参数的含义
  （它们出现表示该操作有副作用，执行前应向用户确认）。

## 红线（任何情况下不得违反）

1. **密钥与凭据**
   - 客户端私钥只在 guest 内生成、只存在 guest 内。禁止读取其内容、禁止复制到
     Windows、禁止写入任何会进 git 的文件。
   - `host/lib/config.ps1` 包含真实 VPS 地址等，禁止提交、禁止在回复中
     完整粘贴。
   - 不要建议用户在 guest 内登录 GitHub（见 docs/05 的风险模型），除非用户明确要求。
2. **失败语义**
   - 任何门卫/检查失败时，唯一正确动作是停止并报告。禁止：停用 `claude_guard`、
     清空 nft 规则、修改 `.wsl` 网络设置绕过检查、启用直连回退。
3. **破坏性操作需用户显式确认**
   - `wsl --unregister`、删除任何 `.vhdx`/`.tar` 备份、VPS 上 `register-peer --restart`
     之外的写操作、`stop-wsl-session.ps1`（会关闭全部 WSL）。
4. **范围约束**
   - 只修改本仓库文件和 runbook 明确列出的系统位置。不要顺手"优化"其他配置。
   - 不安装 runbook 之外的软件包。

## 成功标记速查

| 标记 | 含义 | 产生者 |
|---|---|---|
| `HOST_GATE_STATIC_OK` | 宿主防火墙门卫配置正确 | `host/setup/verify-wsl-guard.ps1` |
| `FILES_OK` | 客户端密钥/配置文件就绪 | `claude-wg-client check-files` |
| `INITIALIZED without activation` | 客户端密钥已生成（未激活） | `claude-wg-client init-client --yes` |
| `ARMED_OFFLINE` | 防火墙+隧道已启用（离线状态） | `claude-wg-client arm-offline --yes` |
| `GUARD_OK` | 客户端防火墙检查通过 | `claude-wg-client check-guard` |
| `INITIALIZED inactive server contract` | VPS 服务端密钥已生成 | `claude-wg-peer init-server --yes` |
| `REGISTERED one peer` | VPS 已登记客户端公钥 | `claude-wg-peer register-peer ...` |
| `VERIFIED` | VPS 全套校验通过 | `claude-wg-peer verify` |
| 五道 `[PASS]` | 启动门卫全过 | `host/start.cmd -CheckOnly` |
