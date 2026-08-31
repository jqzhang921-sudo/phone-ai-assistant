import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/mcp_tool.dart';

void main() {
  // 这一组钉的是同一件事：别人家的服务器返回什么都有可能，解析要能扛住。
  //
  // 原来 description 和 inputSchema 都是硬取，缺一个就抛；而抛出去会被
  // ExternalMcpClient.connect() 外层一兜，症状变成整台服务器「连接失败」——
  // 看着像服务器挂了，其实只是某个工具少个字段。
  group('工具字段缺斤少两也要读得出来', () {
    test('description 是可选的，规范里就没要求给', () {
      final t = McpTool.fromJson({
        'name': 'order_coffee',
        'inputSchema': {'type': 'object'},
      });

      expect(t.name, 'order_coffee');
      expect(t.description, ''); // 不是 null，序列化时不用再判一次
    });

    test('没有 inputSchema 时给一个空 object，而不是让工具消失', () {
      final t = McpTool.fromJson({'name': 'ping'});

      // 模型看到的是「一个不收参数的工具」，比工具直接不存在强
      expect(t.inputSchema['type'], 'object');
    });

    test('inputSchema 不是 Map（有服务器给 null 或字符串）也不能崩', () {
      expect(
        McpTool.fromJson({'name': 'a', 'inputSchema': null}).inputSchema,
        isNotEmpty,
      );
      expect(
        McpTool.fromJson({'name': 'b', 'inputSchema': 'oops'}).inputSchema,
        isNotEmpty,
      );
    });

    test('嵌套的 schema 要原样留着，那是模型填参数的依据', () {
      final t = McpTool.fromJson({
        'name': 'call_car',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'to': {'type': 'string', 'description': '目的地'},
          },
          'required': ['to'],
        },
      });

      final props = t.inputSchema['properties'] as Map;
      expect((props['to'] as Map)['description'], '目的地');
      expect(t.inputSchema['required'], ['to']);
    });
  });

  // name 是唯一真必需的：没有名字就没法调用，留着也是废的。
  // 这里**要**抛——connect() 里逐个 try 会把它单独跳过，不牵连别的工具。
  group('只有 name 缺失才算废工具', () {
    test('没有 name 就抛', () {
      expect(() => McpTool.fromJson({'description': '没名字'}), throwsA(anything));
    });

    test('name 是空串也算没有', () {
      expect(() => McpTool.fromJson({'name': ''}), throwsA(anything));
    });

    test('name 不是字符串也算没有', () {
      expect(() => McpTool.fromJson({'name': 42}), throwsA(anything));
    });
  });
}
