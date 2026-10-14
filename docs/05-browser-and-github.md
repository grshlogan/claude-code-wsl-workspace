# 浏览器与 GitHub 凭据

> 前置阅读：[04-guest-debian.md](04-guest-debian.md) 已完成，客户端已可上网

## ⚠️ 先读：GitHub 凭据的风险模型

本方案对 GitHub 凭据的态度是 **"能不放客户端里就不放"**，原因如下：

1. **账号关联风险**。Claude Code 是一个会自主执行 git/fetch/push 的 agent。如果它
   使用的 GitHub 凭据与"运行它的 Claude 账号"绑在同一个环境里，平台侧有能力将
   "某个 Claude 会话"与"某个 GitHub 账号的行为"关联起来。多个账号、多个身份的
   使用者尤其需要注意这一点。
2. **Agent 误操作风险**。OAuth token 一旦对 agent 可见（环境变量、`gh` 已登录态），
   agent 就有能力 push、删分支、开 PR。这不是"会不会发生"的问题，而是"发生时
   有没有兜底"的问题。
3. **凭据泄露面**。token 放在客户端文件系统/keyring 里，意味着任何拿到客户端
   执行权限的进程（包括 agent 自己安装的依赖）都可能尝试读取。

### 推荐架构：凭据与 agent 分离

```
┌─ Windows 宿主 ────────────────────────────────────────┐
│  GitHub 远程仓库所有权、push 权限                       │
│  由"非 Claude 的审查流程/人工"持有                      │
│                                                      │
│  交接方式：文件快照/补丁交换（不共享工作树）             │
│  ┌──────────────┐         ┌───────────────────┐      │
│  │ WSL 客户端    │  快照/   │ Windows 侧        │      │
│  │ Claude Code  │ ──────→ │ git 工作副本       │ ──→ GitHub
│  │ 无任何 GitHub │  审查    │ 人工/其他 agent    │      │
│  │ 凭据         │ ←────── │ 审核+push          │      │
│  └──────────────┘  审查结果 └───────────────────┘      │
└──────────────────────────────────────────────────────┘
```

要点：

- 客户端内只做**本地提交**（`git commit`），从不配置远程凭据
- 代码以"快照/补丁"形式离开客户端，经人工或非 Claude 的 agent 审查后再 push
- 两侧永远不共享工作树或 `.git` 目录
- 本仓库暂不附带这套交接工具的实现（原方案的实现与内部工作流耦合过深），
  上述原则足以自行实现：`git format-patch` / `git bundle` / 目录快照皆可

### 如果确实要在客户端内登录 GitHub

某些工作流（如拉取公共仓库、fork 私有仓库只读）确实需要客户端内的 `gh`。
此时用 `guest/github/setup-guest-github-auth.sh`：

```bash
bash guest/github/setup-guest-github-auth.sh
```

它做到的最低限度安全：

- OAuth token 只进客户端 keyring（libsecret），不落 `gh` 配置文件
- 脚本会显式检查 `hosts.yml` 中**没有**明文 token
- Git 通过 `gh` 作为 credential helper 取凭据，token 不进 `.git/config`
- 浏览器授权步骤由你人工完成，脚本无法也不应代办

**但请理解**：这只解决了"token 不落明文"，没有解决第 1、2 点。若你在意账号
关联，应优先采用上面的分离架构；客户端内登录只用于低风险场景。

## 浏览器：Firefox ESR 专用 profile

浏览器跑在客户端内、走隧道、无 Windows 代理痕迹、无 WebRTC 泄漏。

### 1. 安装 Firefox ESR（root）

```bash
apt-get install -y --no-install-recommends firefox-esr
```

### 2. 部署 profile 与启动器

把仓库 `guest/browser/` 的文件放进客户端：

| 文件 | 目标位置 |
|---|---|
| `claude-browser.sh` | `~/.local/bin/claude-browser`（chmod +x） |
| `claude-browser.desktop` | `~/.local/share/applications/` |
| `mimeapps.list` | `~/.config/mimeapps.list` |
| `claude-settings.json` | `~/.claude/settings.json`（禁用 Claude 自动更新） |
| `firefox-user.js` | `~/.local/share/claude-browser/profile/user.js`（600） |

```bash
install -d -m 700 ~/.local/share/claude-browser/profile
```

`firefox-user.js` 已包含：禁用 WebRTC、禁用 IPv6 DNS、禁用浏览器内 DoH、
**不配置任何代理**（与所有应用一样走系统网络栈，由 nft 层强制进隧道）。

### 3. shell 集成（`~/.bashrc`）

```bash
export BROWSER="$HOME/.local/bin/claude-browser"
export PATH="$HOME/.local/bin:$PATH"
```

Windows 侧用 `host\open-claude-browser.cmd` 打开。

> 浏览器登录（GitHub OAuth、Claude 登录）是**人工操作**。登录状态只存在于
> 客户端 profile 内，不要把 profile 复制到 Windows。
