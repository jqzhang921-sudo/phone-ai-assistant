import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/nudge_service.dart';
import 'package:phone_ai_assistant/services/small_things.dart';

/// 板上的纸条什么时候够格当作「他想开口」的由头。
///
/// 这一层是纯本地读，测得动：信和日记那两条在测试里拿不到文件系统，会被
/// `collectCandidates` 里的 catch 吞掉，所以剩下的候选只可能来自板上——
/// 正好把这条支路单独框出来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// [author] 默认 null——这是**这个字段之前存下来的老纸条**，
  /// 板上现在真有一批，所以它才是默认值。
  Future<void> stick(
    String id,
    String text, {
    Duration ago = const Duration(hours: 12),
    DateTime? due,
    SmallThingAuthor? author,
  }) => SmallThingStore.add(
    SmallThing(
      id: id,
      text: text,
      createdAt: DateTime.now().subtract(ago),
      dueAt: due,
      author: author,
    ),
  );

  group('板上的纸条能不能当由头', () {
    test('贴够久的纯纸条算', () async {
      await stick('s1', '今天云很好看');
      final c = await NudgeService.collectCandidates();
      expect(c.map((e) => e.mentionKey), contains('thing:s1'));
    });

    test('填了截止时间的不算——那是要做的事，提起来就是催', () async {
      await stick(
        's2',
        '周五交房租',
        due: DateTime.now().add(const Duration(days: 2)),
      );
      expect(await NudgeService.collectCandidates(), isEmpty);
    });

    test('刚贴上的不算，那是复读不是想起', () async {
      await stick('s3', '今天云很好看', ago: const Duration(minutes: 30));
      expect(await NudgeService.collectCandidates(), isEmpty);
    });

    test('勾掉的不算', () async {
      await stick('s4', '去拿快递');
      await SmallThingStore.markDone('s4');
      expect(await NudgeService.collectCandidates(), isEmpty);
    });

    test('提过一次就不再当由头', () async {
      await stick('s5', '今天云很好看');
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList('nudge_mentioned', ['thing:s5']);
      expect(await NudgeService.collectCandidates(), isEmpty);
    });

    test('它自己贴的也算，但说清楚那是它替 TA 记的', () async {
      // 这里一度是硬排除（理由：add_small_thing 记的必然是待办，提了就是催）。
      // 那条太绝对——「你那个快递还没去拿吧」听着就是正常人说话。
      // 变味的不是那句话，是说第二遍，而那个由 mentionKey 挡着。
      await stick('s6', '去交物业费', author: SmallThingAuthor.ai);
      final c = await NudgeService.collectCandidates();
      expect(c, hasLength(1));
      expect(c.single.what, contains('你替 TA 记'));
    });

    test('她自己贴的算，而且说得出是她贴的', () async {
      await stick('s7', '今天云很好看', author: SmallThingAuthor.user);
      final c = await NudgeService.collectCandidates();
      expect(c, hasLength(1));
      expect(c.single.what, contains('TA '));
      expect(c.single.what, contains('今天云很好看'));
    });

    test('老纸条作者不明，照样算，但不声称是谁贴的', () async {
      await stick('s8', '今天云很好看');
      final c = await NudgeService.collectCandidates();
      expect(c, hasLength(1));
      expect(c.single.what, isNot(contains('TA ')));
    });

    test('几张一起贴着就都是候选，挑哪张不归这一层管', () async {
      await stick('a', '今天云很好看');
      await stick('b', '楼下那只猫又来了');
      final keys = (await NudgeService.collectCandidates())
          .map((e) => e.mentionKey)
          .toSet();
      expect(keys, {'thing:a', 'thing:b'});
    });
  });
}
