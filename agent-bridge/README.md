# agent-bridge

把你电脑上的 Claude Code / Codex 包装成一个手机 App 能连接的服务。

## 这是什么、不是什么

- **是**：一个跑在你电脑上的小 Node.js 服务，手机发消息过来，它转发给本地的
  `claude` 或 `codex` 命令行工具去执行，再把结果流回手机。
- **不是**：Claude Code / Codex 本身不会跑在手机上——手机只是个遥控器，真正
  干活的还是你这台电脑。所以这台电脑必须开着，服务才能用。

## 前置条件

1. 电脑上已经装好并登录了 [Claude Code](https://claude.com/claude-code)
   和/或 [Codex CLI](https://developers.openai.com/codex/cli)，命令行里
   能直接跑 `claude` / `codex` 才行。
2. 装了 Node.js（18+）。

## 安装

```bash
cd agent-bridge
npm install
cp .env.example .env
```

打开 `.env`，把 `AUTH_TOKEN` 改成一串随机字符串（下面这行帮你生成一个）：

```bash
node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"
```

再把 `AGENT_WORKDIR` 改成你想让它操作的文件夹——**强烈建议专门建一个新文件夹**
给它用，不要指向你的整个用户目录，因为 Claude Code 在这个目录里有读写和执行
命令的权限。

## 启动

```bash
npm start
```

看到 `[agent-bridge] 监听端口 8787` 就是起来了。想测试一下能不能连通：

```bash
curl http://localhost:8787/health
```

## 手机怎么连进来

这台电脑和你的手机不在同一个局域网时（比如你在学校、电脑在宿舍），得靠一个
内网穿透工具让手机能找到这台电脑。推荐 **Tailscale**（免费，两端都装个App登
录同一账号，就能互相访问，比自己配路由器端口转发安全得多）：

1. 电脑和手机都装 [Tailscale](https://tailscale.com/download)，登录同一账号
2. 电脑上 Tailscale 会给你分配一个内网IP（形如 `100.x.x.x`），在 Tailscale
   的应用里能看到
3. 手机 App 里配置的地址就是 `ws://<这个IP>:8787`

这样手机和电脑之间的流量走的是 Tailscale 的加密隧道，不会暴露在公网上。

## 安全提醒（认真看一下）

- `AUTH_TOKEN` 不要用弱密码，这是唯一挡住"谁都能远程操控你电脑执行命令"的
  一道锁
- 默认配置**没有**用 `--dangerously-skip-permissions`，Claude Code 那边用的
  是 `--permission-mode acceptEdits`（自动接受文件改动，但工具范围被
  `--allowedTools` 限定），Codex 那边用的是 `--sandbox workspace-write`
  （能读写 `AGENT_WORKDIR`，但没有完全放开权限）——这两个都不是最高危险等
  级，但依然是"能真的改你文件、跑命令"的权限，不是完全无害
- 电脑本身要注意物理和网络安全（比如系统本身有没有中招），这个服务只是加了
  一层"手机能远程触发"，没法替你兜底电脑本身的安全

## Windows 运行说明（本仓库已适配）

- 前置：Node.js 18+；claude / codex 通过 npm 全局安装，确保终端里能直接跑：
  
pm i -g @anthropic-ai/claude-code @openai/codex
- PowerShell 默认禁止运行脚本，先执行一次：
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
- server.js 已做 Windows 适配：
  - 自动解析 claude.exe / codex.js 的真实路径（避免 Node 无法直接 spawn .cmd）
  - 子进程 stdin 置为忽略（否则 codex 会一直等待 stdin）
  - codex 追加 --skip-git-repo-check（工作目录不是 git 仓库时也能跑）
- 放行防火墙端口 8787（管理员 PowerShell）：
  New-NetFirewallRule -DisplayName "agent-bridge 8787" -Direction Inbound -Protocol TCP -LocalPort 8787 -Action Allow -Profile Any
- Tailscale：电脑的 IP 以 	ailscale status 显示为准（Windows 节点），手机 App 里填 ws://<电脑IP>:8787
- 强烈建议 AGENT_WORKDIR 指向专用空文件夹，不要指向整个用户目录
