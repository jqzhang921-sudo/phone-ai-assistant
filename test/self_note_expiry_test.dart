import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/self_notes.dart';

/// 便签过期不再静默消失。
///
/// 过期本身是**删除**，而在她那边「便签过期了」和「压根没触发」长得一模一样：
/// 都是贴了便条，然后什么都没发生。所以作废这件事得留一行字。
///
/// 窗口是真的窄——宽限 = clamp(等待时长, 30分, 3小时)，一张等 20 分钟的便签
/// 只在第 20 到第 50 分钟之间活着。ColorOS 攒一次唤醒就整个错过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  SelfNote note({
    required Duration ago,
    required Duration waited,
    String about = '她说去做饭了',
  }) {
    final created = DateTime.now().subtract(ago);
    return SelfNote(
      id: 'n_${ago.inMinutes}_$about',
      conversationId: 'c1',
      about: about,
      createdAt: created,
      dueAt: created.add(waited),
    );
  }

  group('作废留痕', () {
    test('还活着的不记账', () async {
      await SelfNoteStore.add(
        note(ago: const Duration(minutes: 10), waited: const Duration(minutes: 40)),
      );
      await SelfNoteStore.due(DateTime.now());
      expect(await SelfNoteStore.recentlyExpired(), isEmpty);
    });

    test('过期的记下来，而且真的从板上下来了', () async {
      // 等 20 分钟 → 宽限取下限 30 分钟 → 第 50 分钟作废。两小时前的早没了。
      await SelfNoteStore.add(
        note(ago: const Duration(hours: 2), waited: const Duration(minutes: 20)),
      );
      expect(await SelfNoteStore.due(DateTime.now()), isEmpty);

      final gone = await SelfNoteStore.recentlyExpired();
      expect(gone, hasLength(1));
      expect(gone.single.$2, '她说去做饭了');
      expect(await SelfNoteStore.list(), isEmpty);
    });

    test('留新便签时顺手清掉的那些也记账', () async {
      // add() 里也清过期，那条路以前同样不留痕——两处清理现在收口到一个函数。
      await SelfNoteStore.add(
        note(ago: const Duration(hours: 2), waited: const Duration(minutes: 20)),
      );
      await SelfNoteStore.add(
        note(ago: const Duration(minutes: 1), waited: const Duration(minutes: 40)),
      );
      expect(await SelfNoteStore.recentlyExpired(), hasLength(1));
      expect(await SelfNoteStore.list(), hasLength(1));
    });

    test('作废腾出来的名额能接着用', () async {
      // 上限 4 张。塞满之后全部过期，应该能再留下新的。
      for (var i = 0; i < SelfNoteStore.maxPending; i++) {
        expect(
          await SelfNoteStore.add(
            note(
              ago: const Duration(hours: 2),
              waited: const Duration(minutes: 20),
              about: '第 $i 件事',
            ),
          ),
          isTrue,
        );
      }
      expect(
        await SelfNoteStore.add(
          note(ago: const Duration(minutes: 1), waited: const Duration(minutes: 40)),
        ),
        isTrue,
      );
      expect(await SelfNoteStore.list(), hasLength(1));
    });

    test('只留最近几条，不无限攒', () async {
      for (var i = 0; i < 9; i++) {
        await SelfNoteStore.add(
          note(
            ago: const Duration(hours: 2),
            waited: const Duration(minutes: 20),
            about: '第 $i 件事',
          ),
        );
      }
      expect((await SelfNoteStore.recentlyExpired()).length, lessThanOrEqualTo(5));
    });
  });
}
