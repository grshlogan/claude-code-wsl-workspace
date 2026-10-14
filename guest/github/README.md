# ⚠️ 先看这里

**这套脚本把 GitHub 凭据装进运行 Claude Code 的环境里。如果在意账号安全，请先阅读 [../../docs/05-browser-and-github.md](../../docs/05-browser-and-github.md) 的风险模型和推荐的"凭据与 agent 分离"架构，再决定是否使用。**

这些脚本解决的只是"token 不落明文"这一个问题（token 只进 libsecret keyring，Git 配置里不出现明文），它不能消除"agent 环境持有 GitHub 凭据"本身的风险。适用场景：拉取公共仓库、低风险账户、以及已评估并接受关联风险的用户。

## 文件

| 文件 | 用途 |
|---|---|
| `setup-guest-github-auth.sh` | 安装向导：装 gh/keyring 依赖、浏览器 OAuth、验证 keyring |
| `guest-keyring.sh` | keyring 解锁与 gh 凭据调用的封装 |
| `test-guest-keyring.sh` | 验证 keyring 路径是否生效 |
| `org.freedesktop.secrets.service` | D-Bus secrets 服务配置 |
