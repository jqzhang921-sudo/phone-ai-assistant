import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/models/mcp_tool.dart';
import 'package:phone_ai_assistant/services/tool_tiers.dart';

McpTool tool(String name, String desc) => McpTool(
  name: name,
  description: desc,
  inputSchema: const {'type': 'object', 'properties': {}},
  category: '手机工具',
);

final _all = [
  tool('memory', '长期记忆：关于用户是谁的事。'),
  tool('follow_up_later', '给自己留一张便签：这件事没完，过一会儿回来问一句。'),
  tool('take_photo', '用手机摄像头拍一张照片。'),
  tool('get_weather', '查天气（当前实况 + 未来几天预报）。'),
  tool('set_alarm', '设一个闹钟。'),
  tool('read_clipboard', '读剪贴板里的内容。'),
  tool('find_tools', '取一个手上没有的工具。'),
];

void main() {
  setUp(ToolTiers.resetForTest);

  group('分层', () {
    test('常驻的直接声明，收着的不声明', () {
      ToolTiers.begin('c1', _all);
      final active = ToolTiers.active(_all).map((t) => t.name).toSet();
      expect(active, contains('memory'));
      expect(active, contains('follow_up_later'));
      expect(active, contains('find_tools'));
      expect(active, isNot(contains('take_photo')));
      expect(active, isNot(contains('set_alarm')));
    });

    test('find_tools 必须常驻——它要是也收起来，延迟层等于不存在', () {
      expect(ToolTiers.resident, contains('find_tools'));
    });

    test('索引里是收着的那些，一行一个', () {
      final idx = ToolTiers.buildIndex(_all);
      expect(idx, contains('take_photo'));
      expect(idx, contains('set_alarm'));
      // 常驻的不该出现在「还能取用的」里
      expect(idx, isNot(contains('- memory：')));
    });

    test('一行索引真的只有一行——长描述要被压短', () {
      final t = tool('x', '第一句话。第二句话不该出现在索引里，'
          '第三句更不该，这段描述总共好几百字，全塞进去就白分层了。');
      expect(ToolTiers.oneLine(t), '第一句话');
    });
  });

  group('取工具', () {
    test('搜到了就声明出去，而且这轮就能调', () async {
      ToolTiers.begin('c1', _all);
      final r = await ToolFinder.execute({'query': '我想拍张照'});
      expect(r['success'], isTrue);
      expect(
        ToolTiers.active(_all).map((t) => t.name),
        contains('take_photo'),
      );
    });

    test('英文工具名直接说也认', () async {
      ToolTiers.begin('c1', _all);
      final r = await ToolFinder.execute({'query': 'set_alarm'});
      expect(r['success'], isTrue);
      expect((r['tools'] as List).first['name'], 'set_alarm');
    });

    test('⚠️ 搜不到要把整份清单摊开，不能一句「没找到」把路堵死', () async {
      ToolTiers.begin('c1', _all);
      final r = await ToolFinder.execute({'query': '帮我订一张去冰岛的机票'});
      expect(r['success'], isFalse);
      final avail = (r['available'] as List).join();
      // 收着的每一个都得列出来，让它自己挑
      for (final n in ['take_photo', 'get_weather', 'set_alarm', 'read_clipboard']) {
        expect(avail, contains(n), reason: '清单里缺了 $n');
      }
    });

    test('空 query 不搜', () async {
      ToolTiers.begin('c1', _all);
      final r = await ToolFinder.execute({'query': '   '});
      expect(r['success'], isFalse);
    });
  });

  group('⚠️ 缓存前缀：取出来的只增不减', () {
    test('取过一次之后一直留着——否则每轮 tools 都在变，缓存全落空', () async {
      ToolTiers.begin('c1', _all);
      await ToolFinder.execute({'query': '拍照'});
      expect(ToolTiers.active(_all).map((t) => t.name), contains('take_photo'));

      // 同一段对话里再 begin 一次（每次发消息都会调），不该把它清掉
      ToolTiers.begin('c1', _all);
      expect(ToolTiers.active(_all).map((t) => t.name), contains('take_photo'));
    });

    test('索引始终列全部收着的——取出来的也留在里面', () async {
      ToolTiers.begin('c1', _all);
      final before = ToolTiers.buildIndex(_all);
      await ToolFinder.execute({'query': '拍照'});
      // 索引一变，tools 和 system 前缀会一起变，缓存白赔两次
      expect(ToolTiers.buildIndex(_all), before);
    });

    test('换对话才清空——新对话本来就是新缓存', () async {
      ToolTiers.begin('c1', _all);
      await ToolFinder.execute({'query': '拍照'});
      ToolTiers.begin('c2', _all);
      expect(
        ToolTiers.active(_all).map((t) => t.name),
        isNot(contains('take_photo')),
      );
    });
  });
}
