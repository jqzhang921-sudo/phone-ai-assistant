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
      expect(stickerOf('smile')?.label, '笑');
      expect(stickerOf('没有这个'), isNull);
      expect(stickerOf(null), isNull);
    });

    test('退役的旧 key 仍然查得到——她的老消息里存着', () {
      // 删掉这几个 key，老消息就画不出东西了。见 [Sticker] 的注释。
      for (final old in ['calm', 'wink', 'alert', 'sleepy', 'box', 'back', 'sit']) {
        expect(stickerOf(old), isNotNull, reason: old);
      }
      // 但它们不该出现在面板和工具清单里。
      final current = kStickers.map((s) => s.key).toSet();
      expect(current.contains('calm'), isFalse);
      expect(current.contains('sleepy'), isFalse);
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
      final r = await StickerTool.execute({'name': 'sleep'});
      expect(r['success'], true);
      expect(r['sticker'], 'sleep');
    });

    test('退役的表情它发不出来', () async {
      // 老消息还得靠这些 key 画出来，但不该让它继续发这批旧图。
      final r = await StickerTool.execute({'name': 'sleepy'});
      expect(r['success'], false);
    });

    test('名字写错了，把清单还回去让它自己挑', () async {
      final r = await StickerTool.execute({'name': '困'});
      expect(r['success'], false);
      // ⚠️ 只回一句「没有这个表情」会把路堵死：它只会改用文字描述表情，
      // 那正是这个工具要避免的。
      expect(r['error'], contains('sleep'));
    });

    test('不给名字也不崩', () async {
      final r = await StickerTool.execute({});
      expect(r['success'], false);
    });
  });
}
