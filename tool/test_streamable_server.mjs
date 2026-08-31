// 最小 Streamable HTTP MCP server，用来验证 Dart 客户端
// 故意让 initialize 走 application/json，tools/list 走 SSE，两条分支都测到
import { createServer } from 'node:http';

const SESSION = 'test-session-abc123';

const TOOLS = [
  { name: 'echo', description: '原样返回', inputSchema: { type: 'object', properties: { text: { type: 'string' } } } },
  { name: 'add',  description: '两数相加', inputSchema: { type: 'object', properties: { a: { type: 'number' }, b: { type: 'number' } } } },
];

const srv = createServer((req, res) => {
  if (req.method === 'DELETE') { res.writeHead(200).end(); return; }
  if (req.method !== 'POST') { res.writeHead(405).end(); return; }

  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    let msg;
    try { msg = JSON.parse(body); } catch { res.writeHead(400).end('bad json'); return; }

    const log = (t) => console.log(`  ${t}  sid=${req.headers['mcp-session-id'] ?? '-'}  ver=${req.headers['mcp-protocol-version'] ?? '-'}`);

    // 通知：无 id，返回 202 空体
    if (msg.id === undefined) {
      log(`NOTIFY ${msg.method}`);
      res.writeHead(202).end();
      return;
    }

    const reply = (result) => ({ jsonrpc: '2.0', id: msg.id, result });

    if (msg.method === 'initialize') {
      log('initialize -> json');
      const payload = reply({
        protocolVersion: '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'test-streamable-server', version: '0.1.0' },
      });
      res.writeHead(200, { 'Content-Type': 'application/json', 'Mcp-Session-Id': SESSION });
      res.end(JSON.stringify(payload));
      return;
    }

    if (msg.method === 'tools/list') {
      log('tools/list -> SSE');
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      // 先塞一条无关的通知和一条注释，验证客户端会跳过它们
      res.write(': keep-alive\n\n');
      res.write(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/progress', params: { progress: 1 } })}\n\n`);
      setTimeout(() => {
        res.write(`event: message\ndata: ${JSON.stringify(reply({ tools: TOOLS }))}\n\n`);
        res.end();
      }, 120);
      return;
    }

    if (msg.method === 'tools/call') {
      log(`tools/call ${msg.params?.name} -> json`);
      const { name, arguments: args } = msg.params ?? {};
      let text;
      if (name === 'echo') text = String(args?.text ?? '');
      else if (name === 'add') text = String((args?.a ?? 0) + (args?.b ?? 0));
      else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32602, message: `没有这个工具: ${name}` } }));
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(reply({ content: [{ type: 'text', text }] })));
      return;
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'method not found' } }));
  });
});

srv.listen(8931, '127.0.0.1', () => console.log('test MCP server on http://127.0.0.1:8931/mcp'));
