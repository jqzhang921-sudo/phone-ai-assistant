// agent-bridge/server.js
//
// 跑在你自己电脑上的一个小服务：
//   手机 App --(WebSocket, 局域网/Tailscale)--> 这个服务 --(子进程)--> Claude Code / Codex CLI
//
// 核心思路很简单：
//   1. 收到手机发来的一条消息
//   2. 用 child_process 起一个 `claude -p ...` 或 `codex exec ...` 的一次性进程
//   3. 把它的输出（JSON Lines 流）逐行转发回手机
//   4. 进程结束就告诉手机"这轮说完了"
//
// 安全上的几个硬性设计（别绕过）：
//   - 必须带对的 AUTH_TOKEN 才能连接，没有 token 直接断开
//   - Claude Code 默认用 --permission-mode acceptEdits（自动接受文件改动，
//     但不是"什么都不问"的 --dangerously-skip-permissions），并且用
//     --allowedTools 限定了工具范围
//   - Codex 默认用 --sandbox workspace-write（能读写工作目录，但不是
//     danger-full-access）
//   - 所有操作都被限制在 AGENT_WORKDIR 这一个目录里，不要指向你的整个硬盘

require('dotenv').config();
const express = require('express');
const { WebSocketServer } = require('ws');
const { spawn } = require('child_process');
const http = require('http');
const path = require('path');

const PORT = process.env.PORT || 8787;
const AUTH_TOKEN = process.env.AUTH_TOKEN;
const AGENT_WORKDIR = process.env.AGENT_WORKDIR || process.cwd();
const MAX_TURNS = process.env.MAX_TURNS || '15';

if (!AUTH_TOKEN) {
  console.error('[agent-bridge] 缺少 AUTH_TOKEN，去 .env 里设置一个随机字符串再启动。');
  process.exit(1);
}

const app = express();
app.get('/health', (req, res) => res.json({ ok: true }));

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

/**
 * 根据 agent 类型拼出对应的一次性命令行调用。
 * claude: claude -p "<msg>" --output-format stream-json --permission-mode acceptEdits ...
 * codex:  codex exec --json --sandbox workspace-write "<msg>"
 */
function buildCommand(agent, message) {
  if (agent === 'claude') {
    return {
      cmd:
          process.platform === 'win32'
            ? path.join(process.env.APPDATA || '', 'npm', 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe')
            : 'claude',
      args: [
        '-p',
        message,
        '--output-format',
        'stream-json',
        '--verbose',
        '--permission-mode',
        'acceptEdits',
        '--allowedTools',
        'Read,Edit,Write,Bash',
        '--max-turns',
        MAX_TURNS,
      ],
    };
  }
  if (agent === 'codex') {
    if (process.platform === 'win32') {
      return {
        cmd: 'node',
        args: [
          path.join(process.env.APPDATA || '', 'npm', 'node_modules', '@openai', 'codex', 'bin', 'codex.js'),
          'exec',
          '--json',
          '--skip-git-repo-check',
          '--sandbox',
          'workspace-write',
          message,
        ],
      };
    }
    return {
      cmd: 'codex',
      args: ['exec', '--json', '--skip-git-repo-check', '--sandbox', 'workspace-write', message],
    };
  }
  throw new Error(`未知的 agent 类型: ${agent}`);
}

wss.on('connection', (ws) => {
  let authed = false;
  let child = null;

  const kill = () => {
    if (child && !child.killed) {
      child.kill('SIGTERM');
      child = null;
    }
  };

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      ws.send(JSON.stringify({ type: 'error', message: '消息不是合法JSON' }));
      return;
    }

    if (msg.type === 'auth') {
      authed = msg.token === AUTH_TOKEN;
      ws.send(JSON.stringify({ type: 'auth_result', ok: authed }));
      if (!authed) ws.close();
      return;
    }

    if (!authed) {
      ws.send(JSON.stringify({ type: 'error', message: '还没通过认证' }));
      return;
    }

    if (msg.type === 'cancel') {
      kill();
      ws.send(JSON.stringify({ type: 'cancelled' }));
      return;
    }

    if (msg.type === 'chat') {
      const agent = msg.agent === 'codex' ? 'codex' : 'claude';
      const message = String(msg.message || '').trim();
      if (!message) return;

      kill(); // 同一个连接同时只跑一个任务
      let built;
      try {
        built = buildCommand(agent, message);
      } catch (e) {
        ws.send(JSON.stringify({ type: 'error', message: e.message }));
        return;
      }

      ws.send(JSON.stringify({ type: 'started', agent }));

      child = spawn(built.cmd, built.args, {
        cwd: AGENT_WORKDIR,
        env: process.env,
        stdio: ['ignore', 'pipe', 'pipe'],
      });

      let buffer = '';
      child.stdout.on('data', (chunk) => {
        buffer += chunk.toString();
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          // 直接把原始 JSON 行转发给客户端，解析交给 App 那边做
          ws.send(JSON.stringify({ type: 'raw_line', agent, line: trimmed }));
        }
      });

      child.stderr.on('data', (chunk) => {
        ws.send(
          JSON.stringify({ type: 'stderr', agent, text: chunk.toString() }),
        );
      });

      child.on('close', (code) => {
        ws.send(JSON.stringify({ type: 'done', agent, exitCode: code }));
        child = null;
      });

      child.on('error', (err) => {
        ws.send(
          JSON.stringify({
            type: 'error',
            message: `启动 ${built.cmd} 失败：${err.message}（是否装了这个CLI？）`,
          }),
        );
        child = null;
      });
    }
  });

  ws.on('close', kill);
});

server.listen(PORT, () => {
  console.log(`[agent-bridge] 监听端口 ${PORT}，工作目录：${AGENT_WORKDIR}`);
});
