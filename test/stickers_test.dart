import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/phone_tools/sticker_tool.dart';
import 'package:phone_ai_assistant/services/stickers.dart';

void main() {
  group('表情清单', () {
    test('key 不重复——存进消息里的就是它，重了会画错', () {
      final keys = kStickers.map((s) => s.key).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('资源路径和文件名对得上', () {
      for (final s in kStickers) {
        expect(s.asset, 'assets/stickers/mochi_${s.key}.png');
      }
    });

    test('每张都得有给模型看的「什么时候用」', () {
      for (final s in kStickers) {
        expect(s.when.trim(), isNotEmpty, reason: s.key);
        expect(s.label.trim(), isNotEmpty, reason: s.key);
      }
    });

    test('查得到，也查得出没有', () {
      expect(stickerOf('calm')?.label, '平常');
      expect(stickerOf('没有这个'), isNull);
      expect(stickerOf(null), isNull);
    });
  });

  group('send_sticker', () {
    test('工具描述里列出了全部表情', () {
      final d = StickerTool.definition.description;
      for (final s in kStickers) {
        expect(d, contains('`${s.key}`'), reason: s.key);
      }
    });

    test('参数只认清单里的名字', () {
      final schema = StickerTool.definition.inputSchema;
      final e = (schema['properties'] as Map)['name']['enum'] as List;
      expect(e.toSet(), kStickers.map((s) => s.key).toSet());
    });

    test('发对了返回 key', () async {
      final r = await StickerTool.execute({'name': 'sleepy'});
      expect(r['success'], true);
      expect(r['sticker'], 'sleepy');
    });

    test('名字写错了，把清单还回去让它自己挑', () async {
      final r = await StickerTool.execute({'name': '困'});
      expect(r['success'], false);
      // ⚠️ 只回一句「没有这个表情」会把路堵死：它只会改用文字描述表情，
      // 那正是这个工具要避免的。
      expect(r['error'], contains('sleepy'));
    });

    test('不给名字也不崩', () async {
      final r = await StickerTool.execute({});
      expect(r['success'], false);
    });
  });
}
