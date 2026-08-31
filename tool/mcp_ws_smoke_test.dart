// ignore_for_file: avoid_print, avoid_relative_lib_imports
// 回归测试：确认改造后 WebSocket 那条路（App 自带的 8765 server）没坏。
//   node test_mcp_server.js &
//   dart run tool/mcp_ws_smoke_test.dart
import '../lib/services/mcp_transport.dart';

Future<void> main() async {
  final t = createTransport('ws://127.0.0.1:8765');
  if (t is! WebSocketTransport) throw StateError('ws:// 没选中 WebSocketTransport');
  await t.open();

  final init = await t.request('initialize', {
    'protocolVersion': kMcpProtocolVersion,
    'capabilities': <String, dynamic>{},
    'clientInfo': {'name': 'smoke', 'version': '1.0.0'},
  });
  print('serverInfo: ${init['serverInfo']}');

  t.onInitialized();
  await t.notify('notifications/initialized');

  final listed = await t.request('tools/list');
  final tools = (listed['tools'] as List?) ?? [];
  print('tools: ${tools.map((e) => (e as Map)['name']).toList()}');

  await t.close();
  print(tools.isNotEmpty ? 'WS OK' : 'WS 没拿到工具');
}
