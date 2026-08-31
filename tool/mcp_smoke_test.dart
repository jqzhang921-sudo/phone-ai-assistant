// ignore_for_file: avoid_print, avoid_relative_lib_imports
// 冒烟测试：用真实 HTTP 跑一遍 StreamableHttpTransport 的完整握手。
//
// 只依赖 mcp_transport.dart（纯 Dart），所以可以直接 `dart run`，
// 不用起模拟器。用法：
//   node <scratchpad>/test_streamable_server.mjs &
//   dart run tool/mcp_smoke_test.dart
import '../lib/services/mcp_transport.dart';

const _endpoint = 'http://127.0.0.1:8931/mcp';

int _passed = 0;
int _failed = 0;

void check(String label, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  PASS  $label');
  } else {
    _failed++;
    print('  FAIL  $label${detail == null ? '' : '  ($detail)'}');
  }
}

Future<void> main() async {
  print('endpoint: $_endpoint\n');

  final transport = createTransport(_endpoint);
  check('按 http:// 选中 Streamable HTTP', transport is StreamableHttpTransport);

  await transport.open();

  // --- initialize：走 application/json，并从响应头拿 session id ---
  final init = await transport.request('initialize', {
    'protocolVersion': kMcpProtocolVersion,
    'capabilities': <String, dynamic>{},
    'clientInfo': {'name': 'smoke', 'version': '1.0.0'},
  });
  check('initialize 返回 serverInfo',
      (init['serverInfo'] as Map?)?['name'] == 'test-streamable-server',
      '$init');

  transport.onInitialized();
  await transport.notify('notifications/initialized');
  check('notifications/initialized 已发出（202 不报错）', true);

  // --- tools/list：走 SSE，且流里混了注释和无关通知 ---
  final listed = await transport.request('tools/list');
  final tools = (listed['tools'] as List?) ?? [];
  check('SSE 分支解析出 2 个工具', tools.length == 2, '${tools.length}');
  check('跳过了流里的注释和无关通知',
      tools.isNotEmpty && (tools.first as Map)['name'] == 'echo');

  // --- tools/call：走 application/json ---
  final echo = await transport.request('tools/call', {
    'name': 'echo',
    'arguments': {'text': '小克在此'},
  });
  final echoText = ((echo['content'] as List?)?.first as Map?)?['text'];
  check('echo 往返中文无损', echoText == '小克在此', '$echoText');

  final add = await transport.request('tools/call', {
    'name': 'add',
    'arguments': {'a': 3, 'b': 4},
  });
  final addText = ((add['content'] as List?)?.first as Map?)?['text'];
  check('add 返回 7', addText == '7', '$addText');

  // --- 错误分支：server 返回 JSON-RPC error，应该抛出而不是静默变 null ---
  try {
    await transport.request('tools/call', {'name': 'nope', 'arguments': {}});
    check('工具不存在时抛出 McpTransportError', false, '没有抛异常');
  } on McpTransportError catch (e) {
    check('工具不存在时抛出 McpTransportError', true);
    check('错误消息带上了服务器原文', e.message.contains('没有这个工具'), e.message);
    check('错误码透传', e.code == -32602, '${e.code}');
  }

  // --- 地址无法识别时应当明确拒绝 ---
  try {
    createTransport('ftp://nope');
    check('无法识别的 scheme 被拒绝', false, '没有抛异常');
  } on McpTransportError {
    check('无法识别的 scheme 被拒绝', true);
  }

  await transport.close();

  print('\n$_passed passed, $_failed failed');
  if (_failed > 0) throw StateError('smoke test failed');
}
