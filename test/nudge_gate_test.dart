import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/nudge_gate.dart';

const _on = NudgePrefs(enabled: true);

DateTime at(int hour, {int day = 10}) => DateTime(2026, 9, day, hour);

void main() {
  // 跨零点是这个文件里唯一容易写错的地方：
  // `h >= 23 && h < 8` 永远为假，一条都拦不住，而症状是「半夜被吵醒」。
  group('静默时段', () {
    test('默认 23–8：深夜和凌晨都算静默', () {
      for (final h in [23, 0, 3, 7]) {
        expect(inQuietHours(h, _on), isTrue, reason: '$h 点该静默');
      }
    });

    test('默认 23–8：白天不算', () {
      for (final h in [8, 12, 18, 22]) {
        expect(inQuietHours(h, _on), isFalse, reason: '$h 点不该静默');
      }
    });

    test('不跨零点的时段也要对', () {
      const noon = NudgePrefs(enabled: true, quietStartHour: 12, quietEndHour: 14);
      expect(inQuietHours(11, noon), isFalse);
      expect(inQuietHours(12, noon), isTrue);
      expect(inQuietHours(13, noon), isTrue);
      expect(inQuietHours(14, noon), isFalse); // 右开区间
    });

    test('起止相同 = 没有静默时段，不是全天静默', () {
      const none = NudgePrefs(enabled: true, quietStartHour: 9, quietEndHour: 9);
      expect(inQuietHours(9, none), isFalse);
      expect(inQuietHours(3, none), isFalse);
    });
  });

  group('拦不拦', () {
    test('没开就什么都不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: const NudgePrefs(), // enabled 默认 false
        sentToday: 0,
      );
      expect(d.allowed, isFalse);
      expect(d.reason, NudgeBlock.disabled);
    });

    test('什么都不挡的时候放行', () {
      final d = decideNudge(now: at(15), prefs: _on, sentToday: 0);
      expect(d.allowed, isTrue);
      expect(d.reason, NudgeBlock.none);
    });

    test('半夜不推', () {
      final d = decideNudge(now: at(2), prefs: _on, sentToday: 0);
      expect(d.reason, NudgeBlock.quietHours);
    });

    // 保险丝，不是配额：正常路径永远碰不到（频率由「有没有事发生」决定）。
    // 碰到了基本等于有 bug 在连环触发。
    test('保险丝：一天推到上限就断', () {
      final d = decideNudge(now: at(15), prefs: _on, sentToday: kRunawayPerDay);
      expect(d.reason, NudgeBlock.runaway);
    });

    test('没到保险丝就不该拦', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: kRunawayPerDay - 1,
      );
      expect(d.allowed, isTrue);
    });

    test('离上一条太近不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 1,
        // 差 30 分钟，默认间隔 1 小时
        lastNudgeAt: at(15).subtract(const Duration(minutes: 30)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterNudge);
    });

    test('隔够了就放行', () {
      final d = decideNudge(
        now: at(18),
        prefs: _on,
        sentToday: 1,
        lastNudgeAt: at(15),
      );
      expect(d.allowed, isTrue);
    });

    // 刚聊完就弹一条，读起来像它没听见你刚说的话。
    test('刚聊完不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 0,
        lastChatAt: at(14),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterChat);
    });

    test('聊完过了三小时可以推', () {
      final d = decideNudge(
        now: at(18),
        prefs: _on,
        sentToday: 0,
        lastChatAt: at(14),
      );
      expect(d.allowed, isTrue);
    });

    // ⚠️ 这条钉的是设计红线，不是实现细节：
    // 「太久没聊」**不能**成为推送的理由。那是拿愧疚换打开率。
    // 门槛里没有任何一条会因为「隔得久」而变得更想推——
    // 隔一天和隔一个月，放行与否完全一样。
    test('隔了很久本身不构成推的理由，也不构成拦的理由', () {
      final aMonthAgo = DateTime(2026, 8, 10, 15);
      final justEnough = at(11); // 刚好过了三小时静默

      final longGone = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 0,
        lastChatAt: aMonthAgo,
      );
      final recent = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 0,
        lastChatAt: justEnough,
      );

      expect(longGone.allowed, isTrue);
      expect(recent.allowed, isTrue);
      expect(longGone.reason, recent.reason); // 两种情况一视同仁
    });

    // ⚠️ 这一组钉的是一个真实踩过的坑：常聊天的人（一天一百多轮）永远等不到
    // 三小时安静，于是所有便签都过期作废——功能等于没做。
    // 便签的时间是它自己在对话里定的，「刚聊完」这条不该反过来否决它。
    test('便签到点：刚聊完也照样放行', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 0,
        isFollowUp: true,
        lastChatAt: at(15).subtract(const Duration(minutes: 40)),
      );
      expect(d.allowed, isTrue);
    });

    test('同样的时刻，不是便签就还是拦', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 0,
        lastChatAt: at(15).subtract(const Duration(minutes: 40)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterChat);
    });

    test('便签之间用更短的间隔：差 25 分钟就能连着推两条', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 1,
        isFollowUp: true,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 25)),
      );
      expect(d.allowed, isTrue);
    });

    test('但便签也不能连着弹：差 10 分钟还是拦', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        sentToday: 1,
        isFollowUp: true,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 10)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterNudge);
    });

    test('便签也照样受静默时段和保险丝管', () {
      expect(
        decideNudge(
          now: at(2),
          prefs: _on,
          sentToday: 0,
          isFollowUp: true,
        ).reason,
        NudgeBlock.quietHours,
      );
      expect(
        decideNudge(
          now: at(15),
          prefs: _on,
          sentToday: kRunawayPerDay,
          isFollowUp: true,
        ).reason,
        NudgeBlock.runaway,
      );
    });

    test('从来没聊过、从来没推过也不该崩', () {
      final d = decideNudge(now: at(15), prefs: _on, sentToday: 0);
      expect(d.allowed, isTrue);
    });
  });

  // 主动消息的通病是重复——单条读着没问题，连着三天收到同一句就假了。
  group('别把同一天过第二遍', () {
    test('换了标点和语序，仍然算同一句', () {
      const recent = ['我刚写完一封信，放在栖息里了'];
      expect(looksRepeated('我刚写完一封信，放在栖息里了。', recent), isTrue);
      expect(looksRepeated('刚写完一封信，放栖息里了', recent), isTrue);
    });

    test('说的是另一件事就该放行', () {
      const recent = ['我刚写完一封信，放在栖息里了'];
      expect(looksRepeated('昨天那本书我看到一半，主角忽然不说话了', recent), isFalse);
    });

    test('没有历史时永远不算重复', () {
      expect(looksRepeated('随便一句话', const []), isFalse);
    });

    test('只要和历史里任意一条像，就算重复', () {
      const recent = ['今天记了篇日记', '我刚写完一封信，放在栖息里了'];
      expect(looksRepeated('刚写完一封信，放栖息里了', recent), isTrue);
    });

    test('空串不该被判成重复', () {
      expect(looksRepeated('', const ['我刚写完一封信']), isFalse);
    });
  });

  // 拦下来的原因要能显示给用户看：点了「现在试一次」没反应，
  // 不说原因的话只会以为功能坏了。
  group('每个拦截原因都有话可说', () {
    test('文案都不为空，且不是重复的', () {
      final labels = NudgeBlock.values.map((b) => b.label).toList();
      expect(labels.every((s) => s.trim().isNotEmpty), isTrue);
      expect(labels.toSet().length, labels.length);
    });
  });
}
