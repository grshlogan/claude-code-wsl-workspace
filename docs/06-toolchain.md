# 开发工具链

> 前置阅读：客户端已可上网，浏览器/GitHub 已配置

`guest/toolchain/` 里的脚本把客户端打造成完整的开发工作站。所有安装都走隧道
apt / 官方 HTTPS 下载，并在每一步前后校验 `claude-wg-client check-guard`。

## 推荐安装顺序

| 步骤 | 脚本 | 运行身份 | 内容 |
|---|---|---|---|
| 1 | `install-baseline.sh` | root | 基础包：ca-certificates、curl、git、jq、ripgrep、gcc、python3 等 |
| 2 | `install-uv.sh` | 普通用户 | uv（Python 包管理） |
| 3 | `install-node.sh` | 普通用户 | Node.js LTS（仅当前 LTS 大版本） |
| 4 | `install-rust.sh` | 普通用户 | rustup + stable 工具链 |
| 5 | `install-mingw64.sh` | root | MinGW-w64 交叉编译器（可选，面向 Windows 目标） |
| 6 | `install-gui-build-deps.sh` | root | GUI 开发依赖：CMake、Ninja、OpenGL/X11 头文件等（可选） |

版本由 `select-versions.sh` 从官方源（GitHub API / Node dist index / Rust channel）
拉取并锁定，避免"装的时候是什么版本"说不清。

## 校验脚本

| 脚本 | 作用 |
|---|---|
| `preflight-baseline.sh` | 安装前检查受保护文件哈希与 guard 状态 |
| `verify-network.sh` | 验证出口 IP == VPS IP、直连 eth0 被拒、IPv6 被拒 |
| `verify-python-node-c.sh` | 三语言冒烟测试 |
| `verify-node-release.sh` | Node 版本与官方索引一致性 |
| `verify-smoke.sh` | 汇总冒烟结果 |

## 示例项目

- `mingw64-smoke/` — 最小 Windows GUI 交叉编译样例（C + C++ + 资源文件）
- `gui-build-smoke/` — CMake/Ninja 本地 + 交叉构建样例

构建产物拷贝到 Windows 侧运行（客户端内不执行 Windows 程序，interop 保持禁用）。

## 安装纪律

- 用 `--no-install-recommends`，避免依赖膨胀
- 安装前后跑 `check-guard` 确认防火墙未被意外改动
- 项目依赖一律放项目目录（venv / node_modules / Cargo.lock），不做全局替换
- 不升级系统内已有包（`--no-upgrade`），保持环境可复现
- 证据（版本清单、哈希）写入审计目录 `/root/claude-toolchain-audit` 或
  `~/.local/state/claude-toolchain/audit`
