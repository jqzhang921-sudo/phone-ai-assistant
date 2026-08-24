import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/models/conversation.dart';
import 'package:phone_ai_assistant/services/history_compactor.dart';

Conversation _conv(int n, {int summarized = 0}) => Conversation(
  id: 'c1',
  title: 't',
  createdAt: DateTime(2026, 8, 24),
  updatedAt: DateTime(2026, 8, 24),
  messages: [
    for (var i = 0; i < n; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? MessageRole.user : MessageRole.assistant,
        content: '第 $i 条',
      ),
  ],
  summarizedCount: summarized,
);

void main() {
  group('什么时候该压', () {
    test('没到阈值不压', () {
      // 阈值是 80，80 条整不该触发（比较是严格大于）
      expect(needsCompaction(_conv(80)), isFalse);
      expect(needsCompaction(_conv(81)), isTrue);
    });

    test('数的是「未压缩的」条数，不是总条数', () {
      // 200 条里已经压掉 150，剩 50 条没压——没到阈值，不该再压
      expect(needsCompaction(_conv(200, summarized: 150)), isFalse);
      // 已压 100，剩 100 条——该压
      expect(needsCompaction(_conv(200, summarized: 100)), isTrue);
    });
  });

  group('阈值和保留数的关系', () {
    /// 这两个数必须一起看：差值才是「每次折叠多少条」。
    ///
    /// 2026-08-24 把 _kKeepRecent 从 30 抬到 45（压缩那一刻整批抽走风格样本，
    /// 是「突然性情大变」的根子）。抬它的时候必须把阈值一起抬，
    /// 否则每次压缩只折走几条，白白多花一次 API 调用。
    ///
    /// 这两个常量是私有的，从外部只能通过 needsCompaction 的行为反推——
    /// 下面用二分探出阈值，再断言差值落在合理区间。
    int probeThreshold() {
      var lo = 1, hi = 1000;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        if (needsCompaction(_conv(mid))) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      return lo - 1; // 最后一个「不触发」的条数 = 阈值
    }

    test('阈值就是 80，改了这里要连带想清楚下面那条', () {
      expect(probeThreshold(), 80);
    });

    test('每次至少折走 30 条，否则压缩不划算', () {
      // 保留数 45 是从代码里读来的常量值；差值 = 80 - 45 = 35
      const keepRecent = 45;
      final folded = probeThreshold() - keepRecent;
      expect(
        folded,
        greaterThanOrEqualTo(30),
        reason: '折叠 $folded 条就要跑一次 API，太少了。抬 _kKeepRecent 时阈值要跟着抬',
      );
    });
  });
}
